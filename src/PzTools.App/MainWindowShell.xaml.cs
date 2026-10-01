using PzTools.Process.Contracts.GameRuntime;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PzTools.App.Core;
using PzTools.Backup.Core;
using PzTools.Projections;
using PzTools.Zomboid.State;
using PzTools.Zomboid.Archive;
using Microsoft.Windows.Storage.Pickers;
using Windows.Storage.Streams;

namespace PzTools.App;

public sealed partial class MainWindowShell : UserControl
{
    private const int RevisionEntranceDurationMs = 260;
    private const int RevisionEntranceStaggerMs = 22;
    private const int RevisionEntranceStaggerRows = 7;
    private const int RevisionEntranceRisePx = 14;
    private const int RevisionExitDurationMs = 150;
    private readonly DispatcherQueueTimer countdownTimer;
    private readonly DispatcherQueueTimer detailProgressDelayTimer;
    private readonly DispatcherQueueTimer revisionEntranceTimer;
    private readonly DispatcherQueueTimer localOperationCardTimer;
    private readonly DispatcherQueueTimer operationCardExpiryTimer;
    private readonly SemaphoreSlim thumbnailLoadGate;
    private readonly Dictionary<SaveVersionUiItem, CancellationTokenSource> revisionThumbnailLoads = [];
    private readonly HashSet<SaveVersionUiItem> revisionThumbnailAttempted = [];
    private CancellationTokenSource? operationProgressRefreshCancellation;
    private readonly AnimatedListSelectionBar saveSelectionBar;
    private readonly AnimatedListSelectionBar revisionSelectionBar;
    private readonly ListInsertionAnimator saveInsertionAnimator;
    private readonly ListInsertionAnimator revisionInsertionAnimator;
    private readonly Dictionary<ListViewItem, (ScalarKeyFrameAnimation Fade,
        Vector3KeyFrameAnimation Rise)> revisionEntranceAnimations = [];
    private ScalarKeyFrameAnimation? revisionExitFade;
    private readonly Dictionary<string, (string Message, DateTimeOffset RecordedUtc)> operationErrors = [];
    private IDisposable? viewSubscription;
    private long saveListRevision;
    private long scheduleRevision;
    private long operationsRevision;
    private long projectorHealthRevision;
    private long blockedComponentsRevision;
    private BlockedComponentsView? blockedComponents;
    private string? dismissedBlockedComponents;
    private long gameLinkRevision;
    private GameLinkView? gameLink;
    private bool gameLinkDismissed;
    private long logsRevision;
    private long backupCatalogRevision;
    private long homeExtensionsRevision;
    private BackupCatalogView? homeCatalog;
    private GameExtensionsView? homeExtensions;
    private long selectedDetailRevision;
    private long saveListApplyGeneration;
    private long detailApplyGeneration;
    private string? selectedSaveId;
    private string? displayedDetailSaveId;
    private ScheduleStatusView? schedule;
    private ProjectorHealthView? projectorHealth;
    private SaveListView? saveListSnapshot;
    private bool hostStartFailed;
    private bool narrow;
    private bool archiveInteraction;
    private bool detailLoading;
    private bool hasPresentedDetail;
    private bool hasSetInitialFocus;
    private bool revisionEntranceInProgress;
    private OperationView? localOperation;
    private long localOperationBaselineRunIndex;
    // Results of the user's actions that ran no worker, and placeholders whose work must not come back as a card.
    private readonly List<OperationNotice> notices = [];
    private readonly List<RetiredWork> retiredLocalWork = [];
    // While the pointer rests on the cards, finished ones stay so they can be read to the end.
    private bool operationCardsHovered;
    private IReadOnlyList<OperationCard> shownOperationCards = [];
    private readonly DispatcherQueueTimer operationCardsHoverTimer;
    // The cards may only use room the menu does not need; finished ones that do not fit are left out.
    private ScrollViewer? menuItemsScroller;
    private readonly Dictionary<string, double> operationCardHeights = new(StringComparer.Ordinal);
    private bool operationCardFitQueued;
    private readonly Dictionary<string, OperationCardElements> operationCardElements = new(StringComparer.Ordinal);

    private sealed record OperationCardElements(Border Root, FontIcon Icon, TextBlock Title, TextBlock Percent,
        ProgressBar Progress, Grid Detail, TextBlock Phase, TextBlock Amount, TextBlock Message);

