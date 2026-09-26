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
    private readonly SemaphoreSlim thumbnailLoadGate;
    private readonly Dictionary<SaveVersionUiItem, CancellationTokenSource> revisionThumbnailLoads = [];
    private readonly HashSet<SaveVersionUiItem> revisionThumbnailAttempted = [];
    private CancellationTokenSource? operationProgressRefreshCancellation;
    private readonly TransientNotification notification;
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
    private long logsRevision;
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

    public MainWindowShell()
    {
        InitializeComponent();
        var runtime = App.Host?.RuntimeOptions ?? new AppRuntimeOptions();
        thumbnailLoadGate = new(runtime.ThumbnailReadConcurrency, runtime.ThumbnailReadConcurrency);
        saveSelectionBar = new AnimatedListSelectionBar(
            SaveList, SaveSelectionLayer, SaveSelectionBar, 18);
        revisionSelectionBar = new AnimatedListSelectionBar(
            RevisionList, RevisionSelectionLayer, RevisionSelectionBar, 17);
        saveInsertionAnimator = new ListInsertionAnimator(SaveList);
        revisionInsertionAnimator = new ListInsertionAnimator(RevisionList);
        RevisionList.LayoutUpdated += (_, _) => RevealRevisionSelectionIfReady();
        notification = new TransientNotification(ActionResultCard, ActionResultTitle, ActionResultMessage);
        // 수동 접힘에서는 DisplayMode가 Expanded인 채로 남을 수 있으므로 실제 열림 상태를 관찰합니다.
        Navigation.RegisterPropertyChangedCallback(NavigationView.IsPaneOpenProperty,
            (_, _) => ApplyNavigationSpacing());
        ApplyLocalizedText();
        countdownTimer = DispatcherQueue.CreateTimer();
        countdownTimer.Interval = TimeSpan.FromSeconds(1);
        countdownTimer.Tick += (_, _) => UpdateCountdown();
        detailProgressDelayTimer = DispatcherQueue.CreateTimer();
        detailProgressDelayTimer.Interval = TimeSpan.FromMilliseconds(runtime.DetailProgressDelayMs);
        detailProgressDelayTimer.IsRepeating = false;
        detailProgressDelayTimer.Tick += (_, _) =>
        {
            if (detailLoading && hasPresentedDetail)
            {
                DetailTransitionProgress.Visibility = Visibility.Visible;
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
            localOperation = null;
            RefreshOperationCards();
        };
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
        AppTitleText.Text = Localizer.Get("AppTitle");
        if (IsLoaded) App.MainWindow.Title = AppTitleText.Text;
        SavesItem.Content = Localizer.Get("SavesNavigation.Content");
        SavesPageTitle.Text = Localizer.Get("SavesNavigation.Content");
        AppToolTip.SetTip(SavesPageTitle, SavesPageTitle.Text);
        LogsItem.Content = Localizer.Get("LogsNavigation.Content");
        if (Navigation.SettingsItem is NavigationViewItem settings)
            settings.Content = Localizer.Get("SettingsTitle.Text");
        ExportProgressTitle.Text = Localizer.Get("Exporting.Text");
        BackupProgressTitle.Text = Localizer.Get("BackingUp.Text");
        NextBackupText.Text = Localizer.Get("NextBackupWaiting.Text");
        ProjectorStatusTitle.Text = Localizer.Get("ProjectorStatusTitle");
        ImportButton.Content = Localizer.Get("ImportArchive.Content");
        DeleteAllBackupsButton.Content = Localizer.Get("DeleteAllBackupsButton");
        NoSavesText.Text = Localizer.Get("NoSaves.Text");
        LoadingSavesText.Text = Localizer.Get("LoadingSaves.Text");
        SavesUnavailableText.Text = Localizer.Get("ProjectorStatusTitle");
        LoadingBackupsText.Text = Localizer.Get("LoadingBackups.Text");
        SelectSaveText.Text = Localizer.Get("SelectSave.Text");
        NarrowBackButton.Content = Localizer.Get("BackToList.Content");
        BackupRevisionsText.Text = Localizer.Get("BackupRevisions.Text");
        NoBackups.Text = Localizer.Get("NoBackups.Text");
        ManualBackupButton.Content = Localizer.Get("ManualBackup.Content");
        RestoreButton.Content = Localizer.Get("Restore.Content");
        ExportButton.Content = Localizer.Get("ExportArchive.Content");
    }

    public void ShowHostError(Exception exception)
    {
        hostStartFailed = true;
        UpdateSaveListPlaceholder();
        LoadingBackups.Visibility = Visibility.Collapsed;
        LogsRoot.ShowLoadFailure();
        EndDetailLoading();
        ShowSidebarNotification(InfoBarSeverity.Error,
            Localizer.Get("BackgroundServiceStartFailed"), UserFacingError.FromException(exception));
    }

    internal void ShowSidebarNotification(InfoBarSeverity severity, string title, string message) =>
        notification.Show(severity, title, message);

    internal void RefreshLocalization()
    {
        ApplyLocalizedText();
        SettingsRoot.ApplyLocalizedText();
        LogsRoot.ApplyLocalizedText();
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
        App.MainWindow.Title = AppTitleText.Text;
        UpdateTitleBar();
        Navigation.SelectedItem ??= SavesItem;
        // Avoid the automatic startup focus ring on the pane toggle. Keyboard
        // navigation still uses the normal focus visuals after this first load.
        if (!hasSetInitialFocus)
            hasSetInitialFocus = SavesItem.Focus(FocusState.Pointer);
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
    }

    private void UpdateTitleBar()
    {
        if (!IsLoaded) return;
        App.MainWindow.AppWindow.TitleBar.ButtonForegroundColor = ActualTheme == ElementTheme.Dark
            ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        LoadingSavesProgress.IsActive = false;
        CancelRevisionThumbnails();
        countdownTimer.Stop();
        detailProgressDelayTimer.Stop();
        saveInsertionAnimator.Reset();
        revisionInsertionAnimator.Reset();
        ResetRevisionEntrance();
        ResetRevisionExit();
        localOperationCardTimer.Stop();
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

        var logs = host.Views.ReadIfChanged<LogsView>(ViewKey.Logs, logsRevision);
        if (logs.Modified && logs.Snapshot is not null)
        {
            logsRevision = logs.ViewRevision;
            LogsRoot.Apply(logs.Snapshot);
            LogsUnreadBadge.Value = logs.Snapshot.UnreadIssues;
            LogsUnreadBadge.Visibility = logs.Snapshot.UnreadIssues > 0
                ? Visibility.Visible : Visibility.Collapsed;
        }

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
            currentItem.UpdateLive(live, currentCharacter);
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
        LoadingBackups.Visibility = Visibility.Collapsed;
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
        foreach (var expired in operationErrors
                     .Where(item => DateTimeOffset.UtcNow - item.Value.RecordedUtc > TimeSpan.FromMinutes(1))
                     .Select(item => item.Key).ToArray())
            operationErrors.Remove(expired);
        var backup = OperationProgressDisplay.SelectLocal(view.Operations.Where(operation =>
            operation.Kind.Contains("backup", StringComparison.OrdinalIgnoreCase)),
            localOperation?.Kind == "backup" ? localOperation : null, localOperationBaselineRunIndex);
        var foreground = OperationProgressDisplay.SelectForeground(view,
            localOperation?.Kind == "backup" ? null : localOperation, localOperationBaselineRunIndex);
        BackupProgressTitle.Text = OperationProgressTitle(backup, "BackingUp.Text");
        var foregroundTitleKey = foreground?.Kind == "delete-save" ? "DeletingSave" : foreground?.Kind == "character-recovery" ? "HealCharacterTitle" : foreground?.Kind.Contains(
            "import", StringComparison.OrdinalIgnoreCase) == true
            ? "Importing"
            : foreground?.Kind.Contains("restore", StringComparison.OrdinalIgnoreCase) == true
                ? "Restoring"
                : "ExportingDynamic";
        ExportProgressTitle.Text = OperationProgressTitle(foreground, foregroundTitleKey);
        ApplyProgress(BackupProgressCard, BackupProgress, BackupProgressMessage, backup);
        ApplyProgress(ExportProgressCard, ExportProgress, ExportProgressMessage, foreground);
        if (backup?.Status == OperationStatus.Running
            || (foreground?.Status == OperationStatus.Running && foreground.Kind != "delete-save"))
            StartOperationProgressRefresh();
        else StopOperationProgressRefresh();
        UpdateOperationActions();
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

    private void ApplyProgress(
        FrameworkElement card,
        ProgressBar progress,
        TextBlock message,
        OperationView? operation)
    {
        card.Visibility = operation is null ? Visibility.Collapsed : Visibility.Visible;
        var display = OperationProgressDisplay.From(operation, projectorHealth?.IsFaulted("telemetry") == true);
        progress.IsIndeterminate = display.IsIndeterminate;
        progress.Visibility = display.IsVisible ? Visibility.Visible : Visibility.Collapsed;
        if (operation is null) return;
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
        message.Text = (operation.Status is OperationStatus.Failed or OperationStatus.Degraded)
            && operationErrors.TryGetValue(operation.OperationId, out var error)
            ? error.Message
            : operation.Status is not OperationStatus.Running
            ? operation.Status switch
            {
                OperationStatus.Succeeded => Localizer.Get("OperationSucceeded"),
                OperationStatus.NoChange => Localizer.Get("OperationNoChange"),
                OperationStatus.Busy => Localizer.Get("OperationBusy"),
                OperationStatus.Cancelled => Localizer.Get("OperationCancelled"),
                OperationStatus.Degraded => Localizer.Get("OperationDegraded"),
                _ => operation.Message ?? Localizer.Get("OperationFailed"),
            }
            : telemetryUnavailable
            ? Localizer.Get("TelemetryProgressUnavailable")
            : byteBased
            ? Localizer.Format(
                "OperationCopyProgressFormat",
                ProgressPhaseText(operation.Phase),
                operation.CompletedBytes / 1048576.0,
                operation.TotalBytes!.Value / 1048576.0,
                Math.Floor(Math.Clamp(
                    100.0 * operation.CompletedBytes / operation.TotalBytes.Value, 0, 100)))
            : operation.TotalItems is > 0 and var total
                ? Localizer.Format(
                    "OperationProgressFormat",
                    ProgressPhaseText(operation.Phase),
                    operation.CompletedItems,
                    total,
                    Math.Floor(Math.Clamp(byteBased
                        ? 100.0 * operation.CompletedBytes / operation.TotalBytes!.Value
                        : 100.0 * operation.CompletedItems / total, 0, 100)))
                : operation.CompletedItems > 0
                    ? Localizer.Format("OperationDiscoveredFormat", ProgressPhaseText(operation.Phase), operation.CompletedItems)
                    : ProgressPhaseText(operation.Phase);
    }

    private static string OperationProgressTitle(OperationView? operation, string runningTitleKey) =>
        Localizer.Get(operation?.Status switch
        {
            OperationStatus.Succeeded => "OperationCardSucceeded",
            OperationStatus.NoChange => "OperationCardNoChange",
            OperationStatus.Failed => "OperationCardFailed",
            OperationStatus.Cancelled => "OperationCardCancelled",
            OperationStatus.Busy => "OperationCardBusy",
            OperationStatus.Degraded => "OperationCardDegraded",
            OperationStatus.Waiting => "OperationCardWaiting",
            _ => runningTitleKey,
        });

    private static string ProgressPhaseText(string? phase) => phase switch
    {
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
            throw;
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

    private bool HasConflictingOperation() =>
        archiveInteraction || (projectorHealth?.IsFaulted("telemetry") != true
        && App.Host?.Views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot?.Operations
            .Any(operation => operation.Status == OperationStatus.Running) == true);

    private void UpdateCountdown()
    {
        if (projectorHealth?.IsFaulted("scheduler") == true)
        {
            NextBackupText.Text = Localizer.Get("SchedulerStatusUnavailable");
            return;
        }
        if (schedule is null || !schedule.AutomaticEnabled)
        {
            NextBackupText.Text = Localizer.Get("AutomaticBackupOff");
            return;
        }
        if (schedule.PauseAware)
        {
            var seconds = (long)Math.Ceiling(Math.Max(0, schedule.RemainingMilliseconds ?? 0) / 1000d);
            var clock = $"{seconds / 60:00}:{seconds % 60:00}";
            if (schedule.CompletionUncertain)
                NextBackupText.Text = Localizer.Get("RuntimeBackupCompletionUnknown");
            else if ((schedule.Hold & ScheduleHold.Ambiguous) != 0)
                NextBackupText.Text = Localizer.Format("RuntimeBackupAmbiguous", clock);
            else if ((schedule.Hold & (ScheduleHold.Unknown | ScheduleHold.Unsupported)) != 0)
                NextBackupText.Text = Localizer.Format("RuntimeBackupWaiting", clock);
            else if ((schedule.Hold & ScheduleHold.NoWorld) != 0)
                NextBackupText.Text = Localizer.Get("NextBackupWaitingDynamic");
            else if ((schedule.Hold & ScheduleHold.GamePaused) != 0)
                NextBackupText.Text = Localizer.Format("RuntimeBackupPaused", clock);
            else if (seconds == 0)
                NextBackupText.Text = Localizer.Get(schedule.PeriodicBackupInProgress
                    ? "NextBackupWaitingForCurrent" : "NextBackupWaitingToStart");
            else NextBackupText.Text = Localizer.Format("NextBackupFormat",
                DateTimeOffset.Now.AddSeconds(seconds).ToString("T"), clock);
            return;
        }
        if (schedule.NextDueUtc is not { } due)
        {
            NextBackupText.Text = Localizer.Get("NextBackupWaitingDynamic");
            return;
        }
        var remaining = due - DateTimeOffset.UtcNow;
        if (remaining <= TimeSpan.Zero)
        {
            NextBackupText.Text = Localizer.Get(schedule.PeriodicBackupInProgress
                ? "NextBackupWaitingForCurrent" : "NextBackupWaitingToStart");
            return;
        }
        remaining = TimeSpan.FromSeconds(Math.Ceiling(remaining.TotalSeconds));
        NextBackupText.Text = Localizer.Format(
            "NextBackupFormat",
            due.ToLocalTime().ToString("T"),
            $"{(int)remaining.TotalMinutes:00}:{remaining.Seconds:00}");
    }

    private void Navigation_SelectionChanged(
        NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var settings = args.IsSettingsSelected;
        var tag = (args.SelectedItem as NavigationViewItem)?.Tag?.ToString();
        var logs = !settings && tag == "logs";
        SettingsRoot.Visibility = settings ? Visibility.Visible : Visibility.Collapsed;
        LogsRoot.Visibility = logs ? Visibility.Visible : Visibility.Collapsed;
        if (logs) LogsRoot.RefreshForNavigation();
        // Keep the save lists laid out while another page is shown. Collapsing this grid
        // unrealizes ListView rows, so its selection bar can reappear before the rows do.
        var showSaves = !settings && !logs;
        SavesRoot.Opacity = showSaves ? 1 : 0;
        SavesRoot.IsHitTestVisible = showSaves;
    }

    private void Navigation_DisplayModeChanged(NavigationView sender, NavigationViewDisplayModeChangedEventArgs args)
        => ApplyNavigationSpacing();

    private void Navigation_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer != SavesItem) return;
        // Returning to this page must not reset selection or start a new detail load.
        SaveList.SelectedItem ??= SaveItems.FirstOrDefault();
    }

    private void Navigation_PaneChanged(NavigationView sender, object args) => ApplyNavigationSpacing();

    private void ApplyNavigationSpacing()
    {
        if (Navigation is null || SavesItem is null || LogsItem is null) return;
        // 선택 표시줄을 창 가장자리에서 띄웁니다. 축소 모드에서는 아이콘 공간을 보존합니다.
        var expanded = Navigation.IsPaneOpen;
        // 기본 템플릿이 세로 2px 여백을 이미 제공하므로 중복해서 더하지 않습니다.
        var margin = expanded ? new Thickness(12, 0, 12, 0) : new Thickness(0);
        SavesItem.Margin = LogsItem.Margin = margin;
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
            LoadingBackups.Visibility = Visibility.Collapsed;
            if (DetailTransitionProgress.Visibility != Visibility.Visible)
                detailProgressDelayTimer.Start();
        }
        else
        {
            RevisionList.SelectedItem = null;
            RevisionItems.Clear();
            LoadingBackups.Visibility = Visibility.Visible;
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
            else ShowOperationResult(Localizer.Get("ImportArchiveTitle"), result);
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
        if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
        if (detailLoading || HasConflictingOperation() || App.Host != host || !current.CanHeal
            || !ReferenceEquals(SaveList.SelectedItem, save)
            || save.Activity != ActivityState.Inactive || !save.IsFresh) return;
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            var root = host.ActiveSavesRoot ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            var result = await RunWithProgressAsync("character-recovery", id => host.Operations!.RecoverCharacterAsync(root, save.SaveId, operationId: id));
            if (result.Outcome == PzTools.Process.Contracts.ProcessOutcome.Succeeded)
                await RefreshAfterMutationAsync(host, Localizer.Get("HealCharacterTitle"),
                    Localizer.Get("HealCharacterSucceeded"), collectState: true);
            else ShowOperationResult(Localizer.Get("HealCharacterTitle"), result);
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
            ShowOperationResult(Localizer.Get("ManualBackupTitle"), result);
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
        if (await confirmation.ShowAsync() != ContentDialogResult.Primary) return;
        if (detailLoading || App.Host != host || HasConflictingOperation()
            || !ReferenceEquals(SaveList.SelectedItem, save)
            || !ReferenceEquals(RevisionList.SelectedItem, revision)) return;
        archiveInteraction = true;
        UpdateOperationActions();
        try
        {
            var result = await RunWithProgressAsync("restore", id => host.Operations!.RestoreAsync(
                revision.SourceId.Value, revision.Revision, save.SourcePath, operationId: id));
            ShowOperationResult(Localizer.Get("RestoreTitle"), result);
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
            if (localOperation?.Kind == "export")
                CompleteLocalOperationProgress(OperationStatus.Failed,
                    error: UserFacingError.FromException(exception));
            else
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

    private void ShowActionError(string title, Exception exception) =>
        ShowActionError(title, UserFacingError.FromException(exception));

    private void ShowOperationResult(string title, PzTools.App.Core.AppOperationResult result)
    {
        // 실행 번호가 부여된 작업은 진행 카드가 완료/실패 상태까지 표시합니다.
        if (result.RunIndex > 0)
        {
            if ((result.Outcome is PzTools.Process.Contracts.ProcessOutcome.Failed
                    or PzTools.Process.Contracts.ProcessOutcome.Degraded)
                && !string.IsNullOrWhiteSpace(result.Error))
            {
                operationErrors[result.OperationId] = (
                    UserFacingError.FromProcessError(result.ErrorMessage ?? result.Error), DateTimeOffset.UtcNow);
                var current = App.Host?.Views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot;
                if (current is not null) ApplyOperations(current);
            }
            return;
        }
        var severity = result.Outcome is PzTools.Process.Contracts.ProcessOutcome.Succeeded
            or PzTools.Process.Contracts.ProcessOutcome.NoChange
            ? InfoBarSeverity.Success
            : result.Outcome == PzTools.Process.Contracts.ProcessOutcome.Busy
                ? InfoBarSeverity.Warning : InfoBarSeverity.Error;
        var message = result.Outcome switch
        {
            PzTools.Process.Contracts.ProcessOutcome.Succeeded => Localizer.Get("OperationSucceeded"),
            PzTools.Process.Contracts.ProcessOutcome.NoChange => Localizer.Get("OperationNoChange"),
            PzTools.Process.Contracts.ProcessOutcome.Busy => Localizer.Get("OperationBusy"),
            _ => UserFacingError.FromProcessError(result.ErrorMessage ?? result.Error),
        };
        ShowSidebarNotification(severity, title, message);
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
    public string? SurvivalReadError => characterMetadataError;
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

    public void UpdateLive(SaveListItemView live, CharacterSnapshot? snapshot = null)
    {
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
        Set(ref revisionText, string.IsNullOrWhiteSpace(revision.DisplayName)
            ? NamePlaceholderText
            : revision.DisplayName, nameof(RevisionText));
        Notify(nameof(EditableNameText));
        Notify(nameof(NamePlaceholderText));
        Set(ref timeText, Localizer.Format("BackupRecordedTimeFormat",
            revision.CreatedUtc.ToLocalTime().ToString("G", Localizer.Culture)), nameof(TimeText));
        Set(ref sizeText, FormatBytes(revision.LogicalSize), nameof(SizeText));
        Notify(nameof(EditLabel));
        Notify(nameof(DeleteLabel));
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
        return $"{value:0.#} {suffixes[suffix]}";
    }
}