    public MainWindowShell()
    {
        InitializeComponent();
        // A click or a key anywhere closes an open tooltip. Attached here, not by the window, so a shell
        // that replaces this one (after a data-folder change) has them too.
        AddHandler(PointerPressedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => AppToolTip.CloseCurrent()), true);
        AddHandler(KeyDownEvent, new Microsoft.UI.Xaml.Input.KeyEventHandler((_, _) => AppToolTip.CloseCurrent()), true);
        HomeRoot.NavigationRequested += HomeRoot_NavigationRequested;
        var runtime = App.Host?.RuntimeOptions ?? new AppRuntimeOptions();
        thumbnailLoadGate = new(runtime.ThumbnailReadConcurrency, runtime.ThumbnailReadConcurrency);
        saveSelectionBar = new AnimatedListSelectionBar(
            SaveList, SaveSelectionLayer, SaveSelectionBar, 18);
        revisionSelectionBar = new AnimatedListSelectionBar(
            RevisionList, RevisionSelectionLayer, RevisionSelectionBar, 17);
        saveInsertionAnimator = new ListInsertionAnimator(SaveList);
        revisionInsertionAnimator = new ListInsertionAnimator(RevisionList);
        RevisionList.LayoutUpdated += (_, _) => RevealRevisionSelectionIfReady();
        // Keep header/card presentation in sync with the responsive icon-only rail.
        Navigation.RegisterPropertyChangedCallback(NavigationView.IsPaneOpenProperty,
            (_, _) => ApplyNavigationSpacing());
        ApplyLocalizedText();
        countdownTimer = DispatcherQueue.CreateTimer();
        countdownTimer.Interval = TimeSpan.FromSeconds(1);
        countdownTimer.Tick += (_, _) => UpdateCountdown(tick: true);
        detailProgressDelayTimer = DispatcherQueue.CreateTimer();
        detailProgressDelayTimer.Interval = TimeSpan.FromMilliseconds(runtime.DetailProgressDelayMs);
        detailProgressDelayTimer.IsRepeating = false;
        detailProgressDelayTimer.Tick += (_, _) =>
        {
            if (detailLoading && hasPresentedDetail)
            {
                DetailTransitionProgress.Visibility = Visibility.Visible;
                DetailTransitionProgress.IsIndeterminate = true;
                UpdateOperationActions();
            }
        };
        revisionEntranceTimer = DispatcherQueue.CreateTimer();
        revisionEntranceTimer.Interval = TimeSpan.FromMilliseconds(
            RevisionEntranceDurationMs + RevisionEntranceStaggerMs * RevisionEntranceStaggerRows + 25);
        revisionEntranceTimer.IsRepeating = false;
        revisionEntranceTimer.Tick += (_, _) =>
        {
            revisionEntranceInProgress = false;
            RevealRevisionSelectionIfReady();
        };
        localOperationCardTimer = DispatcherQueue.CreateTimer();
        localOperationCardTimer.Interval = TimeSpan.FromSeconds(runtime.SuccessCardSeconds);
        localOperationCardTimer.IsRepeating = false;
        localOperationCardTimer.Tick += (_, _) =>
        {
            // The worker's own record of the same work must not appear as a second card now.
            if (localOperation is not null)
                retiredLocalWork.Add(new(localOperation.OperationId, localOperation.RunIndex, DateTimeOffset.UtcNow));
            localOperation = null;
            RefreshOperationCards();
        };
        operationCardExpiryTimer = DispatcherQueue.CreateTimer();
        operationCardExpiryTimer.IsRepeating = false;
        operationCardExpiryTimer.Tick += (_, _) => RefreshOperationCards();
        operationCardsHoverTimer = DispatcherQueue.CreateTimer();
        operationCardsHoverTimer.IsRepeating = false;
        // A pointer merely crossing the cards should not make them vanish the instant it leaves.
        operationCardsHoverTimer.Interval = TimeSpan.FromSeconds(1);
        operationCardsHoverTimer.Tick += (_, _) =>
        {
            operationCardsHovered = false;
            RefreshOperationCards();
        };
        OperationCards.PointerEntered += (_, _) =>
        {
            operationCardsHoverTimer.Stop();
            operationCardsHovered = true;
            operationCardExpiryTimer.Stop();
        };
        OperationCards.PointerExited += (_, _) => operationCardsHoverTimer.Start();
        OperationCards.SizeChanged += (_, _) => QueueOperationCardFit();
        InteractiveCards.SizeChanged += (_, _) => QueueOperationCardFit();
        Navigation.SizeChanged += (_, _) => QueueOperationCardFit();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        ActualThemeChanged += (_, _) => UpdateTitleBar();
    }

    public ObservableCollection<SaveListUiItem> SaveItems { get; } = [];
    public ObservableCollection<SaveVersionUiItem> RevisionItems { get; } = [];

    private App App => (App)Application.Current;

    private void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        AppSubtitleText.Text = Localizer.Get("AppSubtitle");
        LocalizeSupportButton();
        if (IsLoaded) App.MainWindow.Title = Localizer.Get("AppTitle");
        HomeItem.Content = Localizer.Get("HomeNavigation.Content");
        SavesItem.Content = Localizer.Get("SavesNavigation.Content");
        SavesPageTitle.Text = Localizer.Get("SavesNavigation.Content");
        AppToolTip.SetTip(SavesPageTitle, SavesPageTitle.Text);
        LogsItem.Content = Localizer.Get("LogsNavigation.Content");
        GameExtensionsItem.Content = Localizer.Get("GameExtensions.Title");
        ProfilerItem.Content = Localizer.Get("ProfilerNavigation");
        if (Navigation.SettingsItem is NavigationViewItem settings)
            settings.Content = Localizer.Get("SettingsTitle.Text");
        if (IsLoaded) RefreshOperationCards();
        if (blockedComponents is not null) ApplyBlockedComponents(blockedComponents);
        if (gameLink is not null) ApplyGameLink(gameLink);
        NextBackupText.Text = Localizer.Get("NextBackupWaiting.Text");
        ProjectorStatusTitle.Text = Localizer.Get("ProjectorStatusTitle");
        SetIconContent(ImportButton, "\uE8B5", Localizer.Get("ImportArchive.Content"));
        SetIconContent(DeleteAllBackupsButton, "\uE74D", Localizer.Get("DeleteAllBackupsButton"));
        NoSavesText.Text = Localizer.Get("NoSaves.Text");
        LoadingSavesText.Text = Localizer.Get("LoadingSaves.Text");
        SavesUnavailableText.Text = Localizer.Get("ProjectorStatusTitle");
        LoadingBackupsText.Text = Localizer.Get("LoadingBackups.Text");
        SelectSaveText.Text = Localizer.Get("SelectSave.Text");
        NarrowBackButton.Content = Localizer.Get("BackToList.Content");
        BackupRevisionsText.Text = Localizer.Get("BackupRevisions.Text");
        NoBackups.Text = Localizer.Get("NoBackups.Text");
        SetIconContent(ManualBackupButton, "\uE74E", Localizer.Get("ManualBackup.Content"));
        SetIconContent(RestoreButton, "\uE777", Localizer.Get("Restore.Content"));
        SetIconContent(ExportButton, "\uEDE1", Localizer.Get("ExportArchive.Content"));
        if (IsLoaded) UpdateRevisionActions();
    }

    // Action buttons carry a small icon before their label; the label stays their accessible name.
    private static void SetIconContent(Button button, string glyph, string text)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        button.Content = content;
        AutomationProperties.SetName(button, text);
    }

    public void ShowHostError(Exception exception)
    {
        hostStartFailed = true;
        UpdateSaveListPlaceholder();
        ShowLoadingBackups(false);
        LogsRoot.ShowLoadFailure();
        EndDetailLoading();
        ShowSidebarNotification(InfoBarSeverity.Error,
            Localizer.Get("BackgroundServiceStartFailed"), UserFacingError.FromException(exception));
    }

    /// <summary>Shows the result of an action as a card with the user's other work; it expires like one.</summary>
    internal void ShowSidebarNotification(InfoBarSeverity severity, string title, string message)
    {
        notices.Add(new(Guid.NewGuid().ToString("N"), title, message, severity switch
        {
            InfoBarSeverity.Error => OperationStatus.Failed,
            InfoBarSeverity.Warning => OperationStatus.Degraded,
            // Something that could not be done right now, with nothing wrong: the neutral icon of work that did not start.
            InfoBarSeverity.Informational => OperationStatus.Busy,
            _ => OperationStatus.Succeeded,
        }, DateTimeOffset.UtcNow));
        if (severity is InfoBarSeverity.Error or InfoBarSeverity.Warning)
            App.Host?.RecordActionIssue(title, message, severity == InfoBarSeverity.Error);
        RefreshOperationCards();
    }

    internal void RefreshLocalization()
    {
        ApplyLocalizedText();
        HomeRoot.ApplyLocalizedText();
        SettingsRoot.ApplyLocalizedText();
        LogsRoot.ApplyLocalizedText();
        GameExtensionsRoot.ApplyLocalizedText();
        ProfilerRoot.ApplyLocalizedText();
        saveListRevision = 0;
        scheduleRevision = 0;
        operationsRevision = 0;
        projectorHealthRevision = 0;
        logsRevision = 0;
        selectedDetailRevision = 0;
        RefreshChangedViews();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        App.MainWindow.SetTitleBar(AppTitleBar);
        App.MainWindow.Title = Localizer.Get("AppTitle");
        UpdateTitleBar();
        Navigation.SelectedItem ??= HomeItem;
        // Avoid the automatic startup focus ring on the pane toggle. Keyboard
        // navigation still uses the normal focus visuals after this first load.
        if (!hasSetInitialFocus)
            hasSetInitialFocus = HomeItem.Focus(FocusState.Pointer);
        if (Navigation.SettingsItem is NavigationViewItem settings)
        {
            settings.Content = Localizer.Get("SettingsTitle.Text");
            settings.Icon = new ImageIcon
            {
                Width = 20,
                Height = 20,
                Source = new SvgImageSource(new Uri("ms-appx:///Assets/Navigation/settings.svg")),
            };
        }
        ApplyNavigationSpacing();
        UpdateSaveListPlaceholder();
        var host = App.Host;
        if (host is null) return;
        viewSubscription ??= host.Views.Subscribe((_, _) =>
            DispatcherQueue.TryEnqueue(RefreshChangedViews));
        countdownTimer.Start();
        RefreshChangedViews();
        UpdateCountdown();
        // The extension settings are read on demand; Home shows them from the start.
        _ = RefreshExtensionsForHomeAsync(host);
    }

    private static async Task RefreshExtensionsForHomeAsync(AppHost host)
    {
        // A settings file that cannot be read is reported on the extensions page; Home keeps "checking".
        try { await host.GameExtensions.RefreshAsync(); }
        catch (Exception) { }
    }

    private void UpdateTitleBar()
    {
        if (!IsLoaded) return;
        App.MainWindow.AppWindow.TitleBar.ButtonForegroundColor = ActualTheme == ElementTheme.Dark
            ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        StopCountdownPulse();
        FinishContentNavigation();
        LoadingSavesProgress.IsActive = false;
        CancelRevisionThumbnails();
        countdownTimer.Stop();
        detailProgressDelayTimer.Stop();
        saveInsertionAnimator.Reset();
        revisionInsertionAnimator.Reset();
        ResetRevisionEntrance();
        ResetRevisionExit();
        localOperationCardTimer.Stop();
        // A replaced shell must not wake up later and start refreshing cards nobody sees.
        operationCardExpiryTimer.Stop();
        operationCardsHoverTimer.Stop();
        StopOperationProgressRefresh();
        viewSubscription?.Dispose();
        viewSubscription = null;
    }

    private void RefreshChangedViews()
    {
        var host = App.Host;
        if (host is null) return;

        var saves = host.Views.ReadIfChanged<SaveListView>(ViewKey.SaveList, saveListRevision);
        if (saves.Modified && saves.Snapshot is not null)
        {
            saveListRevision = saves.ViewRevision;
            ApplySaveList(saves.Snapshot, saves.ViewRevision);
        }

        var scheduler = host.Views.ReadIfChanged<ScheduleStatusView>(
            ViewKey.ScheduleStatus, scheduleRevision);
        if (scheduler.Modified && scheduler.Snapshot is not null)
        {
            scheduleRevision = scheduler.ViewRevision;
            schedule = scheduler.Snapshot;
            UpdateCountdown();
        }

        var operations = host.Views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, operationsRevision);
        if (operations.Modified && operations.Snapshot is not null)
        {
            operationsRevision = operations.ViewRevision;
            ApplyOperations(operations.Snapshot);
        }

        var health = host.Views.ReadIfChanged<ProjectorHealthView>(
            ViewKey.ProjectorHealth, projectorHealthRevision);
        if (health.Modified && health.Snapshot is not null)
        {
            projectorHealthRevision = health.ViewRevision;
            projectorHealth = health.Snapshot;
            ApplyProjectorHealth();
        }

        var blocked = host.Views.ReadIfChanged<BlockedComponentsView>(
            AppHost.BlockedComponentsViewKey, blockedComponentsRevision);
        if (blocked.Modified && blocked.Snapshot is not null)
        {
            blockedComponentsRevision = blocked.ViewRevision;
            ApplyBlockedComponents(blocked.Snapshot);
        }

        var link = host.Views.ReadIfChanged<GameLinkView>(AppHost.GameLinkViewKey, gameLinkRevision);
        if (link.Modified && link.Snapshot is not null)
        {
            gameLinkRevision = link.ViewRevision;
            ApplyGameLink(link.Snapshot);
        }

        var logs = host.Views.ReadIfChanged<LogsView>(ViewKey.Logs, logsRevision);
        if (logs.Modified && logs.Snapshot is not null)
        {
            logsRevision = logs.ViewRevision;
            LogsRoot.Apply(logs.Snapshot);
            LogsUnreadBadge.Value = logs.Snapshot.UnreadIssues;
            LogsUnreadBadge.Visibility = logs.Snapshot.UnreadIssues > 0
                ? Visibility.Visible : Visibility.Collapsed;
        }

        // Home's state tiles: the saves and schedule above, plus the backups and the extensions.
        var catalog = host.Views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, backupCatalogRevision);
        if (catalog.Modified && catalog.Snapshot is not null)
        {
            backupCatalogRevision = catalog.ViewRevision;
            homeCatalog = catalog.Snapshot;
        }
        var extensions = host.Views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, homeExtensionsRevision);
        if (extensions.Modified && extensions.Snapshot is not null)
        {
            homeExtensionsRevision = extensions.ViewRevision;
            homeExtensions = extensions.Snapshot;
        }
        if (saves.Modified || scheduler.Modified || catalog.Modified || extensions.Modified)
            HomeRoot.ShowStatus(HomeStatusSource.From(saveListSnapshot, homeCatalog, homeExtensions, schedule));

        RefreshSelectedDetail();
    }

    private void ApplySaveList(SaveListView view, long viewRevision)
    {
        var generation = ++saveListApplyGeneration;
        var existing = SaveItems.ToDictionary(item => item.SaveId, StringComparer.OrdinalIgnoreCase);
        var updates = new List<(SaveListUiItem Item, SaveListItemView Model,
            bool ReplaceThumbnail)>(view.Saves.Count);
        foreach (var save in view.Saves)
        {
            var item = existing.TryGetValue(save.SaveId, out var prior)
                ? prior : new SaveListUiItem(save);
            var replaceThumbnail = prior is null
                || !StringComparer.Ordinal.Equals(item.ThumbnailKey, save.ThumbnailKey);
            updates.Add((item, save, replaceThumbnail));
        }
        if (generation != saveListApplyGeneration || viewRevision != saveListRevision) return;

        var desired = updates.Select(update => update.Item).ToArray();
        var insertion = saveInsertionAnimator.Capture(SaveItems, desired, 0);
        if (insertion is null && (SaveItems.Count != desired.Length
            || SaveItems.Where((item, index) => !ReferenceEquals(item, desired[index])).Any()))
            saveInsertionAnimator.Reset();
        foreach (var (item, model, replaceThumbnail) in updates)
        {
            item.Update(model);
            if (replaceThumbnail) item.Thumbnail = null;
        }
        IncrementalListReconciler.Reconcile(SaveItems, desired);
        saveListSnapshot = view;
        hostStartFailed = false;
        UpdateSaveListPlaceholder();
        if (SaveList.SelectedItem is not SaveListUiItem selected || !SaveItems.Contains(selected))
            SaveList.SelectedItem = SaveItems.FirstOrDefault(item =>
                StringComparer.OrdinalIgnoreCase.Equals(item.SaveId, selectedSaveId))
                ?? SaveItems.FirstOrDefault();
        if (SaveItems.Count == 0)
        {
            selectedSaveId = null;
            selectedDetailRevision = 0;
            detailApplyGeneration++;
            EndDetailLoading();
            IncrementalListReconciler.Reconcile(RevisionItems, []);
            NoSelection.Visibility = Visibility.Visible;
            DetailContent.Visibility = Visibility.Collapsed;
            ShowNarrowDetail(false);
        }
        UpdateOperationActions();
        saveInsertionAnimator.Animate(insertion);
        foreach (var (item, model, replaceThumbnail) in updates)
            if (replaceThumbnail && model.ThumbnailKey is not null)
                _ = LoadLiveThumbnailForItemAsync(item, model);
    }

    private void UpdateSaveListPlaceholder()
    {
        var placeholder = SaveListPresentation.Resolve(saveListSnapshot,
            hostStartFailed || projectorHealth?.IsFaulted("state") == true);
        LoadingSaves.Visibility = placeholder == SaveListPlaceholder.Loading
            ? Visibility.Visible : Visibility.Collapsed;
        LoadingSavesProgress.IsActive = placeholder == SaveListPlaceholder.Loading && IsLoaded;
        EmptySaves.Visibility = placeholder == SaveListPlaceholder.Empty
            ? Visibility.Visible : Visibility.Collapsed;
        UnavailableSaves.Visibility = placeholder == SaveListPlaceholder.Unavailable
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task LoadLiveThumbnailForItemAsync(SaveListUiItem item, SaveListItemView model)
    {
        try
        {
            await thumbnailLoadGate.WaitAsync();
            BitmapImage? thumbnail;
            try { thumbnail = await LoadLiveThumbnailAsync(model); }
            finally { thumbnailLoadGate.Release(); }
            if (SaveItems.Contains(item)
                && StringComparer.Ordinal.Equals(item.ThumbnailKey, model.ThumbnailKey))
                item.Thumbnail = thumbnail;
        }
        catch (Exception exception)
        {
            System.Diagnostics.Debug.WriteLine(exception);
        }
    }

    private void RefreshSelectedDetail()
    {
        var host = App.Host;
        if (host is null || selectedSaveId is null) return;
        var result = host.Views.ReadIfChanged<SaveDetailView>(
            ViewKey.SaveDetail(selectedSaveId), selectedDetailRevision);
        if (!result.Modified || result.Snapshot is null) return;
        selectedDetailRevision = result.ViewRevision;
        _ = ApplyDetailAsync(result.Snapshot, result.ViewRevision, selectedSaveId);
    }

    private async Task ApplyDetailAsync(
        SaveDetailView detail,
        long viewRevision,
        string saveId)
    {
        var generation = ++detailApplyGeneration;
        var live = detail.LiveSave;
        var currentCharacter = live?.Character;
        var items = new List<SaveVersionUiItem>(detail.BackupRevisions.Count + 1);
        SaveVersionUiItem? currentItem = null;
        BitmapImage? currentThumbnail = null;
        var replaceCurrentThumbnail = false;
        if (live is not null)
        {
            var existingCurrent = RevisionItems.FirstOrDefault(item => item.IsCurrent
                && StringComparer.OrdinalIgnoreCase.Equals(item.SaveId, live.SaveId));
            currentItem = existingCurrent ?? new SaveVersionUiItem(live);
            replaceCurrentThumbnail = existingCurrent is null
                || !StringComparer.Ordinal.Equals(currentItem.ThumbnailKey, live.ThumbnailKey);
            if (replaceCurrentThumbnail)
            {
                currentThumbnail = SaveItems.FirstOrDefault(item =>
                    StringComparer.OrdinalIgnoreCase.Equals(item.SaveId, live.SaveId)
                    && StringComparer.Ordinal.Equals(item.ThumbnailKey, live.ThumbnailKey))?.Thumbnail;
            }
            items.Add(currentItem);
        }
        var source = FindBackupSource(detail.SaveId);
        var revisionUpdates = new List<(SaveVersionUiItem Item, BackupRevisionView Model,
            bool ReplaceThumbnail)>(detail.BackupRevisions.Count);
        foreach (var revision in detail.BackupRevisions.OrderByDescending(item => item.Revision))
        {
            var existingItem = RevisionItems.FirstOrDefault(existing => !existing.IsCurrent
                && StringComparer.OrdinalIgnoreCase.Equals(existing.SaveId, saveId)
                && existing.SourceId == source?.SourceId
                && existing.Revision == revision.Revision);
            var item = existingItem ?? new SaveVersionUiItem(saveId, source?.SourceId, revision);
            var replaceThumbnail = existingItem is null
                || !StringComparer.Ordinal.Equals(item.ThumbnailKey, revision.ThumbnailKey);
            revisionUpdates.Add((item, revision, replaceThumbnail));
            items.Add(item);
        }
        if (generation != detailApplyGeneration || viewRevision != selectedDetailRevision
            || !StringComparer.OrdinalIgnoreCase.Equals(saveId, selectedSaveId)) return;

        var changedSave = !StringComparer.OrdinalIgnoreCase.Equals(displayedDetailSaveId, saveId);
        if (changedSave && hasPresentedDetail && RevisionList.Visibility == Visibility.Visible)
        {
            await FadeOutRevisionListAsync();
            if (generation != detailApplyGeneration || viewRevision != selectedDetailRevision
                || !StringComparer.OrdinalIgnoreCase.Equals(saveId, selectedSaveId)) return;
        }
        ResetRevisionExit();

        if (currentItem is not null && live is not null)
        {
            // The save file records no version; the running game, the last one seen with this save, or the
            // newest backup that recorded one, in that order.
            var currentVersion = App.Host?.CurrentSaveVersion(live.SourcePath)
                ?? (detail.BackupRevisions.Where(revision => !string.IsNullOrWhiteSpace(revision.GameVersion))
                    .MaxBy(revision => revision.Revision) is { } latest
                    ? new SaveGameVersion(latest.GameVersion!.Trim(), SaveVersionBasis.LatestBackup, latest.CreatedUtc)
                    : null);
            currentItem.UpdateLive(live, currentCharacter, currentVersion);
            if (replaceCurrentThumbnail) currentItem.Thumbnail = currentThumbnail;
        }
        foreach (var (item, model, replaceThumbnail) in revisionUpdates)
        {
            item.UpdateRevision(source?.SourceId, model);
            if (replaceThumbnail) item.Thumbnail = null;
        }
        var previous = RevisionList.SelectedItem as SaveVersionUiItem;
        var insertion = changedSave ? null : revisionInsertionAnimator.Capture(
            RevisionItems, items, currentItem is null ? 0 : 1);
        if (insertion is null && (RevisionItems.Count != items.Count
            || RevisionItems.Where((item, index) => !ReferenceEquals(item, items[index])).Any()))
            revisionInsertionAnimator.Reset();
        ResetRevisionEntrance();
        revisionEntranceInProgress = changedSave;
        IncrementalListReconciler.Reconcile(RevisionItems, items);
        if (previous is null || !RevisionItems.Contains(previous))
            RevisionList.SelectedItem = items.FirstOrDefault(item => item.IsCurrent)
                ?? items.FirstOrDefault();
        EndDetailLoading();
        hasPresentedDetail = true;
        RevisionList.Visibility = Visibility.Visible;
        RevisionList.IsHitTestVisible = true;
        RevisionSelectionLayer.Visibility = Visibility.Collapsed;
        displayedDetailSaveId = saveId;
        revisionInsertionAnimator.Animate(insertion);
        if (changedSave)
        {
            ResetRevisionScroll();
            RevisionList.UpdateLayout();
            QueueRealizedRevisionThumbnails();
            AnimateVisibleRevisionRows();
            revisionEntranceTimer.Start();
        }
        // ListView can realize its containers on the next layout pass.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (generation != detailApplyGeneration
                || !StringComparer.OrdinalIgnoreCase.Equals(displayedDetailSaveId, saveId)
                || !StringComparer.OrdinalIgnoreCase.Equals(selectedSaveId, saveId))
                return;
            RevisionList.UpdateLayout();
            if (changedSave) ResetRevisionScroll();
            QueueRealizedRevisionThumbnails();
            if (changedSave && revisionEntranceInProgress)
                AnimateVisibleRevisionRows();
            RevealRevisionSelectionIfReady();
        });
        NoBackups.Visibility = RevisionItems.Any(item => !item.IsCurrent)
            ? Visibility.Collapsed : Visibility.Visible;
        ManualBackupButton.IsEnabled = live is not null && !HasConflictingOperation();
        UpdateRevisionActions();
        if (currentItem is not null && live is not null
            && replaceCurrentThumbnail && currentThumbnail is null)
            _ = LoadCurrentThumbnailForItemAsync(currentItem, live);
    }

    private void RevisionList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is not SaveVersionUiItem item || item.IsCurrent) return;
        if (args.InRecycleQueue)
        {
            if (revisionThumbnailLoads.Remove(item, out var request)) request.Cancel();
            revisionThumbnailAttempted.Remove(item);
            item.Thumbnail = null;
        }
        else if (args.Phase == 0)
            args.RegisterUpdateCallback((_, updated) =>
            {
                if (!updated.InRecycleQueue && updated.Item is SaveVersionUiItem realized)
                    QueueRevisionThumbnail(realized);
            });
    }

    private void QueueRealizedRevisionThumbnails()
    {
        if (RevisionList.ItemsPanelRoot is not { } panel) return;
        foreach (var container in panel.Children.OfType<ListViewItem>())
            if (container.Content is SaveVersionUiItem item) QueueRevisionThumbnail(item);
    }

    private void QueueRevisionThumbnail(SaveVersionUiItem item)
    {
        if (!IsLoaded || item.IsCurrent || item.SourceId is null || item.ThumbnailKey is null
            || item.SaveId != selectedSaveId || !RevisionItems.Contains(item)
            || item.Thumbnail is not null || !revisionThumbnailAttempted.Add(item)) return;
        var cancellation = new CancellationTokenSource();
        revisionThumbnailLoads[item] = cancellation;
        _ = LoadRevisionThumbnailForItemAsync(item, cancellation);
    }

    private void CancelRevisionThumbnails()
    {
        foreach (var request in revisionThumbnailLoads.Values) request.Cancel();
        revisionThumbnailLoads.Clear();
        revisionThumbnailAttempted.Clear();
    }

    private async Task LoadCurrentThumbnailForItemAsync(
        SaveVersionUiItem item, SaveListItemView model)
    {
        try
        {
            await thumbnailLoadGate.WaitAsync();
            BitmapImage? thumbnail;
            try { thumbnail = await LoadLiveThumbnailAsync(model); }
            finally { thumbnailLoadGate.Release(); }
            if (RevisionItems.Contains(item)
                && StringComparer.Ordinal.Equals(item.ThumbnailKey, model.ThumbnailKey))
                item.Thumbnail = thumbnail;
        }
        catch (Exception exception) { System.Diagnostics.Debug.WriteLine(exception); }
    }

    private async Task LoadRevisionThumbnailForItemAsync(
        SaveVersionUiItem item, CancellationTokenSource cancellation)
    {
        var sourceId = item.SourceId!.Value;
        var cacheKey = item.ThumbnailKey!;
        var token = cancellation.Token;
        try
        {
            await thumbnailLoadGate.WaitAsync(token);
            BitmapImage? thumbnail;
            try
            {
                token.ThrowIfCancellationRequested();
                var host = App.Host;
                if (host?.Repository is null) return;
                var bytes = await Task.Run(() => host.Thumbnails.ReadRevisionThumbnailAsync(
                    cacheKey, host.Repository, sourceId, item.Revision, token), token);
                token.ThrowIfCancellationRequested();
                thumbnail = bytes is null ? null : await CreateBitmapAsync(bytes);
            }
            finally { thumbnailLoadGate.Release(); }
            if (!token.IsCancellationRequested && RevisionItems.Contains(item) && item.SourceId == sourceId
                && StringComparer.Ordinal.Equals(item.ThumbnailKey, cacheKey))
                item.Thumbnail = thumbnail;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception exception) { System.Diagnostics.Debug.WriteLine(exception); }
        finally
        {
            if (revisionThumbnailLoads.TryGetValue(item, out var current) && current == cancellation)
                revisionThumbnailLoads.Remove(item);
            cancellation.Dispose();
        }
    }

    private void EndDetailLoading()
    {
        detailLoading = false;
        detailProgressDelayTimer.Stop();
        DetailTransitionProgress.Visibility = Visibility.Collapsed;
        ShowLoadingBackups(false);
    }

    private void ResetRevisionScroll()
    {
        var scroll = FindScrollViewer(RevisionList);
        scroll?.ChangeView(null, 0, null, true);
    }

    private void ResetRevisionEntrance()
    {
        revisionEntranceTimer.Stop();
        revisionEntranceInProgress = false;
        foreach (var (container, animations) in revisionEntranceAnimations)
        {
            container.StopAnimation(animations.Fade);
            container.StopAnimation(animations.Rise);
            container.Opacity = 1;
            container.Translation = Vector3.Zero;
        }
        revisionEntranceAnimations.Clear();
    }

    private async Task FadeOutRevisionListAsync()
    {
        ResetRevisionExit();
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        var easing = compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.4f, 0f), new Vector2(1f, 1f));
        var fade = compositor.CreateScalarKeyFrameAnimation();
        fade.Target = "Opacity";
        fade.InsertKeyFrame(0f, 1f);
        fade.InsertKeyFrame(1f, 0f, easing);
        fade.Duration = TimeSpan.FromMilliseconds(RevisionExitDurationMs);
        revisionExitFade = fade;
        // 완료 후 교체 시점까지 기존 행이 다시 번쩍 나타나지 않게 최종 값을 유지합니다.
        RevisionList.Opacity = 0;
        RevisionList.StartAnimation(fade);
        await Task.Delay(RevisionExitDurationMs);
    }

    private void ResetRevisionExit()
    {
        if (revisionExitFade is not null)
        {
            RevisionList.StopAnimation(revisionExitFade);
            revisionExitFade = null;
        }
        RevisionList.Opacity = 1;
    }

    private void AnimateVisibleRevisionRows()
    {
        var compositor = CompositionTarget.GetCompositorForCurrentThread();
        var easing = compositor.CreateCubicBezierEasingFunction(
            new Vector2(0.2f, 0f), new Vector2(0f, 1f));
        var visibleIndex = 0;
        for (var index = 0; index < Math.Min(RevisionItems.Count, 16); index++)
        {
            if (RevisionList.ContainerFromIndex(index) is not ListViewItem container
                || container.ActualHeight <= 0
                || revisionEntranceAnimations.ContainsKey(container)) continue;
            var position = container.TransformToVisual(RevisionList)
                .TransformPoint(new Windows.Foundation.Point(0, 0));
            if (position.Y + container.ActualHeight <= 0
                || position.Y >= RevisionList.ActualHeight) continue;

            var stagger = Math.Min(visibleIndex++, RevisionEntranceStaggerRows)
                * RevisionEntranceStaggerMs;
            var duration = RevisionEntranceDurationMs + stagger;
            var fade = compositor.CreateScalarKeyFrameAnimation();
            fade.Target = "Opacity";
            fade.InsertKeyFrame(0f, 0f);
            if (stagger > 0) fade.InsertKeyFrame((float)stagger / duration, 0f);
            fade.InsertKeyFrame(1f, 1f, easing);
            fade.Duration = TimeSpan.FromMilliseconds(duration);

            var rise = compositor.CreateVector3KeyFrameAnimation();
            rise.Target = "Translation";
            rise.InsertKeyFrame(0f, new Vector3(0, RevisionEntranceRisePx, 0));
            if (stagger > 0)
                rise.InsertKeyFrame((float)stagger / duration,
                    new Vector3(0, RevisionEntranceRisePx, 0));
            rise.InsertKeyFrame(1f, Vector3.Zero, easing);
            rise.Duration = fade.Duration;

            container.Opacity = 1;
            container.Translation = Vector3.Zero;
            container.StartAnimation(fade);
            container.StartAnimation(rise);
            revisionEntranceAnimations.Add(container, (fade, rise));
        }
    }

    private void RevealRevisionSelectionIfReady()
    {
        // Called on every layout pass in the window: nothing to do once the bar is shown.
        if (RevisionSelectionLayer.Visibility == Visibility.Visible) return;
        if (detailLoading || revisionEntranceInProgress
            || RevisionList.Visibility != Visibility.Visible
            || RevisionList.SelectedItem is not { } selected
            || RevisionList.ContainerFromItem(selected) is not ListViewItem)
            return;
        RevisionSelectionLayer.Visibility = Visibility.Visible;
    }

    private static ScrollViewer? FindScrollViewer(DependencyObject root)
    {
        if (root is ScrollViewer scroll) return scroll;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            if (FindScrollViewer(VisualTreeHelper.GetChild(root, index)) is { } child)
                return child;
        return null;
    }

    private BackupSourceView? FindBackupSource(string saveId)
    {
        var catalog = App.Host?.Views.ReadIfChanged<BackupCatalogView>(
            ViewKey.BackupCatalog, 0).Snapshot;
        return catalog?.Sources.FirstOrDefault(source =>
            StringComparer.OrdinalIgnoreCase.Equals(source.SaveId, saveId));
    }

    private async Task<BitmapImage?> LoadLiveThumbnailAsync(SaveListItemView save)
    {
        var host = App.Host;
        if (host is null || save.ThumbnailKey is null) return null;
        var bytes = await host.Thumbnails.ReadLiveThumbnailAsync(
            save.ThumbnailKey, save.SourcePath);
        return bytes is null ? null : await CreateBitmapAsync(bytes);
    }

    private static async Task<BitmapImage> CreateBitmapAsync(byte[] bytes)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(bytes);
            await writer.StoreAsync();
            await writer.FlushAsync();
        }
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        return bitmap;
    }

    private void ApplyOperations(OperationsView view)
    {
        var runtime = App.Host?.RuntimeOptions ?? new AppRuntimeOptions();
        var success = TimeSpan.FromSeconds(runtime.SuccessCardSeconds);
        var failure = TimeSpan.FromSeconds(runtime.FailureCardSeconds);
        // Kept as long as a failure card can be on screen (its setting allows two minutes, and a pointer
        // resting on the cards keeps them), so a card never falls back to the generic text while shown.
        var keep = failure + TimeSpan.FromMinutes(5);
        var now = DateTimeOffset.UtcNow;
        foreach (var expired in operationErrors
                     .Where(item => now - item.Value.RecordedUtc > keep)
                     .Select(item => item.Key).ToArray())
            operationErrors.Remove(expired);
        retiredLocalWork.RemoveAll(work => now - work.RetiredUtc > keep);
        notices.RemoveAll(notice => now - notice.ShownUtc > OperationCardLifetime.Of(notice.Status, false, success, failure));
        var cards = OperationCardStack.Build(
            OperationCardStack.Visible(view, retiredLocalWork, now, success, failure),
            localOperation, localOperationBaselineRunIndex, notices: notices);
        if (operationCardsHovered)
        {
            // Keep finished cards that would have left, in their place, until the pointer moves away.
            var kept = cards.ToList();
            for (var index = 0; index < shownOperationCards.Count; index++)
            {
                var previous = shownOperationCards[index];
                if (previous.Operation.Status is OperationStatus.Running or OperationStatus.Waiting
                    || kept.Any(card => card.Key == previous.Key)) continue;
                kept.Insert(Math.Min(index, kept.Count), previous);
            }
            cards = kept;
        }
        else ScheduleOperationCardExpiry(cards, now, success, failure);
        shownOperationCards = cards;
        foreach (var key in operationCardElements.Keys.Except(cards.Select(card => card.Key)).ToArray())
        {
            OperationCards.Children.Remove(operationCardElements[key].Root);
            operationCardElements.Remove(key);
        }
        for (var index = 0; index < cards.Count; index++)
        {
            var card = cards[index];
            if (!operationCardElements.TryGetValue(card.Key, out var elements))
                operationCardElements.Add(card.Key, elements = CreateOperationCard());
            // Keep each card's element so a refresh moves it instead of rebuilding the stack.
            var current = OperationCards.Children.IndexOf(elements.Root);
            if (current < 0) OperationCards.Children.Insert(index, elements.Root);
            else if (current != index) OperationCards.Children.Move((uint)current, (uint)index);
            elements.Title.Text = OperationCardTitle(card);
            ApplyOutcomeIcon(elements.Icon, card.Operation.Status);
            ApplyProgress(elements, card);
        }
        OperationCards.Visibility = cards.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        foreach (var key in operationCardHeights.Keys.Except(cards.Select(card => card.Key)).ToArray())
            operationCardHeights.Remove(key);
        QueueOperationCardFit();
        // Local deletion and background cleanup report no worker progress worth polling for.
        if (cards.Any(card => card.Operation.Status == OperationStatus.Running
                && card.Group is not (OperationCardGroup.DeleteSave or OperationCardGroup.Maintenance)))
            StartOperationProgressRefresh();
        else StopOperationProgressRefresh();
        UpdateOperationActions();
    }

    private void QueueOperationCardFit()
    {
        if (operationCardFitQueued) return;
        operationCardFitQueued = true;
        // After layout, so the menu and the cards report the sizes they actually have.
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            operationCardFitQueued = false;
            FitOperationCards();
        });
    }

    /// <summary>
    /// The menu keeps the room it needs; the cards get what is left. Finished cards that do not fit are left
    /// out, least important and oldest first. Running work and the cards that need attention always stay.
    /// </summary>
    private void FitOperationCards()
    {
        if (!Navigation.IsPaneOpen || OperationCards.Visibility != Visibility.Visible) return;
        menuItemsScroller ??= FindNamedDescendant<ScrollViewer>(Navigation, "MenuItemsScrollViewer");
        if (menuItemsScroller is null || menuItemsScroller.ViewportHeight <= 0) return;
        const double spacing = 8;
        var shown = shownOperationCards
            .Where(card => operationCardElements.ContainsKey(card.Key))
            .Select(card => (Card: card, Root: operationCardElements[card.Key].Root)).ToList();
        foreach (var (card, root) in shown)
            if (root.Visibility == Visibility.Visible && root.ActualHeight > 0)
                operationCardHeights[card.Key] = root.ActualHeight;
        double HeightOf(OperationCard card) => operationCardHeights.GetValueOrDefault(card.Key, 56);
        // What the cards use now plus the menu's spare room; negative spare room means the menu is squeezed.
        var budget = OperationCards.ActualHeight + menuItemsScroller.ViewportHeight - menuItemsScroller.ExtentHeight;
        var total = shown.Sum(item => HeightOf(item.Card)) + spacing * Math.Max(0, shown.Count - 1);
        var hidden = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (card, _) in shown)
        {
            if (total <= budget + 0.5) break;
            if (card.Operation.Status is OperationStatus.Running or OperationStatus.Waiting) continue;
            hidden.Add(card.Key);
            total -= HeightOf(card) + spacing;
        }
        foreach (var (card, root) in shown)
            root.Visibility = hidden.Contains(card.Key) ? Visibility.Collapsed : Visibility.Visible;
    }

    private static T? FindNamedDescendant<T>(DependencyObject root, string name) where T : FrameworkElement
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T match && match.Name == name) return match;
            if (FindNamedDescendant<T>(child, name) is { } found) return found;
        }
        return null;
    }

    // A finished card leaves when its time is up, not only when the next projection happens to arrive.
    private void ScheduleOperationCardExpiry(IReadOnlyList<OperationCard> cards, DateTimeOffset now, TimeSpan success, TimeSpan failure)
    {
        operationCardExpiryTimer.Stop();
        var next = cards
            .Where(card => card.Key != "local" && card.Operation.CompletedUtc is not null
                && card.Operation.Status is not (OperationStatus.Running or OperationStatus.Waiting))
            .Select(card => card.Operation.CompletedUtc!.Value + OperationCardLifetime.Of(card.Operation.Status,
                card.Group == OperationCardGroup.Maintenance, success, failure))
            .DefaultIfEmpty(DateTimeOffset.MaxValue).Min();
        if (next == DateTimeOffset.MaxValue) return;
        operationCardExpiryTimer.Interval = TimeSpan.FromMilliseconds(Math.Max(50, (next - now).TotalMilliseconds + 50));
        operationCardExpiryTimer.Start();
    }

    private OperationCardElements CreateOperationCard()
    {
        // Hierarchy by colour, not weight: Malgun Gothic has no semibold, so SemiBold drew a heavy Bold title.
        var secondary = (Style)Resources["OperationCardSecondaryTextStyle"];
        var icon = new FontIcon { FontSize = 14, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 3, 0, 0) };
        var title = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var percent = new TextBlock { Style = secondary, VerticalAlignment = VerticalAlignment.Top };
        Grid.SetColumn(title, 1);
        Grid.SetColumn(percent, 2);
        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(icon);
        header.Children.Add(title);
        header.Children.Add(percent);
        var progress = new ProgressBar { IsIndeterminate = true };
        // While running: what is happening on the left, how much on the right, always one line each,
        // so the card keeps its height as the numbers change.
        var phase = new TextBlock
        {
            Style = secondary, TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var amount = new TextBlock { Style = secondary, TextWrapping = TextWrapping.NoWrap };
        Grid.SetColumn(amount, 1);
        var detail = new Grid { ColumnSpacing = 8 };
        detail.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        detail.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        detail.Children.Add(phase);
        detail.Children.Add(amount);
        // When finished: why, in at most two lines; the full text stays one hover away.
        var message = new TextBlock
        {
            Style = secondary, TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var content = new StackPanel { Spacing = 6 };
        content.Children.Add(header);
        content.Children.Add(progress);
        content.Children.Add(detail);
        content.Children.Add(message);
        var root = new Border { Style = (Style)Resources["OperationCardStyle"], Child = content };
        return new(root, icon, title, percent, progress, detail, phase, amount, message);
    }

    // Finished work shows its outcome as an icon next to its name; running work has its progress bar instead.
    private void ApplyOutcomeIcon(FontIcon icon, OperationStatus status)
    {
        (string? glyph, string? style) = status switch
        {
            OperationStatus.Succeeded or OperationStatus.NoChange => ("\uE73E", "OperationSucceededIconStyle"),
            OperationStatus.Failed => ("\uE7BA", "OperationFailedIconStyle"),
            OperationStatus.Degraded => ("\uE7BA", "OperationDegradedIconStyle"),
            OperationStatus.Cancelled or OperationStatus.Busy => ("\uE946", "OperationNeutralIconStyle"),
            _ => (null, null),
        };
        icon.Visibility = glyph is null ? Visibility.Collapsed : Visibility.Visible;
        if (glyph is null) return;
        icon.Glyph = glyph;
        icon.Style = (Style)Resources[style!];
    }

    private static string OperationCardTitle(OperationCard card)
    {
        if (card.Title is not null) return card.Title;
        if (card.Operation.Status == OperationStatus.Running)
            return Localizer.Get(card.Group switch
            {
                OperationCardGroup.Backup => "BackingUp.Text",
                OperationCardGroup.Restore => "Restoring",
                OperationCardGroup.Import => "Importing",
                OperationCardGroup.Export => "ExportingDynamic",
                OperationCardGroup.DeleteSave => "DeletingSave",
                OperationCardGroup.CharacterRecovery => "HealCharacterTitle",
                OperationCardGroup.Profile => "ProfileRecordingTitle",
                _ => "MaintenanceRunning",
            });
        // Several finished cards can be stacked, so each one names its work.
        var name = Localizer.Get(card.Group switch
        {
            OperationCardGroup.Backup => "LogActivity.Backup",
            OperationCardGroup.Restore => "LogActivity.Restore",
            OperationCardGroup.Export => "LogActivity.ArchiveExport",
            OperationCardGroup.Import => "LogActivity.ArchiveImport",
            OperationCardGroup.DeleteSave => "DeleteSaveTitle",
            OperationCardGroup.CharacterRecovery => "HealCharacterTitle",
            OperationCardGroup.Profile => "LogActivity.Profile",
            _ => "LogActivity.Maintenance",
        });
        // The outcome is the icon beside the title and, when it needs words, the line below it;
        // repeating it in the title only made the title wrap.
        return card.Operation.Status == OperationStatus.Waiting
            ? $"{name} · {Localizer.Get("OperationCardWaiting")}" : name;
    }

    private void UpdateOperationActions()
    {
        ImportButton.IsEnabled = !HasConflictingOperation();
        if (!IsPreservingDetailActions)
            ManualBackupButton.IsEnabled = SaveList.SelectedItem is SaveListUiItem
                && !detailLoading && !HasConflictingOperation();
        UpdateRevisionActions();
    }

    // 전환이 끝날 때까지 하단 버튼의 이전 표시 상태를 유지합니다.
    // 진행 막대가 나타나도 버튼이 잠깐 비활성화됐다가 다시 켜지지 않게 합니다.
    private bool IsPreservingDetailActions => detailLoading && hasPresentedDetail;

    private void ApplyProgress(OperationCardElements elements, OperationCard card)
    {
        var operation = card.Operation;
        var progress = elements.Progress;
        var display = OperationProgressDisplay.From(operation, projectorHealth?.IsFaulted("telemetry") == true);
        // A hidden indeterminate bar would keep animating on the compositor.
        progress.IsIndeterminate = display.IsVisible && display.IsIndeterminate;
        progress.Visibility = display.IsVisible ? Visibility.Visible : Visibility.Collapsed;
        var telemetryUnavailable = operation.Kind != "delete-save" && (projectorHealth?.IsFaulted("telemetry") == true
            || operation.TelemetryHealth is TelemetryHealth.Unreadable or TelemetryHealth.UnsupportedSchema
                or TelemetryHealth.Stale or TelemetryHealth.Disabled);
        var byteBased = OperationProgressDisplay.UsesBytes(operation);
        if (display.IsVisible && !display.IsIndeterminate)
        {
            progress.Minimum = 0;
            progress.Maximum = byteBased ? operation.TotalBytes!.Value : operation.TotalItems!.Value;
            progress.Value = byteBased
                ? Math.Clamp(operation.CompletedBytes, 0, operation.TotalBytes!.Value)
                : Math.Clamp(operation.CompletedItems, 0, operation.TotalItems!.Value);
        }

        var running = operation.Status == OperationStatus.Running;
        string phase = "", amount = "", percent = "";
        if (running)
        {
            var culture = Localizer.Culture;
            if (telemetryUnavailable) phase = Localizer.Get("TelemetryProgressUnavailable");
            else if (byteBased)
            {
                phase = ProgressPhaseText(operation.Phase, card.Group == OperationCardGroup.Backup);
                amount = string.Format(culture, "{0:N1} / {1:N1} MB",
                    operation.CompletedBytes / 1048576.0, operation.TotalBytes!.Value / 1048576.0);
                percent = string.Format(culture, "{0:N0}%",
                    Math.Floor(Math.Clamp(100.0 * operation.CompletedBytes / operation.TotalBytes.Value, 0, 100)));
            }
            else if (operation.TotalItems is > 0 and var total)
            {
                phase = ProgressPhaseText(operation.Phase, card.Group == OperationCardGroup.Backup);
                amount = string.Format(culture, "{0:N0} / {1:N0}", operation.CompletedItems, total);
                percent = string.Format(culture, "{0:N0}%",
                    Math.Floor(Math.Clamp(100.0 * operation.CompletedItems / total, 0, 100)));
            }
            else phase = operation.CompletedItems > 0
                ? Localizer.Format("OperationDiscoveredFormat", ProgressPhaseText(operation.Phase, card.Group == OperationCardGroup.Backup), operation.CompletedItems)
                : ProgressPhaseText(operation.Phase, card.Group == OperationCardGroup.Backup);
        }
        elements.Percent.Text = percent;
        elements.Percent.Visibility = percent.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        elements.Phase.Text = phase;
        elements.Amount.Text = amount;
        elements.Detail.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        AppToolTip.SetTip(elements.Phase, phase.Length == 0 ? null : phase);

        var message = running ? ""
            : card.Group == OperationCardGroup.Notice ? operation.Message ?? ""
            : (operation.Status is OperationStatus.Failed or OperationStatus.Degraded or OperationStatus.Busy)
            && operationErrors.TryGetValue(operation.OperationId, out var error)
            ? error.Message
            : operation.Status == OperationStatus.Cancelled && card.Group == OperationCardGroup.Maintenance
            ? Localizer.Get("MaintenanceDeferred")
            : operation.Status switch
            {
                // Title and icon already say it; only an action that did something specific adds a line.
                OperationStatus.Succeeded => card.Key == "local" && operation.Message is { } done ? done : "",
                OperationStatus.NoChange => Localizer.Get("OperationNoChange"),
                OperationStatus.Busy => Localizer.Get("OperationBusy"),
                OperationStatus.Cancelled => Localizer.Get("OperationCancelled"),
                OperationStatus.Degraded => Localizer.Get("OperationDegraded"),
                OperationStatus.Waiting => "",
                // Only the app's own card carries a sentence; a worker's card carries a code (such as
                // "progress-unavailable") that is for the logs, never for the screen.
                _ => card.Key == "local" && operation.Message is { } failure ? failure : Localizer.Get("OperationFailed"),
            };
        elements.Message.Text = message;
        // A plain success says everything in its title and icon; the card is one line.
        elements.Message.Visibility = message.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        AppToolTip.SetTip(elements.Message, message.Length == 0 ? null : message);
    }

    private static string ProgressPhaseText(string? phase, bool backup) => phase switch
    {
        "maintenance.revisionreclamation" or "maintenance.artifactcleanup" or "maintenance.orphanbackups"
            or "maintenance.packreclamation"
            => Localizer.Get($"MaintenancePhase.{phase["maintenance.".Length..]}"),
        "profile.recording" => Localizer.Get("ProfilePhaseRecording"),
        "profile.converting" => Localizer.Get("ProfilePhaseConverting"),
        "delete.discover" => Localizer.Get("DeleteSaveDiscoverPhase"),
        "delete.validate" => Localizer.Get("DeleteSaveValidatePhase"),
        "delete.files" => Localizer.Get("DeleteSaveFilesPhase"),
        "delete.backups" => Localizer.Get("DeleteSaveBackupsPhase"),
        "source.prepare" => Localizer.Get("BackupGameSavePhase"),
        "boundary" or "pack" or "commit" => Localizer.Get($"LogPhase.{phase}"),
        "planning" => Localizer.Get("LogPhase.planning"),
        "scan" => Localizer.Get("BackupScanPhase"),
        "hash" => Localizer.Get("BackupHashPhase"),
        "copy" => Localizer.Get("BackupCopyPhase"),
        "copy.retry" => Localizer.Get("BackupCopyRetryPhase"),
        "capture" => Localizer.Get("BackupCapturePhase"),
        "deduplication" => Localizer.Get("BackupDeduplicationPhase"),
        "restore" => Localizer.Get("Restoring"),
        "archive.restore" => Localizer.Get("ArchiveRestorePhase"),
        "archive.snapshot" => Localizer.Get("ArchiveSnapshotPhase"),
        "archive.compress" => Localizer.Get("ArchiveCompressPhase"),
        "archive.finalize" => Localizer.Get("ArchiveFinalizePhase"),
        "import" => Localizer.Get("Importing"),
        // Before a backup reports its first step: its worker is starting and opening the repository.
        null when backup => Localizer.Get("BackupPreparingPhase"),
        _ => Localizer.Get("ProcessingNow"),
    };

    private void RefreshOperationCards()
    {
        var current = App.Host?.Views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot;
        ApplyOperations(current ?? new OperationsView([]));
    }

    private string StartLocalOperationProgress(string kind = "export")
    {
        localOperationCardTimer.Stop();
        var current = App.Host?.Views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot;
        localOperationBaselineRunIndex = current?.Operations.Select(operation => operation.RunIndex)
            .DefaultIfEmpty(0).Max() ?? 0;
        localOperation = new OperationView(
            "local-" + kind, $"local-{kind}:{Guid.NewGuid():N}", kind, kind == "export" ? "archive-worker" : "app", 0,
            OperationStatus.Running, null, 0, null, 0, null,
            TelemetryHealth.Waiting, null, null);
        ApplyOperations(current ?? new OperationsView([]));
        return localOperation.OperationId;
    }

    private void StartOperationProgressRefresh()
    {
        if (operationProgressRefreshCancellation is not null) return;
        var host = App.Host;
        if (host is null) return;
        var cancellation = new CancellationTokenSource();
        operationProgressRefreshCancellation = cancellation;
        _ = Task.Run(async () =>
        {
            try
            {
                // One shared refresh loop while work is active; keep the idle cadence unchanged.
                while (true)
                {
                    await Task.Delay(host.RuntimeOptions.ExportProgressIntervalMs, cancellation.Token);
                    try { await host.Projections.ProjectNowAsync("telemetry", cancellation.Token); }
                    catch (Exception) when (!cancellation.IsCancellationRequested)
                    {
                        // The regular projection loop reports health; retry at the same bounded cadence.
                    }
                }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            finally { cancellation.Dispose(); }
        });
    }

    private void StopOperationProgressRefresh()
    {
        try { operationProgressRefreshCancellation?.Cancel(); }
        catch (ObjectDisposedException) { }
        operationProgressRefreshCancellation = null;
    }

    private void CompleteLocalOperationProgress(
        OperationStatus status, string? operationId = null, long runIndex = 0, string? error = null)
    {
        if (localOperation is null) return;
        localOperation = localOperation with
        {
            OperationId = operationId ?? localOperation.OperationId,
            RunIndex = runIndex,
            Status = status,
            Message = error,
            CompletedUtc = DateTimeOffset.UtcNow,
        };
        if (!string.IsNullOrWhiteSpace(error))
            operationErrors[localOperation.OperationId] = (error, DateTimeOffset.UtcNow);
        RefreshOperationCards();
        var runtime = App.Host?.RuntimeOptions ?? new AppRuntimeOptions();
        localOperationCardTimer.Interval = TimeSpan.FromSeconds(status is OperationStatus.Succeeded or OperationStatus.NoChange
            ? runtime.SuccessCardSeconds : runtime.FailureCardSeconds);
        localOperationCardTimer.Start();
    }

    private async Task<AppOperationResult> RunWithProgressAsync(string kind, Func<string, Task<AppOperationResult>> action)
    {
        var operationId = StartLocalOperationProgress(kind);
        try
        {
            // Worker dispatch and its synchronous setup must not hold the first UI render.
            var result = await Task.Run(() => action(operationId));
            CompleteLocalOperationProgress(result.Outcome switch
            {
                PzTools.Process.Contracts.ProcessOutcome.Succeeded => OperationStatus.Succeeded,
                PzTools.Process.Contracts.ProcessOutcome.NoChange => OperationStatus.NoChange,
                PzTools.Process.Contracts.ProcessOutcome.Busy => OperationStatus.Busy,
                PzTools.Process.Contracts.ProcessOutcome.Cancelled => OperationStatus.Cancelled,
                PzTools.Process.Contracts.ProcessOutcome.Degraded => OperationStatus.Degraded,
                _ => OperationStatus.Failed,
            }, result.OperationId, result.RunIndex,
                result.Outcome is PzTools.Process.Contracts.ProcessOutcome.Failed
                    or PzTools.Process.Contracts.ProcessOutcome.Degraded
                    ? UserFacingError.FromProcessError(result.ErrorMessage ?? result.Error) : null);
            return result;
        }
        catch (Exception exception)
        {
            CompleteLocalOperationProgress(OperationStatus.Failed, error: UserFacingError.FromException(exception));
            // The work's own card now shows the failure; callers must not report it a second time.
            throw new ReportedOnCardException(exception);
        }
    }

    /// <summary>A failure already shown on the card of the work that failed.</summary>
    private sealed class ReportedOnCardException(Exception inner) : Exception(inner.Message, inner);

    /// <summary>Replaces the generic "done" on the card of the work just finished with what was done.</summary>
    private void SetLocalResultMessage(string operationId, string message)
    {
        if (localOperation?.OperationId != operationId || localOperation.Status == OperationStatus.Running) return;
        localOperation = localOperation with { Message = message };
        RefreshOperationCards();
    }

    // Not a piece of work but something for the user to act on: it never expires. It leaves when the
    // user closes it or Windows stops blocking, and comes back only if a different set gets blocked.
    private void ApplyBlockedComponents(BlockedComponentsView view)
    {
        blockedComponents = view;
        var signature = string.Join("|", view.Components);
        if (view.Components.Count == 0) dismissedBlockedComponents = null;
        ComponentBlockedCard.Visibility = view.Components.Count == 0 || signature == dismissedBlockedComponents
            ? Visibility.Collapsed : Visibility.Visible;
        ComponentBlockedTitle.Text = Localizer.Get("ComponentBlockedTitle");
        ComponentBlockedMessage.Text = Localizer.Format("ComponentBlockedMessage", string.Join(", ", view.Components));
        ComponentBlockedOpenButton.Content = Localizer.Get("CardOpenSettings");
        ComponentBlockedCloseButton.Content = Localizer.Get("CardAcknowledge");
        UpdateInteractiveCards();
    }

    // Shown once per outage: it explains why backups now run without the game. Closing it keeps it
    // closed until the game has been readable again and is lost anew; the schedule line keeps saying so.
    private void ApplyGameLink(GameLinkView view)
    {
        gameLink = view;
        SettingsRoot.ApplyGameLink(view);
        if (!view.LinkUnavailable) gameLinkDismissed = false;
        GameLinkCard.Visibility = view.LinkUnavailable && !gameLinkDismissed ? Visibility.Visible : Visibility.Collapsed;
        GameLinkTitle.Text = Localizer.Get("GameLinkCardTitle");
        GameLinkMessage.Text = Localizer.Get(view.RestartRequired ? "GameLinkCardRestartMessage" : "GameLinkCardMessage");
        GameLinkCloseButton.Content = Localizer.Get("CardAcknowledge");
        UpdateInteractiveCards();
    }

    private void GameLinkClose_Click(object sender, RoutedEventArgs e)
    {
        gameLinkDismissed = true;
        GameLinkCard.Visibility = Visibility.Collapsed;
        UpdateInteractiveCards();
    }

    private void UpdateInteractiveCards() =>
        InteractiveCards.Visibility = InteractiveCards.Children.Any(card => card.Visibility == Visibility.Visible)
            ? Visibility.Visible : Visibility.Collapsed;

    private void ComponentBlockedClose_Click(object sender, RoutedEventArgs e)
    {
        dismissedBlockedComponents = string.Join("|", blockedComponents?.Components ?? []);
        ComponentBlockedCard.Visibility = Visibility.Collapsed;
        UpdateInteractiveCards();
    }

    private void ComponentBlockedOpen_Click(object sender, RoutedEventArgs e)
    {
        // Opens the Smart App Control page of Windows Security; the app changes no security setting itself.
        try
        {
            using var _ = System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo("windowsdefender://smartapp/") { UseShellExecute = true });
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception
            or InvalidOperationException or System.IO.FileNotFoundException)
        {
            ShowActionError(Localizer.Get("ComponentBlockedTitle"), exception);
        }
    }

    private void ApplyProjectorHealth()
    {
        UpdateSaveListPlaceholder();
        if (projectorHealth?.IsFaulted("telemetry") == true)
            LogsRoot.ShowLoadFailure();
        var faults = projectorHealth?.Projectors
            .Where(item => item.Health == ProjectorHealth.Faulted).ToArray() ?? [];
        ProjectorStatusCard.Visibility = faults.Length == 0
            ? Visibility.Collapsed : Visibility.Visible;
        UpdateInteractiveCards();
        ProjectorStatusMessage.Text = Localizer.Format(
            "ProjectorStatusMessage", string.Join(", ", faults.Select(item => item.Name switch
            {
                "state" => Localizer.Get("ProjectorArea.State"),
                "backup" => Localizer.Get("ProjectorArea.Backup"),
                "scheduler" => Localizer.Get("ProjectorArea.Schedule"),
                "details" => Localizer.Get("ProjectorArea.Details"),
                "telemetry" => Localizer.Get("ProjectorArea.Logs"),
                _ => Localizer.Get("ProjectorArea.Other"),
            })));
        var operations = App.Host?.Views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot;
        if (operations is not null) ApplyOperations(operations);
        UpdateCountdown();
        UpdateRevisionActions();
    }

    private bool HasConflictingOperation() => archiveInteraction || OtherOperationRunning();

    // Work started elsewhere (a scheduled backup, another window's action), apart from this page's own lock.
    private bool OtherOperationRunning() =>
        projectorHealth?.IsFaulted("telemetry") != true
        && App.Host?.Views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot?.Operations
            // A recording only watches the game; it holds no save and no repository.
            .Any(operation => operation.Status == OperationStatus.Running && operation.Kind != "profile") == true;

    private void ShowLoadingBackups(bool visible)
    {
        LoadingBackups.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        // A collapsed ProgressRing keeps its animation running on the compositor, which then wakes every
        // display refresh even with the window minimised. It runs only while it can be seen.
        LoadingBackupsProgress.IsActive = visible;
    }
    private readonly CountdownDisplayStabilizer countdownStabilizer = new();

    private void UpdateCountdown(bool tick = false)
    {
        var now = DateTimeOffset.UtcNow;
        var display = countdownStabilizer.Apply(ScheduleCountdownPresentation.Resolve(schedule, now,
            projectorHealth?.IsFaulted("scheduler") == true), now);
        // Assign only what changed: even an equal string makes the window draw a frame, every second, for as
        // long as the app runs (also minimised or in the tray).
        SetText(NextBackupText, Localizer.Get(display.MessageKey));
        SetText(NextBackupRemainingText, display.RemainingSeconds is { } seconds
            ? Localizer.Format("BackupTimeRemainingFormat", $"{seconds / 60:00}:{seconds % 60:00}") : "");
        var remainingVisibility = display.RemainingSeconds is null ? Visibility.Collapsed : Visibility.Visible;
        if (NextBackupRemainingText.Visibility != remainingVisibility) NextBackupRemainingText.Visibility = remainingVisibility;
        UpdateCountdownPulse(display.Suspended, display.RemainingSeconds is not null, tick);

        static void SetText(TextBlock block, string value)
        {
            if (!string.Equals(block.Text, value, StringComparison.Ordinal)) block.Text = value;
        }
    }

    private void Navigation_SelectionChanged(
        NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var page = args.IsSettingsSelected ? (FrameworkElement)SettingsRoot
            : (args.SelectedItem as NavigationViewItem)?.Tag?.ToString() switch
            {
                "home" => HomeRoot,
                "logs" => LogsRoot,
                "game-extensions" => GameExtensionsRoot,
                "profiler" => ProfilerRoot,
                _ => SavesRoot,
            };
        NavigateToContent(page);
    }

    private void HomeRoot_NavigationRequested(object? sender, HomeDestination destination)
    {
        Navigation.SelectedItem = destination switch
        {
            HomeDestination.Settings => Navigation.SettingsItem,
            HomeDestination.Extensions => GameExtensionsItem,
            HomeDestination.Profiler => ProfilerItem,
            _ => SavesItem,
        };
        if (destination == HomeDestination.Saves)
            SaveList.SelectedItem ??= SaveItems.FirstOrDefault();
    }

    private void Navigation_DisplayModeChanged(NavigationView sender, NavigationViewDisplayModeChangedEventArgs args)
        => ApplyNavigationSpacing();

    private void Navigation_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer != SavesItem) return;
        // Returning to this page must not reset selection or start a new detail load.
        SaveList.SelectedItem ??= SaveItems.FirstOrDefault();
    }

    private void Navigation_PaneChanged(NavigationView sender, object args)
    {
        ApplyNavigationSpacing();
        QueueOperationCardFit();
    }

    private void ApplyNavigationSpacing()
    {
        if (Navigation is null) return;
        // 선택 표시줄을 창 가장자리에서 띄웁니다. 축소 모드에서는 아이콘 공간을 보존합니다.
        var expanded = Navigation.IsPaneOpen;
        // 기본 템플릿이 세로 2px 여백을 이미 제공하므로 중복해서 더하지 않습니다.
        var margin = expanded ? new Thickness(12, 0, 12, 0) : new Thickness(0);
        // 메뉴에 있는 항목 전부에 같은 여백을 줍니다. 항목을 추가해도 여기를 고칠 필요가 없습니다.
        foreach (var item in Navigation.MenuItems.OfType<NavigationViewItem>())
            item.Margin = margin;
        if (AppBrand is not null && BrandImage is not null && BrandCopy is not null && BrandHeaderSpace is not null)
        {
            AppBrand.Margin = expanded ? new Thickness(24, 20, 12, 0) : new Thickness(8, 8, 8, 0);
            AppBrand.Width = Math.Max(32, (expanded ? Navigation.OpenPaneLength : Navigation.CompactPaneLength)
                - AppBrand.Margin.Left - AppBrand.Margin.Right);
            BrandImage.Width = BrandImage.Height = expanded ? 56 : 32;
            BrandCopy.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            BrandHeaderSpace.Height = expanded ? 48 : 16;
        }
        if (CoffeeSupportArea is not null && CoffeeSupportCopy is not null)
        {
            CoffeeSupportArea.Margin = expanded ? new Thickness(12, 8, 12, 4) : new Thickness(4, 8, 4, 4);
            CoffeeSupportCopy.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            CoffeeSupportButton.Padding = expanded ? new Thickness(10) : new Thickness(8);
        }
        if (Navigation.SettingsItem is NavigationViewItem settings)
            settings.Margin = expanded ? new Thickness(12, 0, 12, 8) : new Thickness(0, 0, 0, 8);
        if (ProgressCards is not null)
            ProgressCards.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SavesRoot_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        narrow = e.NewSize.Width < 860;
        var compactHeader = narrow && e.NewSize.Width < 390;
        SavesHeader.RowSpacing = compactHeader ? 8 : 0;
        Grid.SetRow(SavesHeaderActions, compactHeader ? 1 : 0);
        Grid.SetColumn(SavesHeaderActions, compactHeader ? 0 : 1);
        Grid.SetColumnSpan(SavesHeaderActions, compactHeader ? 2 : 1);
        var compactDetailHeader = narrow && e.NewSize.Width < 520;
        BackupRevisionsHeader.RowSpacing = compactDetailHeader ? 8 : 0;
        Grid.SetRow(BackupRevisionsActions, compactDetailHeader ? 1 : 0);
        Grid.SetColumn(BackupRevisionsActions, compactDetailHeader ? 0 : 1);
        Grid.SetColumnSpan(BackupRevisionsActions, compactDetailHeader ? 2 : 1);
        SavesRoot.ColumnSpacing = narrow ? 0 : 12;
        if (!narrow)
        {
            ListPane.Visibility = Visibility.Visible;
            DetailPane.Visibility = Visibility.Visible;
            NarrowBackButton.Visibility = Visibility.Collapsed;
            ListColumn.MinWidth = 320;
            ListColumn.Width = new GridLength(420);
            DetailColumn.Width = new GridLength(1, GridUnitType.Star);
        }
        else
        {
            ListColumn.Width = new GridLength(1, GridUnitType.Star);
            ShowNarrowDetail(selectedSaveId is not null);
        }
    }

    private void DetailPane_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Width < 520;
        RightDetailActions.Orientation = compact ? Orientation.Vertical : Orientation.Horizontal;
        foreach (var button in RightDetailActions.Children.OfType<Button>())
            button.HorizontalAlignment = HorizontalAlignment.Right;
    }

    private void ShowNarrowDetail(bool detail)
    {
        if (!narrow) return;
        ListColumn.MinWidth = 0;
        ListColumn.Width = detail
            ? new GridLength(0)
            : new GridLength(1, GridUnitType.Star);
        DetailColumn.Width = detail
            ? new GridLength(1, GridUnitType.Star)
            : new GridLength(0);
        ListPane.Visibility = detail ? Visibility.Collapsed : Visibility.Visible;
        DetailPane.Visibility = detail ? Visibility.Visible : Visibility.Collapsed;
        NarrowBackButton.Visibility = detail ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SaveList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        CancelRevisionThumbnails();
        if (SaveList.SelectedItem is not SaveListUiItem selected)
        {
            UpdateRevisionActions();
            return;
        }
        ResetRevisionEntrance();
        ResetRevisionExit();
        revisionInsertionAnimator.Reset();
        selectedSaveId = selected.SaveId;
        selectedDetailRevision = 0;
        detailApplyGeneration++;
        detailLoading = true;
        RevisionList.IsHitTestVisible = false;
        RevisionSelectionLayer.Visibility = Visibility.Collapsed;
        if (hasPresentedDetail)
        {
            // Keep the previous detail visible until the new thumbnail and metadata are ready.
            ShowLoadingBackups(false);
            if (DetailTransitionProgress.Visibility != Visibility.Visible)
                detailProgressDelayTimer.Start();
        }
        else
        {
            RevisionList.SelectedItem = null;
            RevisionItems.Clear();
            ShowLoadingBackups(true);
            RevisionList.Visibility = Visibility.Collapsed;
            NoBackups.Visibility = Visibility.Collapsed;
        }
        NoSelection.Visibility = Visibility.Collapsed;
        DetailContent.Visibility = Visibility.Visible;
        ShowNarrowDetail(true);
        RefreshSelectedDetail();
        UpdateRevisionActions();
    }

    private void NarrowBackButton_Click(object sender, RoutedEventArgs e) => ShowNarrowDetail(false);

    private void RevisionList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateRevisionActions();
    }

    private void UpdateRevisionActions()
    {
        var idle = !HasConflictingOperation();
        foreach (var item in SaveItems)
        {
            item.CanDelete = idle && item.IsFresh && item.Activity == ActivityState.Inactive
                && projectorHealth?.IsFaulted("state") != true;
            item.DeleteTooltip = item.IsFresh && item.Activity == ActivityState.Active
                ? Localizer.Get("StopPlayingToDeleteSave") : item.DeleteLabel;
        }
        // 이전 버튼 모양을 유지하되, 실행 핸들러는 detailLoading으로 차단합니다.
        if (IsPreservingDetailActions) return;
        idle &= !detailLoading;
        foreach (var item in RevisionItems)
            item.CanDelete = idle && !item.IsCurrent && item.SourceId is not null
                && projectorHealth?.IsFaulted("backup") != true;
        var selected = RevisionList.SelectedItem as SaveVersionUiItem;
        var backupFaulted = projectorHealth?.IsFaulted("backup") == true;
        var stateFaulted = projectorHealth?.IsFaulted("state") == true;
        var selectedSave = SaveList.SelectedItem as SaveListUiItem;
        foreach (var item in RevisionItems)
        {
            item.CanHeal = idle && item.IsCurrent && !stateFaulted && !backupFaulted
                && selectedSave is { IsFresh: true, Activity: ActivityState.Inactive }
                && StringComparer.OrdinalIgnoreCase.Equals(item.SaveId, selectedSave.SaveId);
            item.HealTooltip = item.IsCurrent && selectedSave is { IsFresh: true, Activity: ActivityState.Active }
                && StringComparer.OrdinalIgnoreCase.Equals(item.SaveId, selectedSave.SaveId)
                ? Localizer.Get("StopPlayingToHeal") : item.HealLabel;
        }
        var backupSource = selectedSave is null ? null : FindBackupSource(selectedSave.SaveId);
        DeleteAllBackupsButton.IsEnabled = idle && !backupFaulted
            && backupSource is { Revisions.Count: > 0 };
        AppToolTip.SetTip(DeleteAllBackupsButton, selectedSave is null
            ? Localizer.Get("DeleteAllBackupsButton")
            : Localizer.Format("DeleteAllBackupsTooltip", selectedSave.Name));
        var liveActive = SaveList.SelectedItem is SaveListUiItem save
                         && save.Activity == ActivityState.Active;
        ExportButton.IsEnabled = selected is not null && idle
            && (selected.IsCurrent ? !stateFaulted && !liveActive : !backupFaulted && selected.SourceId is not null);
        var exportReason = selected?.IsCurrent == true && liveActive
            ? Localizer.Get("StopPlayingToExport") : null;
        AppToolTip.SetTip(ExportToolTipHost, exportReason);
        AutomationProperties.SetHelpText(ExportButton, exportReason ?? string.Empty);
        RestoreButton.IsEnabled = selected is { IsCurrent: false, SourceId: not null } && !liveActive && !stateFaulted
            && !backupFaulted && idle;
        var restoreReason = selected is { IsCurrent: false, SourceId: not null } && liveActive
            ? Localizer.Get("StopPlayingToRestore") : null;
        // A restore needs a backup: say so when the current save, or nothing, is selected.
        restoreReason ??= selected is null or { IsCurrent: true } ? Localizer.Get("SelectBackupToRestore") : null;
        AppToolTip.SetTip(RestoreToolTipHost, restoreReason);
        AutomationProperties.SetHelpText(RestoreButton, restoreReason ?? string.Empty);
    }

    private async void DeleteSave_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not SaveListUiItem save
            || !save.CanDelete || App.Host?.Operations is null || HasConflictingOperation()) return;
        var host = App.Host;
        var root = host.ActiveSavesRoot;
        if (root is null) return;
        string? progressId = null;
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = Localizer.Get("DeleteSaveTitle"),
                Content = Localizer.Format("DeleteSaveConfirmation", save.Name, save.SourcePath),
                PrimaryButtonText = Localizer.Get("DeleteAction"), CloseButtonText = Localizer.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var current = SaveItems.FirstOrDefault(item => item.SaveId == save.SaveId);
            if (App.Host != host || current is null || !current.IsFresh
                || current.Activity != ActivityState.Inactive || projectorHealth?.IsFaulted("state") == true)
                throw new InvalidOperationException(Localizer.Get("DeleteSaveUnavailable"));
            var expectedPath = System.IO.Path.GetFullPath(System.IO.Path.Combine(root, save.SaveId));
            if (!StringComparer.OrdinalIgnoreCase.Equals(expectedPath, System.IO.Path.GetFullPath(save.SourcePath)))
                throw new InvalidOperationException(Localizer.Get("DeleteSaveUnavailable"));
            progressId = StartLocalOperationProgress("delete-save");
            var progress = new LatestProgress<SaveDeletionProgress>();
            var progressTimer = DispatcherQueue.CreateTimer();
            progressTimer.Interval = TimeSpan.FromMilliseconds(host.RuntimeOptions.ExportProgressIntervalMs);
            void ApplyLatestDeletionProgress()
            {
                var value = progress.TakeLatest();
                if (value is null || localOperation?.OperationId != progressId
                    || localOperation.Status != OperationStatus.Running) return;
                localOperation = localOperation with { Phase = value.Phase switch
                {
                    SaveDeletionPhase.Discovering => "delete.discover",
                    SaveDeletionPhase.Validating => "delete.validate",
                    SaveDeletionPhase.DeletingFiles => "delete.files",
                    SaveDeletionPhase.DeletingBackups => "delete.backups",
                    _ => null,
                }, CompletedItems = value.CompletedItems, TotalItems = value.TotalItems,
                    TelemetryHealth = TelemetryHealth.Healthy };
                RefreshOperationCards();
            }
            progressTimer.Tick += (_, _) => ApplyLatestDeletionProgress();
            progressTimer.Start();
            try
            {
                await Task.Run(() => host.Operations!.DeleteSaveAsync(root, save.SaveId, progress: progress));
                ApplyLatestDeletionProgress();
            }
            finally { progressTimer.Stop(); }
            CompleteLocalOperationProgress(OperationStatus.Succeeded);
            await RefreshAfterMutationAsync(host, Localizer.Get("DeleteSaveTitle"),
                Localizer.Get("SaveDeletedPermanently"), showSuccessNotification: false);
        }
        catch (SaveBackupDeletionFailedException)
        {
            if (progressId is not null)
                CompleteLocalOperationProgress(OperationStatus.Failed, error: Localizer.Get("SaveBackupDeletionFailed"));
            else ShowActionError(Localizer.Get("DeleteSaveTitle"), Localizer.Get("SaveBackupDeletionFailed"));
        }
        catch (Exception exception)
        {
            if (progressId is not null)
                CompleteLocalOperationProgress(OperationStatus.Failed, error: UserFacingError.FromException(exception));
            else ShowActionError(Localizer.Get("DeleteSaveTitle"), exception);
        }
        finally { archiveInteraction = false; UpdateOperationActions(); }
    }

    private async void DeleteRevision_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not SaveVersionUiItem revision
            || !revision.CanDelete || revision.SourceId is null || App.Host?.Operations is null
            || detailLoading || !StringComparer.OrdinalIgnoreCase.Equals(revision.SaveId, selectedSaveId)
            || HasConflictingOperation()) return;
        var host = App.Host;
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = Localizer.Get("DeleteRevisionTitle"),
                Content = Localizer.Format("DeleteRevisionConfirmation", revision.SaveId, revision.RevisionText),
                PrimaryButtonText = Localizer.Get("DeleteAction"), CloseButtonText = Localizer.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            if (detailLoading || App.Host != host
                || !StringComparer.OrdinalIgnoreCase.Equals(revision.SaveId, selectedSaveId)
                || !ReferenceEquals(RevisionList.SelectedItem, revision)
                || projectorHealth?.IsFaulted("backup") == true)
                throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            await host.Operations!.DeleteRevisionAsync(revision.SourceId.Value, revision.Revision);
            await RefreshAfterMutationAsync(host, Localizer.Get("DeleteRevisionTitle"),
                Localizer.Get("RevisionDeleted"), collectState: false);
        }
        catch (Exception exception) { ShowActionError(Localizer.Get("DeleteRevisionTitle"), exception); }
        finally { archiveInteraction = false; UpdateOperationActions(); }
    }

    private async void DeleteAllBackupsButton_Click(object sender, RoutedEventArgs e)
    {
        if (detailLoading || SaveList.SelectedItem is not SaveListUiItem save
            || FindBackupSource(save.SaveId) is not { Revisions.Count: > 0 } source
            || App.Host?.Operations is null || HasConflictingOperation()
            || projectorHealth?.IsFaulted("backup") == true) return;
        var host = App.Host;
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = Localizer.Get("DeleteAllBackupsTitle"),
                Content = Localizer.Format("DeleteAllBackupsConfirmation", save.Name, source.Revisions.Count),
                PrimaryButtonText = Localizer.Get("DeleteAction"),
                CloseButtonText = Localizer.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var currentSource = FindBackupSource(save.SaveId);
            if (detailLoading || App.Host != host || SaveList.SelectedItem is not SaveListUiItem selected
                || !StringComparer.OrdinalIgnoreCase.Equals(selected.SaveId, save.SaveId)
                || currentSource is null || currentSource.SourceId != source.SourceId
                || currentSource.Revisions.Count == 0
                || projectorHealth?.IsFaulted("backup") == true)
                throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            await host.Operations!.DeleteAllRevisionsAsync(source.SourceId, save.SaveId);
            await RefreshAfterMutationAsync(host, Localizer.Get("DeleteAllBackupsTitle"),
                Localizer.Get("AllBackupsDeleted"), collectState: false);
        }
        catch (Exception exception) { ShowActionError(Localizer.Get("DeleteAllBackupsTitle"), exception); }
        finally { archiveInteraction = false; UpdateOperationActions(); }
    }

    private void RenameRevision_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.DataContext is not SaveVersionUiItem revision
            || !revision.CanDelete || revision.SourceId is null || App.Host?.Operations is null
            || detailLoading || !StringComparer.OrdinalIgnoreCase.Equals(revision.SaveId, selectedSaveId)
            || HasConflictingOperation()) return;
        var editor = (button.Parent as Grid)?.Children.OfType<TextBox>().FirstOrDefault();
        if (editor is null) return;
        revision.IsEditing = true;
        editor.Text = revision.RevisionText;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!revision.IsEditing) return;
            editor.Focus(FocusState.Programmatic);
            editor.SelectionStart = editor.Text.Length;
            editor.SelectionLength = 0;
        });
    }

    private void RevisionNameEditor_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (sender is not TextBox editor) return;
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            _ = CommitRevisionNameAsync(editor);
            DispatcherQueue.TryEnqueue(() => RevisionList.Focus(FocusState.Pointer));
        }
        else if (e.Key == Windows.System.VirtualKey.Escape)
        {
            e.Handled = true;
            if (editor.DataContext is SaveVersionUiItem revision) revision.IsEditing = false;
            DispatcherQueue.TryEnqueue(() => RevisionList.Focus(FocusState.Pointer));
        }
    }

    private void RevisionNameEditor_LostFocus(object sender, RoutedEventArgs e)
    {
        if (sender is TextBox editor) _ = CommitRevisionNameAsync(editor);
    }

    private void RevisionNameClear_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || button.DataContext is not SaveVersionUiItem revision
            || !revision.IsEditing) return;
        var editor = (button.Parent as Grid)?.Children.OfType<TextBox>().FirstOrDefault();
        if (editor is null) return;
        editor.Text = string.Empty;
        editor.Focus(FocusState.Programmatic);
    }

    private async Task CommitRevisionNameAsync(TextBox editor)
    {
        if (editor.DataContext is not SaveVersionUiItem revision || !revision.IsEditing) return;
        var name = string.IsNullOrWhiteSpace(editor.Text)
            ? revision.NamePlaceholderText
            : editor.Text.Trim();
        var previousName = revision.RevisionText;
        if (name == previousName)
        {
            revision.IsEditing = false;
            return;
        }
        var host = App.Host;
        if (detailLoading || !StringComparer.OrdinalIgnoreCase.Equals(revision.SaveId, selectedSaveId)
            || revision.SourceId is null || host?.Operations is null || HasConflictingOperation())
        {
            revision.IsEditing = false;
            return;
        }
        archiveInteraction = true;
        UpdateOperationActions();
        revision.SetRevisionName(name);
        revision.IsEditing = false;
        try
        {
            if (App.Host != host || projectorHealth?.IsFaulted("backup") == true)
                throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            await host.Operations!.RenameRevisionAsync(
                revision.SourceId.Value, revision.Revision, name);
            await RefreshAfterMutationAsync(host, Localizer.Get("RenameRevisionTitle"),
                Localizer.Get("RevisionRenamed"), collectState: false);
        }
        catch (Exception exception)
        {
            revision.SetRevisionName(previousName);
            ShowActionError(Localizer.Get("RenameRevisionTitle"), exception);
        }
        finally { archiveInteraction = false; UpdateOperationActions(); }
    }

    private async void ImportButton_Click(object sender, RoutedEventArgs e)
    {
        var host = App.Host;
        var operations = host?.Operations;
        if (operations is null || HasConflictingOperation()) return;
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            // Windows App SDK 선택기는 관리자 권한 실행도 지원합니다.
            var picker = new FileOpenPicker(App.MainWindow.AppWindow.Id);
            picker.FileTypeFilter.Add(".zip");
            picker.FileTypeFilter.Add(".pzsave");
            var file = await picker.PickSingleFileAsync();
            if (file is null) return;
            var inspectionCancellation = new CancellationTokenSource();
            var loading = new Grid
            {
                Width = Math.Max(180, Math.Min(640, XamlRoot.Size.Width - 96)),
                MinHeight = 180,
            };
            var loadingContents = new StackPanel
            {
                Spacing = 16,
                VerticalAlignment = VerticalAlignment.Center,
            };
            loadingContents.Children.Add(new TextBlock
            {
                Text = Localizer.Get("InspectingArchive"),
                Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
                TextWrapping = TextWrapping.Wrap,
            });
            loadingContents.Children.Add(new ProgressBar { IsIndeterminate = true });
            loading.Children.Add(loadingContents);
            var dialog = new ImportPreviewDialog
            {
                XamlRoot = XamlRoot,
                Title = Localizer.Get("ConfirmImportTitle"),
                Content = loading,
                PrimaryButtonText = Localizer.Get("Import"),
                IsPrimaryButtonEnabled = false,
                CloseButtonText = Localizer.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            dialog.Resources["ContentDialogMaxWidth"] = 720d;
            dialog.Resources["ContentDialogTitleMargin"] = new Thickness(0, 0, 0, 24);
            var opened = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var dialogClosed = false;
            dialog.Opened += (_, _) => opened.TrySetResult();
            dialog.Closed += (_, _) =>
            {
                dialogClosed = true;
                inspectionCancellation.Cancel();
            };
            var dialogResult = dialog.ShowAsync();
            await opened.Task;
            if (dialogClosed) return;
            ArchiveInspection inspection;
            try
            {
                inspection = await operations.InspectArchiveAsync(file.Path, inspectionCancellation.Token);
            }
            catch (OperationCanceledException) when (inspectionCancellation.IsCancellationRequested)
            {
                return;
            }
            catch
            {
                if (!dialogClosed) dialog.Hide();
                throw;
            }
            if (dialogClosed) return;
            BitmapImage? image;
            try
            {
                image = inspection.Thumbnail is null
                    ? null : await CreateBitmapAsync(inspection.Thumbnail);
            }
            catch
            {
                if (!dialogClosed) dialog.Hide();
                throw;
            }
            if (dialogClosed) return;
            var content = new Grid { ColumnSpacing = 24, RowSpacing = 16 };
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(180) });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var metadata = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            if (image is not null)
                content.Children.Add(new Border
                {
                    Width = 180, Height = 180, CornerRadius = new CornerRadius(6),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Child = new Image { Source = image, Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill },
                });
            metadata.Children.Add(new TextBlock
            {
                Text = inspection.Manifest.SaveName, FontSize = 20,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
            });
            metadata.Children.Add(new TextBlock { Text = Localizer.Format("GameModeFormat", inspection.Manifest.Mode), TextWrapping = TextWrapping.Wrap });
            metadata.Children.Add(new TextBlock
            {
                Text = Localizer.Format("VersionCharacterFormat",
                    inspection.CharacterName ?? Localizer.Get("CharacterNameUnknown")),
                Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
                TextWrapping = TextWrapping.Wrap,
            });
            metadata.Children.Add(new TextBlock
            {
                Text = Localizer.Format("VersionSurvivalFormat",
                    inspection.HoursSurvived is >= 0
                        ? SaveVersionUiItem.FormatSurvivalHours(inspection.HoursSurvived.Value)
                        : Localizer.Get("SurvivalTimeUnknown")),
                Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
                TextWrapping = TextWrapping.Wrap,
            });
            metadata.Children.Add(new TextBlock
            {
                Text = inspection.Manifest.LastPlayedUtc is { } played
                    ? Localizer.Format("LastPlayedFormat", played.ToLocalTime().ToString("G", Localizer.Culture))
                    : Localizer.Get("LastPlayedUnknown"),
                Style = (Style)Application.Current.Resources["SecondaryTextStyle"],
                TextWrapping = TextWrapping.Wrap,
            });
            content.Children.Add(metadata);
            void ArrangePreview()
            {
                var width = Math.Max(180, Math.Min(640, XamlRoot.Size.Width - 96));
                var horizontal = image is not null && width >= 480;
                content.Width = width;
                content.ColumnDefinitions[0].Width = new GridLength(horizontal ? 180 : 1,
                    horizontal ? GridUnitType.Pixel : GridUnitType.Star);
                content.ColumnDefinitions[1].Width = new GridLength(horizontal ? 1 : 0, GridUnitType.Star);
                content.ColumnSpacing = horizontal ? 24 : 0;
                // 가로 배치에서는 비어 있는 두 번째 행에 간격을 남기지 않습니다.
                content.RowSpacing = image is not null && !horizontal ? 16 : 0;
                Grid.SetColumn(metadata, horizontal ? 1 : 0);
                Grid.SetRow(metadata, image is not null && !horizontal ? 1 : 0);
            }
            void PreviewRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => ArrangePreview();
            dialog.Content = content;
            ArrangePreview();
            XamlRoot.Changed += PreviewRootChanged;
            dialog.IsPrimaryButtonEnabled = true;
            ContentDialogResult confirmation;
            try { confirmation = await dialogResult; }
            finally { XamlRoot.Changed -= PreviewRootChanged; }
            if (confirmation != ContentDialogResult.Primary) return;
            if (App.Host != host) throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            var savesRoot = host!.ActiveSavesRoot
                ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            var result = await RunWithProgressAsync("import", id => operations.ImportArchiveAsync(file.Path, savesRoot, operationId: id));
            if (result.Outcome == PzTools.Process.Contracts.ProcessOutcome.Succeeded)
                await RefreshAfterMutationAsync(host, Localizer.Get("ImportArchiveTitle"),
                    Localizer.Get("OperationSucceeded"), showSuccessNotification: false);
            else ShowOperationResult(result);
        }
        catch (InvalidDataException exception)
        {
            ShowActionError(Localizer.Get("ImportArchiveTitle"), UserFacingError.FromArchiveError(exception));
        }
        catch (Exception exception)
        {
            ShowActionError(Localizer.Get("ImportArchiveTitle"), exception);
        }
        finally
        {
            archiveInteraction = false;
            UpdateOperationActions();
        }
    }
    private async void HealCharacter_Click(object sender, RoutedEventArgs e)
    {
        if (detailLoading || HasConflictingOperation()
            || sender is not FrameworkElement { DataContext: SaveVersionUiItem { IsCurrent: true, CanHeal: true } current }
            || SaveList.SelectedItem is not SaveListUiItem { IsFresh: true, Activity: ActivityState.Inactive } save
            || !StringComparer.OrdinalIgnoreCase.Equals(current.SaveId, save.SaveId)
            || App.Host?.Operations is null) return;
        var host = App.Host;
        var confirmation = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = Localizer.Get("HealCharacterTitle"),
            Content = new ScrollViewer
            {
                MaxHeight = Math.Max(120, XamlRoot.Size.Height - 240),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = new TextBlock
                {
                    Text = Localizer.Format("ConfirmHealCharacterBody", current.CharacterName ?? save.Name),
                    TextWrapping = TextWrapping.Wrap,
                },
            },
            PrimaryButtonText = Localizer.Get("HealCharacterAction"),
            CloseButtonText = Localizer.Get("Cancel"), DefaultButton = ContentDialogButton.Close,
        };
        // Locked from the moment the question is asked, as deletion is: a second click cannot open a
        // second dialog (which throws), and a failure to show it is reported instead of ending the app.
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
            if (detailLoading || OtherOperationRunning() || App.Host != host || !current.CanHeal
                || !ReferenceEquals(SaveList.SelectedItem, save)
                || save.Activity != ActivityState.Inactive || !save.IsFresh) return;
            var root = host.ActiveSavesRoot ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            var result = await RunWithProgressAsync("character-recovery", id => host.Operations!.RecoverCharacterAsync(root, save.SaveId, operationId: id));
            if (result.Outcome == PzTools.Process.Contracts.ProcessOutcome.Succeeded)
            {
                SetLocalResultMessage(result.OperationId, Localizer.Get("HealCharacterSucceeded"));
                await RefreshAfterMutationAsync(host, Localizer.Get("HealCharacterTitle"),
                    Localizer.Get("HealCharacterSucceeded"), collectState: true, showSuccessNotification: false);
            }
            else ShowOperationResult(result);
        }
        catch (Exception exception) { ShowActionError(Localizer.Get("HealCharacterTitle"), exception); }
        finally { archiveInteraction = false; UpdateOperationActions(); }
    }

    private async void ManualBackupButton_Click(object sender, RoutedEventArgs e)
    {
        if (detailLoading || HasConflictingOperation() || SaveList.SelectedItem is not SaveListUiItem save || App.Host?.Operations is null)
            return;
        ManualBackupButton.IsEnabled = false;
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            var operations = App.Host.Operations;
            var result = await RunWithProgressAsync("backup", id => operations.BackupAsync(save.SaveId, save.SourcePath, operationId: id));
            ShowOperationResult(result);
        }
        catch (Exception exception)
        {
            ShowActionError(Localizer.Get("ManualBackupTitle"), exception);
        }
        finally
        {
            archiveInteraction = false;
            UpdateOperationActions();
        }
    }

    private async void RestoreButton_Click(object sender, RoutedEventArgs e)
    {
        if (detailLoading || HasConflictingOperation()
            || SaveList.SelectedItem is not SaveListUiItem save
            || RevisionList.SelectedItem is not SaveVersionUiItem { IsCurrent: false } revision
            || revision.SourceId is null
            || !StringComparer.OrdinalIgnoreCase.Equals(revision.SaveId, save.SaveId)
            || App.Host?.Operations is null)
            return;
        var host = App.Host;
        var confirmation = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = Localizer.Get("ConfirmRestoreTitle"),
            Content = Localizer.Format("ConfirmRestoreBody", save.Name, revision.RevisionText),
            PrimaryButtonText = Localizer.Get("RestoreAction"),
            CloseButtonText = Localizer.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        // Locked while the question is asked: see HealCharacter_Click.
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
            if (detailLoading || App.Host != host || OtherOperationRunning()
                || !ReferenceEquals(SaveList.SelectedItem, save)
                || !ReferenceEquals(RevisionList.SelectedItem, revision)) return;
            var result = await RunWithProgressAsync("restore", id => host.Operations!.RestoreAsync(
                revision.SourceId.Value, revision.Revision, save.SourcePath, operationId: id));
            ShowOperationResult(result);
        }
        catch (Exception exception)
        {
            ShowActionError(Localizer.Get("RestoreTitle"), exception);
        }
        finally
        {
            archiveInteraction = false;
            UpdateOperationActions();
        }
    }
    private async void ExportButton_Click(object sender, RoutedEventArgs e)
    {
        if (detailLoading || RevisionList.SelectedItem is not SaveVersionUiItem revision
            || (!revision.IsCurrent && revision.SourceId is null)
            || !StringComparer.OrdinalIgnoreCase.Equals(revision.SaveId, selectedSaveId)
            || App.Host?.Operations is null || HasConflictingOperation())
            return;
        if (revision.IsCurrent && (projectorHealth?.IsFaulted("state") == true
            || SaveList.SelectedItem is not SaveListUiItem current || current.Activity == ActivityState.Active))
            return;
        var operations = App.Host.Operations;
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            var picker = new FileSavePicker(App.MainWindow.AppWindow.Id)
            {
                SuggestedFileName = revision.IsCurrent
                    ? $"{revision.SaveId.Replace('/', '-')}-current"
                    : $"{revision.SaveId.Replace('/', '-')}-r{revision.Revision}",
            };
            picker.FileTypeChoices.Add(Localizer.Get("ArchiveFileType"), [".zip"]);
            var file = await picker.PickSaveFileAsync();
            if (file is null) return;
            if (detailLoading || !StringComparer.OrdinalIgnoreCase.Equals(revision.SaveId, selectedSaveId)
                || !ReferenceEquals(RevisionList.SelectedItem, revision)) return;
            if (revision.IsCurrent && (projectorHealth?.IsFaulted("state") == true
                || SaveItems.FirstOrDefault(item => item.SaveId == revision.SaveId) is not { Activity: not ActivityState.Active }))
                throw new InvalidOperationException(Localizer.Get("StopPlayingToExport"));
            await RunWithProgressAsync("export", id => revision.IsCurrent
                ? operations.ExportLiveArchiveAsync(revision.SourcePath!, revision.SaveId, file.Path, operationId: id)
                : operations.ExportArchiveAsync(revision.SourceId!.Value, revision.Revision, file.Path, operationId: id));
        }
        catch (Exception exception)
        {
            ShowActionError(Localizer.Get("ExportArchiveTitle"), exception);
        }
        finally
        {
            archiveInteraction = false;
            UpdateOperationActions();
        }
    }

    private async Task RefreshAfterMutationAsync(PzTools.App.Core.AppHost host, string title,
        string successMessage, bool collectState = true, bool showSuccessNotification = true)
    {
        try
        {
            await host.RefreshSaveViewsAsync(collectState);
            if (App.Host != host) return;
            var view = host.Views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0);
            if (view.Snapshot is not null)
            {
                saveListRevision = view.ViewRevision;
                ApplySaveList(view.Snapshot, view.ViewRevision);
            }
            RefreshSelectedDetail();
            if (showSuccessNotification)
                ShowSidebarNotification(InfoBarSeverity.Success, title, successMessage);
        }
        catch (Exception)
        {
            if (App.Host == host)
                ShowSidebarNotification(InfoBarSeverity.Warning, title,
                    successMessage + "\n" + Localizer.Get("MutationRefreshFailed"));
        }
    }

    private void ShowActionError(string title, string message)
    {
        ShowSidebarNotification(InfoBarSeverity.Error, title, message);
    }

    private void ShowActionError(string title, Exception exception)
    {
        if (exception is ReportedOnCardException) return;
        ShowActionError(title, UserFacingError.FromException(exception));
    }

    /// <summary>
    /// Names why a worker's work failed or did not start, on that work's own card. The worker has logged it
    /// already, so this adds no notice and no log entry of its own.
    /// </summary>
    internal void ExplainOnOperationCard(string operationId, string message)
    {
        if (string.IsNullOrEmpty(operationId)) return;
        operationErrors[operationId] = (message, DateTimeOffset.UtcNow);
        RefreshOperationCards();
    }

    private void ShowOperationResult(PzTools.App.Core.AppOperationResult result)
    {
        // Every caller ran its work through RunWithProgressAsync, whose card already shows the
        // outcome; this only lets the worker's own card, if it takes over, name a failure the same way.
        if (result.RunIndex <= 0
            || result.Outcome is not (PzTools.Process.Contracts.ProcessOutcome.Failed or PzTools.Process.Contracts.ProcessOutcome.Degraded)
            || string.IsNullOrWhiteSpace(result.Error)) return;
        operationErrors[result.OperationId] = (
            UserFacingError.FromProcessError(result.ErrorMessage ?? result.Error), DateTimeOffset.UtcNow);
        RefreshOperationCards();
    }
}

public abstract class DeletableUiItem : INotifyPropertyChanged
{
    private bool canDelete;
    public bool CanDelete
    {
        get => canDelete;
        set
        {
            if (canDelete == value) return;
            canDelete = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CanDelete)));
        }
    }
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Notify(string propertyName) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));

    protected void Set<T>(ref T field, T value, string propertyName)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        Notify(propertyName);
    }
}

public sealed class SaveListUiItem : DeletableUiItem
{
    private SaveListItemView model;
    private BitmapImage? thumbnail;
    private string lastPlayedText;
    private string deleteLabel;

    public SaveListUiItem(SaveListItemView model)
    {
        this.model = model;
        lastPlayedText = FormatLastPlayed(model);
        deleteLabel = Localizer.Format("DeleteSaveLabel", model.Name);
    }

    public string SaveId => model.SaveId;
    public string Name => model.Name;
    public string Mode => model.Mode;
    public string SourcePath => model.SourcePath;
    public string? ThumbnailKey => model.ThumbnailKey;
    public ActivityState Activity => model.Activity;
    public bool IsFresh => model.Freshness == ViewFreshness.Fresh;
    public string DeleteLabel => deleteLabel;
    private string? deleteTooltip;
    public string? DeleteTooltip { get => deleteTooltip; set => Set(ref deleteTooltip, value, nameof(DeleteTooltip)); }
    public string LastPlayedText => lastPlayedText;
    public Visibility PlayingVisibility => IsFresh && model.Activity == ActivityState.Active
        ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DeadVisibility => model.CharacterState == CharacterState.Dead
        ? Visibility.Visible : Visibility.Collapsed;
    public BitmapImage? Thumbnail
    {
        get => thumbnail;
        set => Set(ref thumbnail, value, nameof(Thumbnail));
    }

    public void Update(SaveListItemView value)
    {
        var previous = model;
        model = value;
        if (previous.Name != value.Name) Notify(nameof(Name));
        if (previous.Mode != value.Mode) Notify(nameof(Mode));
        if (previous.Activity != value.Activity || previous.Freshness != value.Freshness)
            Notify(nameof(PlayingVisibility));
        if (previous.CharacterState != value.CharacterState) Notify(nameof(DeadVisibility));
        Set(ref lastPlayedText, FormatLastPlayed(value), nameof(LastPlayedText));
        Set(ref deleteLabel, Localizer.Format("DeleteSaveLabel", value.Name), nameof(DeleteLabel));
    }

    private static string FormatLastPlayed(SaveListItemView save) =>
        save.LastPlayedUtc is { } value
            ? value.ToLocalTime().ToString("g", Localizer.Culture)
            : Localizer.Get("NoPlayHistory");
}

public sealed class SaveVersionUiItem : DeletableUiItem
{
    private bool canHeal;
    public bool CanHeal { get => canHeal; set => Set(ref canHeal, value, nameof(CanHeal)); }
    public Visibility HealVisibility => IsCurrent ? Visibility.Visible : Visibility.Collapsed;
    public string HealLabel => Localizer.Get("HealCharacterAction");
    private string? healTooltip;
    public string? HealTooltip { get => healTooltip; set => Set(ref healTooltip, value, nameof(HealTooltip)); }
    private string revisionText = string.Empty;
    private BackupKind backupKind;
    private bool isEditing;
    private string timeText = string.Empty;
    private string sizeText = string.Empty;
    private BitmapImage? thumbnail;
    private CharacterState characterState = CharacterState.Unknown;
    private string? characterName;
    private double? hoursSurvived;
    private bool isSurvivalPending;
    private string? characterMetadataError;

    public SaveVersionUiItem(string saveId, long? sourceId, BackupRevisionView model)
    {
        SaveId = saveId;
        Revision = model.Revision;
        UpdateRevision(sourceId, model);
    }

    public SaveVersionUiItem(SaveListItemView live)
    {
        SaveId = live.SaveId;
        IsCurrent = true;
        UpdateLive(live);
    }

    public string SaveId { get; }
    public string? SourcePath { get; private set; }
    public bool IsCurrent { get; }
    public Visibility DeleteVisibility => IsCurrent ? Visibility.Collapsed : Visibility.Visible;
    public Visibility EditVisibility => IsCurrent || isEditing ? Visibility.Collapsed : Visibility.Visible;
    public Visibility ClearNameVisibility => !IsCurrent && isEditing ? Visibility.Visible : Visibility.Collapsed;
    public string EditableNameText => revisionText;
    public string NamePlaceholderText => Localizer.Format(backupKind switch
    {
        BackupKind.Manual => "ManualBackupNameFormat",
        BackupKind.Automatic => "AutomaticBackupNameFormat",
        _ => "BackupNameFormat",
    }, Revision);
    public string AutomaticSaveLabel => Localizer.Get("AutomaticSaveLabel");
    public Visibility AutomaticSaveVisibility => !IsCurrent && backupKind == BackupKind.Automatic
        ? Visibility.Visible : Visibility.Collapsed;
    // The game's version when this backup was made; older backups and ones made without the game have none.
    private string? gameVersion;
    private string gameVersionTip = string.Empty;
    public string GameVersionText => gameVersion is null ? string.Empty : Localizer.Format("GameVersionFormat", gameVersion);
    public string GameVersionTip => gameVersionTip;
    public Visibility GameVersionVisibility => gameVersion is null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility NameDisplayVisibility => isEditing ? Visibility.Collapsed : Visibility.Visible;
    public Visibility NameEditorVisibility => isEditing ? Visibility.Visible : Visibility.Collapsed;
    public bool IsEditing
    {
        get => isEditing;
        set
        {
            if (isEditing == value) return;
            isEditing = value;
            Notify(nameof(EditVisibility));
            Notify(nameof(ClearNameVisibility));
            Notify(nameof(EditableNameText));
            Notify(nameof(NameDisplayVisibility));
            Notify(nameof(NameEditorVisibility));
            Notify(nameof(IsEditing));
        }
    }
    public string EditLabel => Localizer.Format("EditRevisionLabel", RevisionText);
    public string ClearNameLabel => Localizer.Get("ClearRevisionNameLabel");
    public string DeleteLabel => Localizer.Format("DeleteRevisionLabel", RevisionText);
    public long? SourceId { get; private set; }
    public long Revision { get; }
    public string? ThumbnailKey { get; private set; }
    public string RevisionText => revisionText;
    public void SetRevisionName(string name)
    {
        Set(ref revisionText, name, nameof(RevisionText));
        Notify(nameof(EditableNameText));
        Notify(nameof(EditLabel));
        Notify(nameof(DeleteLabel));
    }
    public string TimeText => timeText;
    public string SizeText => sizeText;
    public string? CharacterName => characterName;
    public CharacterState CharacterState => characterState;
    public double? HoursSurvived => hoursSurvived;
    public string CharacterText => Localizer.Format("VersionCharacterFormat",
        characterName ?? Localizer.Get("CharacterNameUnknown"));
    // The stored reason is the reader's own words (Windows may have written them in its language), so the
    // screen says only that it failed, in today's language.
    public string? SurvivalReadError => characterMetadataError is null ? null : Localizer.Get("SurvivalReadFailedTip");
    public string SurvivalText => characterMetadataError is not null
        ? Localizer.Format("VersionSurvivalFormat", Localizer.Get("SurvivalReadFailed"))
        : isSurvivalPending
        ? Localizer.Get("VersionSurvivalLabel")
        : Localizer.Format("VersionSurvivalFormat", hoursSurvived is >= 0
            ? FormatSurvivalHours(hoursSurvived.Value)
            : Localizer.Get("SurvivalTimeUnknown"));
    public bool IsSurvivalPending => isSurvivalPending;
    public Visibility SurvivalProgressVisibility => isSurvivalPending
        ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DeadVisibility => characterState == CharacterState.Dead
        ? Visibility.Visible : Visibility.Collapsed;
    public BitmapImage? Thumbnail
    {
        get => thumbnail;
        set => Set(ref thumbnail, value, nameof(Thumbnail));
    }

    public void UpdateLive(SaveListItemView live, CharacterSnapshot? snapshot = null, SaveGameVersion? version = null)
    {
        SetGameVersion(version?.Version, version switch
        {
            null => string.Empty,
            { Basis: SaveVersionBasis.RunningGame } => Localizer.Get("CurrentSaveVersionRunningTip"),
            { Basis: SaveVersionBasis.LastSeen, AsOfUtc: { } seen } => Localizer.Format("CurrentSaveVersionSeenTip",
                seen.ToLocalTime().ToString("G", Localizer.Culture)),
            { AsOfUtc: { } made } => Localizer.Format("CurrentSaveVersionBackupTip",
                made.ToLocalTime().ToString("G", Localizer.Culture)),
            _ => string.Empty,
        });
        Set(ref characterMetadataError, null, nameof(SurvivalReadError));
        SourcePath = live.SourcePath;
        ThumbnailKey = live.ThumbnailKey;
        Set(ref characterName, snapshot?.Name, nameof(CharacterName));
        Set(ref hoursSurvived, snapshot?.HoursSurvived, nameof(HoursSurvived));
        Set(ref isSurvivalPending, false, nameof(IsSurvivalPending));
        Notify(nameof(CharacterText));
        Notify(nameof(SurvivalText));
        Notify(nameof(SurvivalProgressVisibility));
        var state = snapshot is { State: not CharacterState.Unknown }
            ? snapshot.State : live.CharacterState;
        if (characterState != state)
        {
            characterState = state;
            Notify(nameof(CharacterState));
            Notify(nameof(DeadVisibility));
        }
        Set(ref revisionText, Localizer.Get("CurrentSave"), nameof(RevisionText));
        Notify(nameof(EditableNameText));
        Set(ref timeText, FormatLastPlayed(live.LastPlayedUtc), nameof(TimeText));
        Set(ref sizeText, Localizer.Get("CurrentSaveLocation"), nameof(SizeText));
    }

    public void UpdateRevision(long? sourceId, BackupRevisionView revision)
    {
        Set(ref characterMetadataError, revision.CharacterMetadataError, nameof(SurvivalReadError));
        SourceId = sourceId;
        backupKind = revision.Kind;
        Notify(nameof(AutomaticSaveVisibility));
        ThumbnailKey = revision.ThumbnailKey;
        Set(ref characterName, revision.CharacterName, nameof(CharacterName));
        Set(ref hoursSurvived, revision.HoursSurvived, nameof(HoursSurvived));
        Set(ref isSurvivalPending, revision.SurvivalPending, nameof(IsSurvivalPending));
        Notify(nameof(CharacterText));
        Notify(nameof(SurvivalText));
        Notify(nameof(SurvivalProgressVisibility));
        if (characterState != revision.CharacterState)
        {
            characterState = revision.CharacterState;
            Notify(nameof(CharacterState));
            Notify(nameof(DeadVisibility));
        }
        // An unedited name was written in the language of the day it was made; show today's.
        Set(ref revisionText, string.IsNullOrWhiteSpace(revision.DisplayName)
            || PzTools.Process.Contracts.LanguageCatalog.IsDefaultBackupName(revision.DisplayName, revision.Revision)
            ? NamePlaceholderText
            : revision.DisplayName, nameof(RevisionText));
        Notify(nameof(EditableNameText));
        Notify(nameof(NamePlaceholderText));
        Notify(nameof(AutomaticSaveLabel));
        SetGameVersion(string.IsNullOrWhiteSpace(revision.GameVersion) ? null : revision.GameVersion.Trim(),
            Localizer.Get("BackupGameVersionTip"));
        Set(ref timeText, Localizer.Format("BackupRecordedTimeFormat",
            revision.CreatedUtc.ToLocalTime().ToString("G", Localizer.Culture)), nameof(TimeText));
        Set(ref sizeText, FormatBytes(revision.LogicalSize), nameof(SizeText));
        Notify(nameof(EditLabel));
        Notify(nameof(DeleteLabel));
    }

    private void SetGameVersion(string? version, string tip)
    {
        Set(ref gameVersionTip, tip, nameof(GameVersionTip));
        gameVersion = version;
        // Always: the text is formatted when read, so a language change must redraw it even if the version is the same.
        Notify(nameof(GameVersionText));
        Notify(nameof(GameVersionVisibility));
        // Labels read straight from the resources, for the same reason.
        Notify(nameof(HealLabel));
        Notify(nameof(ClearNameLabel));
    }

    private static string FormatLastPlayed(DateTimeOffset? played) => played is { } value
        ? Localizer.Format("LastPlayedFormat", value.ToLocalTime().ToString("G", Localizer.Culture))
        : Localizer.Get("LastPlayedUnknown");

    internal static string FormatSurvivalHours(double hours)
    {
        var minutes = (long)Math.Round(hours * 60, MidpointRounding.AwayFromZero);
        var days = minutes / (24 * 60);
        return days > 0
            ? Localizer.Format("SurvivalDaysHoursFormat", days, minutes / 60 % 24)
            : Localizer.Format("SurvivalHoursMinutesFormat", minutes / 60, minutes % 60);
    }

    private static string FormatBytes(long bytes)
    {
        string[] suffixes = ["B", "KB", "MB", "GB", "TB"];
        var value = (double)bytes;
        var suffix = 0;
        while (value >= 1024 && suffix < suffixes.Length - 1)
        {
            value /= 1024;
            suffix++;
        }
        // The UI language's decimal mark; the thread's culture can still be the one the app started with.
        return string.Create(Localizer.Culture, $"{value:0.#} {suffixes[suffix]}");
    }
}
