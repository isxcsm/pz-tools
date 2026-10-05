using PzTools.Process.Contracts;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media.Animation;
using PzTools.App.Core;
using PzTools.Projections;
using Microsoft.Windows.Storage.Pickers;
using SettingsCard = CommunityToolkit.WinUI.Controls.SettingsCard;

namespace PzTools.App;

/// <summary>A setting another page can lead to.</summary>
internal enum SettingTarget { Rolling, GameMemory }

public sealed partial class SettingsPage : UserControl
{
    private readonly DispatcherQueueTimer applyTimer;
    private bool loading = true;
    private bool applying;
    private bool settingsLoaded;
    private bool initialLayoutCompleted;
    private long requestedApply;
    private long completedApply;

    public SettingsPage()
    {
        InitializeComponent();
        // After the theme has reached the probes below: queued, so the colours taken are the new theme's.
        ActualThemeChanged += (_, _) => DispatcherQueue.Enqueue(() =>
        {
            if (warningShown is { } unsaved) ShowGameSaveWarning(unsaved, force: true);
        });
        // Alphabetical by native name, independent of the current UI language, so every user finds theirs in the same place.
        foreach (var language in LanguageCatalog.All.OrderBy(language => language.NativeName, StringComparer.InvariantCulture))
            LanguageCombo.Items.Add(new ComboBoxItem { Content = language.NativeName, Tag = language.Tag });
        applyTimer = DispatcherQueue.Timer(ApplyTimer_Tick);
        applyTimer.Interval = TimeSpan.FromMilliseconds((App.Host?.RuntimeOptions ?? new AppRuntimeOptions()).SettingsDebounceMs);
        applyTimer.IsRepeating = false;
        BuildHotKeyCards();
#if PZTOOLS_DEV_TOOLS
        BuildCardPreview();
#endif
        ApplyLocalizedText();
        PrepareForNavigation();
        loading = false;
        Loaded += OnLoaded;
        Unloaded += (_, _) =>
        {
            applyTimer.Stop();
            if (App.HotKeys is { } keys) keys.Changed -= HotKeys_Changed;
            if (capturing is not null) StopCapture();
        };
    }

    private App App => (App)Application.Current;

    private void SettingsPage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        // In a small window SettingsCard stacks as it does by default, and its input is kept from overflowing.
        var available = Math.Max(160, e.NewSize.Width - 72);
        SavesPathEditor.Width = BackupPathEditor.Width = Math.Min(500, available);
        IntervalEditor.Width = RetentionEditor.Width = RollingMinutesEditor.Width = Math.Min(340, available);
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        foreach (var toggle in new[] { SystemTrayToggle, GameSaveToggle, GameSaveCountdownToggle, AutomaticBackupToggle, DeathBackupToggle, PausePeriodicToggle, RollingToggle, UpdateAutoToggle })
        {
            toggle.OnContent = Localizer.Get("SettingEnabled");
            toggle.OffContent = Localizer.Get("SettingDisabled");
        }
        SettingsTitleText.Text = Localizer.Get("SettingsTitle.Text");
        UpdateSection.Header = Localizer.Get("UpdateSection.Header");
        UpdateCheckCard.Header = Localizer.Get("UpdateCheckSetting.Header");
        UpdateReleasePageCard.Header = Localizer.Get("UpdateReleasePage.Header");
        UpdateReleasePageButtonText.Text = Localizer.Get("UpdateReleasePage.Open");
        SetInputName(UpdateReleasePageButton, Localizer.Get("UpdateReleasePage.Name"));
        UpdateAutoSettingCard.Header = Localizer.Get("UpdateAutoSetting.Header");
        UpdateAutoSettingCard.Description = Localizer.Get("UpdateAutoSetting.Description");
        UpdateCheckButton.Content = Localizer.Get("UpdateCheckNow");
        UpdateDownloadButton.Content = Localizer.Get("UpdateDownload");
        SetInputName(UpdateAutoToggle, UpdateAutoSettingCard.Header);
        ApplyUpdate();
        DisplaySection.Header = Localizer.Get("DisplaySettings.Header");
        DisplaySection.Description = Localizer.Get("DisplaySettings.Description");
        LanguageSettingCard.Header = Localizer.Get("LanguageSetting.Header");
        LanguageSettingCard.Description = Localizer.Get("LanguageSetting.Description");
        ThemeSettingCard.Header = Localizer.Get("ThemeSetting.Header");
        ThemeSettingCard.Description = Localizer.Get("ThemeSetting.Description");
        Synchronize(() => ComboBoxLocalization.UpdateLabels(ThemeCombo, () =>
        {
            ThemeSystemItem.Content = Localizer.Get("ThemeSystem.Content");
            ThemeLightItem.Content = Localizer.Get("ThemeLight.Content");
            ThemeDarkItem.Content = Localizer.Get("ThemeDark.Content");
        }));
        SystemTraySettingCard.Header = Localizer.Get("SystemTraySetting.Header");
        SystemTraySettingCard.Description = Localizer.Get("SystemTraySetting.Description");
        PathSection.Header = Localizer.Get("PathSettings.Header");
        PathSection.Description = Localizer.Get("PathSettings.Description");
        SavesPathSettingCard.Header = Localizer.Get("SavesPathSetting.Header");
        BackupPathSettingCard.Header = Localizer.Get("BackupPathSetting.Header");
        SavesBrowseButton.Content = Localizer.Get("Browse.Content");
        BackupBrowseButton.Content = Localizer.Get("Browse.Content");
        SavesOpenButton.Content = BackupOpenButton.Content = Localizer.Get("AdvancedFiles.OpenFolder");
        BackupSection.Header = Localizer.Get("AutomaticBackupSettings.Header");
        BackupSection.Description = Localizer.Get("AutomaticBackupSection.Description");
        AutomaticBackupSettingCard.Header = Localizer.Get("AutomaticBackupSetting.Header");
        AutomaticBackupSettingCard.Description = Localizer.Get("AutomaticBackupSetting.Description");
        PausePeriodicSettingCard.Header = Localizer.Get("PausePeriodicSetting.Header");
        SetInputName(PausePeriodicToggle, PausePeriodicSettingCard.Header);
        IntervalSettingCard.Header = Localizer.Get("IntervalSetting.Header");
        IntervalSettingCard.Description =
            Localizer.Get("IntervalSetting.Description");
        RetentionSettingCard.Header = Localizer.Get("RetentionSetting.Header");
        RetentionSettingCard.Description = Localizer.Get("RetentionSetting.Description");
        DeathBackupSettingCard.Header = Localizer.Get("DeathBackupSetting.Header");
        GameSaveSettingCard.Header = Localizer.Get("GameSaveSetting.Header");
        GameSaveCountdownSettingCard.Header = Localizer.Get("GameSaveCountdownSetting.Header");
        UpdateAvailability();
        GameSection.Header = Localizer.Get("GameSettings.Header");
        GameSection.Description = Localizer.Get("GameSettings.Description");
        GameMemorySettingCard.Header = Localizer.Get("GameMemorySetting.Header");
        SetInputName(GameMemoryCombo, GameMemorySettingCard.Header);
        ApplyGameMemory();
        ProfilerSection.Header = Localizer.Get("ProfilerSettings.Header");
        ProfilerSection.Description = Localizer.Get("ProfilerSettings.Description");
        RollingSettingCard.Header = Localizer.Get("RollingSetting.Header");
        RollingSettingCard.Description = Localizer.Get("RollingSetting.Description");
        RollingModeSettingCard.Header = Localizer.Get("RollingModeSetting.Header");
        RollingModeSettingCard.Description = Localizer.Get("RollingModeSetting.Description");
        RollingModeToggle.OffContent = Localizer.Get("ProfileModeGeneral");
        RollingModeToggle.OnContent = Localizer.Get("ProfileModeDetailed");
        RollingMinutesSettingCard.Header = Localizer.Get("RollingMinutesSetting.Header");
        RollingMinutesSettingCard.Description = Localizer.Get("RollingMinutesSetting.Description");
        SetInputName(RollingToggle, RollingSettingCard.Header);
        SetInputName(RollingModeToggle, RollingModeSettingCard.Header);
        SetInputName(RollingMinutesSlider, RollingMinutesSettingCard.Header);
        SetInputName(RollingMinutesNumber, RollingMinutesSettingCard.Header);
        HotKeySection.Header = Localizer.Get("HotKeysTitle");
        HotKeySection.Description = Localizer.Get("HotKeySettings.Description");
        UpdateHotKeyCards();
        AdvancedSection.Header = Localizer.Get("AdvancedSettings.Header");
        AdvancedSection.Description = Localizer.Get("AdvancedSettings.Description");
        OpenConfigurationCard.Header = Localizer.Get("AdvancedFiles.OpenHeader");
        OpenConfigurationCard.Description = Localizer.Get("AdvancedFiles.OpenDescription");
        ApplyConfigurationCard.Header = Localizer.Get("AdvancedFiles.ApplyHeader");
        ApplyConfigurationCard.Description = Localizer.Get("AdvancedFiles.ApplyDescription");
        ResetConfigurationCard.Header = Localizer.Get("AdvancedFiles.ResetHeader");
        ResetConfigurationCard.Description = Localizer.Get("AdvancedFiles.ResetDescription");
        OpenConfigurationFolderButton.Content = Localizer.Get("AdvancedFiles.OpenFolder");
        RestartForConfigurationButton.Content = Localizer.Get("AdvancedFiles.Restart");
        ResetConfigurationButton.Content = Localizer.Get("AdvancedFiles.Reset");
#if PZTOOLS_DEV_TOOLS
        LocalizeCardPreview();
#endif
        SetInputName(LanguageCombo, LanguageSettingCard.Header);
        SetInputName(ThemeCombo, ThemeSettingCard.Header);
        SetInputName(SystemTrayToggle, SystemTraySettingCard.Header);
        SetInputName(SavesPath, SavesPathSettingCard.Header);
        SetInputName(BackupPath, BackupPathSettingCard.Header);
        SetInputName(AutomaticBackupToggle, AutomaticBackupSettingCard.Header);
        SetInputName(IntervalSlider, IntervalSettingCard.Header);
        SetInputName(IntervalNumber, IntervalSettingCard.Header);
        SetInputName(RetentionSlider, RetentionSettingCard.Header);
        SetInputName(RetentionNumber, RetentionSettingCard.Header);
        SetInputName(DeathBackupToggle, DeathBackupSettingCard.Header);
        SetInputName(GameSaveToggle, GameSaveSettingCard.Header);
        SetInputName(GameSaveCountdownToggle, GameSaveCountdownSettingCard.Header);
        SetInputName(OpenConfigurationFolderButton, OpenConfigurationFolderButton.Content);
        SetInputName(RestartForConfigurationButton, RestartForConfigurationButton.Content);
        SetInputName(ResetConfigurationButton, ResetConfigurationButton.Content);
    }

    private GameLinkView gameLink = GameLinkView.Available;

    /// <summary>A setting that needs the game is locked, not changed, while the game cannot provide it.</summary>
    internal void ApplyGameLink(GameLinkView view)
    {
        if (gameLink == view) return;
        bool heapChanged = gameLink.GameHeapMegabytes != view.GameHeapMegabytes;
        gameLink = view;
        UpdateAvailability();
        if (heapChanged) ApplyGameMemory();
    }

    // Each switch depends on the settings above it and on what it needs from the game. Locking
    // leaves the saved value alone, so everything returns by itself when the game can be read again.
    private void UpdateAvailability()
    {
        // Toggles raise their events while the page is still being built.
        if (AutomaticBackupToggle is null || PausePeriodicToggle is null || DeathBackupToggle is null || GameSaveToggle is null
            || GameSaveCountdownToggle is null || PausePeriodicSettingCard is null || DeathBackupSettingCard is null
            || GameSaveSettingCard is null || GameSaveCountdownSettingCard is null) return;
        bool linked = !gameLink.LinkUnavailable;
        PausePeriodicToggle.IsEnabled = linked;
        DeathBackupToggle.IsEnabled = linked && AutomaticBackupToggle.IsOn;
        GameSaveToggle.IsEnabled = linked;
        GameSaveCountdownToggle.IsEnabled = linked && GameSaveToggle.IsOn;
        string Describe(string key, string? note = null) => Localizer.Get(key)
            + (linked ? note is null ? "" : " " + note : " " + Localizer.Get("SettingUnavailableGameLink"));
        PausePeriodicSettingCard.Description = Describe("PausePeriodicSetting.Description",
            gameLink.SleepUnavailable ? Localizer.Get("SettingSleepUnavailable") : null);
        DeathBackupSettingCard.Description = Describe("DeathBackupSetting.Description");
        // Off, the card says what is lost where it is read: the caution colour behind it, a warning in place of its icon,
        // and what goes missing from backups in place of its description.
        var unsaved = !GameSaveToggle.IsOn;
        ShowGameSaveWarning(unsaved);
        GameSaveSettingCard.Description = Describe(unsaved ? "GameSaveSettingOffWarning" : "GameSaveSetting.Description");
        GameSaveCountdownSettingCard.Description = Describe("GameSaveCountdownSetting.Description");
    }

    // Shown once per change (this runs on every change of the game link), and again when the theme changes, in the
    // page's own theme's colours.
    private bool? warningShown;

    private void ShowGameSaveWarning(bool unsaved, bool force = false)
    {
        if (!force && warningShown == unsaved) return;
        warningShown = unsaved;
        // The card's template eases its background from one brush to the next (PART_RootGrid's BackgroundTransition),
        // mixing the colours as they are: between the opaque caution colour and the card's nearly transparent default it
        // showed a light grey for a moment. This card's background changes only for the warning, and at once.
        if (Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(GameSaveSettingCard) > 0
            && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(GameSaveSettingCard, 0) is Grid { Name: "PART_RootGrid" } templateRoot)
            templateRoot.BackgroundTransition = null;
        if (unsaved) GameSaveSettingCard.Background = CautionBackgroundProbe.Background;
        else GameSaveSettingCard.ClearValue(Microsoft.UI.Xaml.Controls.Control.BackgroundProperty);
        GameSaveSettingCard.HeaderIcon = unsaved
            ? new FontIcon { Glyph = "", Foreground = CautionProbe.Background }
            : new SymbolIcon(Symbol.Save);
    }

    private static void SetInputName(DependencyObject control, object header) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(control, header.ToString() ?? "");

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        PrepareForNavigation();
        if (App.HotKeys is { } keys) { keys.Changed -= HotKeys_Changed; keys.Changed += HotKeys_Changed; }
        UpdateHotKeyCards();
    }

    internal void PrepareForNavigation()
    {
        // The game's file may have changed since the last look (a game update); reading it again is cheap.
        if (App.GameMemory is { } memory) _ = memory.RefreshAsync();
        // Populate controls before their templates enter the visual tree. Keep local
        // edits intact on later visits, including changes still waiting for debounce.
        // Startup may publish a newer snapshot after the constructor. Refresh up
        // to the first presentation, but never replace subsequent pending edits.
        if (!settingsLoaded || !initialLayoutCompleted) LoadSettings();
    }

    /// <summary>
    /// Brings one setting into view, with the keyboard on it: another page leads here (the Performance page while the
    /// last minutes are not kept, or when the game ran short of memory). The focus shows which setting is meant.
    /// </summary>
    internal void Reveal(SettingTarget target)
    {
        var (section, card, control) = target switch
        {
            SettingTarget.GameMemory => (GameSection, GameMemorySettingCard, (Microsoft.UI.Xaml.Controls.Control)GameMemoryCombo),
            _ => (ProfilerSection, RollingSettingCard, RollingToggle),
        };
        section.IsExpanded = true;
        // After this layout pass, which places the page just shown.
        DispatcherQueue.Enqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            card.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0.3, AnimationDesired = true });
            control.Focus(FocusState.Keyboard);
        });
    }

    internal void CompleteInitialLayout()
    {
        if (initialLayoutCompleted) return;
        UpdateLayout();
        foreach (var section in new[] { UpdateSection, DisplaySection, PathSection, BackupSection, GameSection, ProfilerSection, HotKeySection, AdvancedSection })
            SettingsExpanderLayout.CompleteInitialExpansion(section);
        UpdateLayout();
        SettingsSections.ChildrenTransitions = new TransitionCollection
        {
            new RepositionThemeTransition { IsStaggeringEnabled = false },
        };
        initialLayoutCompleted = true;
    }

    private void LoadSettings()
    {
        if (App.Host is null) return;
        var wasLoading = loading;
        loading = true;
        try
        {
            var value = App.Host.Views.ReadIfChanged<SettingsView>(
                ViewKey.Settings, 0).Snapshot;
            if (value is null) return;
            settingsLoaded = true;
            SelectTag(LanguageCombo, value.Language);
            SelectTag(ThemeCombo, value.Theme);
            SystemTrayToggle.IsOn = value.UseSystemTray;
            UpdateAutoToggle.IsOn = value.CheckForUpdates;
            SavesPath.Text = value.SavesRoot;
            BackupPath.Text = value.BackupRoot;
            AutomaticBackupToggle.IsOn = value.AutomaticBackupEnabled;
            backupEditedHere = false;
            PausePeriodicToggle.IsOn = value.PausePeriodicDuringGame;
            IntervalSlider.Value = IntervalNumber.Value = value.BackupIntervalMinutes;
            RetentionSlider.Value = RetentionNumber.Value = value.RetainedRevisions;
            DeathBackupToggle.IsOn = value.BackupOnDeath;
            GameSaveToggle.IsOn = value.SaveGameBeforeBackup;
            GameSaveCountdownToggle.IsOn = value.GameSaveCountdown;
            LoadProfilerSettings(value);
            UpdateAvailability();
        }
        finally
        {
            loading = wasLoading;
        }
    }

    // ---- Performance and hotkeys ----

    private HotKeySettings hotKeySettings = new();
    private readonly Dictionary<HotKeyAction, (SettingsCard Card, Button Key, Button Clear)> hotKeyCards = [];
    private HotKeyAction? capturing;

    private void LoadProfilerSettings(SettingsView value)
    {
        RollingToggle.IsOn = value.RollingEnabled;
        rollingEditedHere = false;
        RollingModeToggle.IsOn = value.RollingDetailed;
        RollingMinutesSlider.Value = RollingMinutesNumber.Value = value.RollingMinutes;
        hotKeySettings = value.HotKeys ?? new();
        UpdateHotKeyCards();
    }

    // The settings were applied elsewhere (a hotkey turned the last minutes or automatic backups on or off): show them,
    // unless an edit made here is still waiting to be applied. The page writes all its values when it applies, so a
    // switch it did not take would undo the hotkey's change with the next edit here.
    private void HotKeys_Changed()
    {
        DispatcherQueue.Enqueue(() =>
        {
            if (App.Host?.Views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot is not { } value) return;
            if (applying || completedApply < requestedApply || capturing is not null)
            {
                // An edit here waits to be applied, and would write the page's values over what the hotkey just did:
                // the hotkey's own switch is taken into the page, unless it is the one being edited.
                if (!rollingEditedHere && RollingToggle.IsOn != value.RollingEnabled)
                    Synchronize(() => RollingToggle.IsOn = value.RollingEnabled);
                if (!backupEditedHere && AutomaticBackupToggle.IsOn != value.AutomaticBackupEnabled)
                    Synchronize(() => AutomaticBackupToggle.IsOn = value.AutomaticBackupEnabled);
                return;
            }
            Synchronize(() =>
            {
                LoadProfilerSettings(value);
                AutomaticBackupToggle.IsOn = value.AutomaticBackupEnabled;
                backupEditedHere = false;
            });
        });
    }

    // Whether the last minutes' or the automatic backups' switch was changed on this page since the settings were last
    // shown.
    private bool rollingEditedHere, backupEditedHere;

    private void RollingSettingChanged(object sender, object e)
    {
        if (ReferenceEquals(sender, RollingToggle) && !loading) rollingEditedHere = true;
        ScheduleApply();
    }

    private void RollingMinutesSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (loading) return;
        Synchronize(() => RollingMinutesNumber.Value = Math.Clamp(Math.Round(e.NewValue), 1, 10));
        ScheduleApply();
    }

    private void RollingMinutesNumber_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (loading || double.IsNaN(args.NewValue)) return;
        var minutes = Math.Clamp(Math.Round(args.NewValue), 1, 10);
        Synchronize(() => RollingMinutesSlider.Value = RollingMinutesNumber.Value = minutes);
        ScheduleApply();
    }

    private static string HotKeyName(HotKeyAction action) => $"HotKey.{action}";

    // A card for each action: its name and what it does, the combination as a button (press it, then the keys), and a
    // button that clears it.
    private void BuildHotKeyCards()
    {
        foreach (var action in Enum.GetValues<HotKeyAction>())
        {
            var key = new Button { MinWidth = 160 };
            var clear = new Button { Content = new SymbolIcon(Symbol.Clear), Style = (Style)Application.Current.Resources["SubtleButtonStyle"] };
            key.Click += (_, _) => StartCapture(action);
            key.PreviewKeyDown += (_, args) => CaptureKey(action, args);
            key.LostFocus += (_, _) => { if (capturing == action) StopCapture(); };
            clear.Click += (_, _) => SetHotKey(action, "");
            // The clear button stands before the key, so every key's right edge lines up whether a key is set or not.
            var holder = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            holder.Children.Add(clear);
            holder.Children.Add(key);
            var card = new SettingsCard { Content = holder, HeaderIcon = new SymbolIcon(Symbol.Keyboard) };
            hotKeyCards[action] = (card, key, clear);
            HotKeySection.Items.Add(card);
        }
    }

#if PZTOOLS_DEV_TOOLS
    // Developer builds only: the sidebar's cards on demand (MainWindowShell.CardPreview).
    private (SettingsCard Card, ComboBox Choice, Button Show, Button Clear)? cardPreview;

    private void BuildCardPreview()
    {
        var choice = new ComboBox { MinWidth = 180, MaxWidth = 320 };
        foreach (var key in MainWindowShell.CardPreviews) choice.Items.Add(new ComboBoxItem { Tag = key });
        choice.SelectedIndex = 0;
        var show = new Button();
        var clear = new Button();
        show.Click += (_, _) =>
        {
            if (App.MainWindow.Content is MainWindowShell shell && choice.SelectedItem is ComboBoxItem { Tag: string key }) shell.PreviewCard(key);
        };
        clear.Click += (_, _) => (App.MainWindow.Content as MainWindowShell)?.ClearCardPreviews();
        var holder = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        holder.Children.Add(choice);
        holder.Children.Add(show);
        holder.Children.Add(clear);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(choice, "CardPreviewChoice");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(show, "CardPreviewShow");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(clear, "CardPreviewClear");
        var card = new SettingsCard { HeaderIcon = new SymbolIcon(Symbol.Preview), Content = holder };
        AdvancedSection.Items.Add(card);
        cardPreview = (card, choice, show, clear);
        LocalizeCardPreview();
    }

    // Like every other text on this page, in the app's language now, again after each language change.
    private void LocalizeCardPreview()
    {
        if (cardPreview is not var (card, choice, show, clear)) return;
        card.Header = Localizer.Get("CardPreview.Header");
        card.Description = Localizer.Get("CardPreview.Description");
        show.Content = Localizer.Get("CardPreview.Show");
        clear.Content = Localizer.Get("CardPreview.Clear");
        SetInputName(choice, Localizer.Get("CardPreview.Header"));
        ComboBoxLocalization.UpdateLabels(choice, () =>
        {
            foreach (var item in choice.Items.OfType<ComboBoxItem>())
                item.Content = MainWindowShell.CardPreviewName((string)item.Tag);
        });
    }
#endif

    private void UpdateHotKeyCards()
    {
        var refused = App.HotKeys?.Refused ?? [];
        foreach (var (action, (card, key, clear)) in hotKeyCards)
        {
            card.Header = Localizer.Get(HotKeyName(action) + ".Header");
            var text = hotKeySettings.Get(action);
            var description = Localizer.Get(HotKeyName(action) + ".Description");
            // Saving the last minutes is taken only while they are kept; another program's hold is said where it shows.
            if (text.Length > 0 && refused.Contains(action)) description += " " + Localizer.Get("HotKeyTaken");
            else if (text.Length > 0 && action == HotKeyAction.SaveLast && !RollingToggle.IsOn) description += " " + Localizer.Get("HotKeyNeedsRolling");
            card.Description = description;
            key.Content = capturing == action ? Localizer.Get("HotKeyPress") : text.Length > 0 ? text : Localizer.Get("HotKeyNone");
            clear.Visibility = text.Length > 0 && capturing != action ? Visibility.Visible : Visibility.Collapsed;
            SetInputName(key, card.Header);
            SetInputName(clear, Localizer.Format("HotKeyClearFormat", card.Header));
        }
    }

    private void StartCapture(HotKeyAction action)
    {
        // While a key is chosen the app gives every combination back, so the one pressed reaches this page.
        App.HotKeys?.Suspend();
        capturing = action;
        // Leaving the window (to the game, to the tray) raises no LostFocus: without this every key stayed off.
        App.MainWindow.Activated -= MainWindow_Activated;
        App.MainWindow.Activated += MainWindow_Activated;
        UpdateHotKeyCards();
    }

    private void StopCapture()
    {
        capturing = null;
        App.MainWindow.Activated -= MainWindow_Activated;
        App.HotKeys?.Resume();
        UpdateHotKeyCards();
    }

    private void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated && capturing is not null) StopCapture();
    }

    private void CaptureKey(HotKeyAction action, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs args)
    {
        if (capturing != action) return;
        args.Handled = true;
        var code = (int)args.Key;
        if (args.Key == Windows.System.VirtualKey.Escape) { StopCapture(); return; }
        // A modifier alone waits for the key it goes with.
        if (args.Key is Windows.System.VirtualKey.Control or Windows.System.VirtualKey.Shift or Windows.System.VirtualKey.Menu
            or Windows.System.VirtualKey.LeftWindows or Windows.System.VirtualKey.RightWindows
            or Windows.System.VirtualKey.LeftControl or Windows.System.VirtualKey.RightControl
            or Windows.System.VirtualKey.LeftShift or Windows.System.VirtualKey.RightShift
            or Windows.System.VirtualKey.LeftMenu or Windows.System.VirtualKey.RightMenu) return;
        static bool Down(Windows.System.VirtualKey key) =>
            Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var modifiers = HotKeyModifiers.None;
        if (Down(Windows.System.VirtualKey.Control)) modifiers |= HotKeyModifiers.Control;
        if (Down(Windows.System.VirtualKey.Menu)) modifiers |= HotKeyModifiers.Alt;
        if (Down(Windows.System.VirtualKey.Shift)) modifiers |= HotKeyModifiers.Shift;
        if (Down(Windows.System.VirtualKey.LeftWindows) || Down(Windows.System.VirtualKey.RightWindows)) modifiers |= HotKeyModifiers.Windows;
        var gesture = new HotKeyGesture(modifiers, code);
        string? problem = !HotKeyGesture.IsKnownKey(code) ? "HotKeyUnknownKey"
            : !gesture.IsValid ? "HotKeyNeedsModifier"
            : Enum.GetValues<HotKeyAction>().Any(other => other != action && HotKeyGesture.Parse(hotKeySettings.Get(other)) == gesture) ? "HotKeyDuplicate"
            : App.HotKeys?.IsFree(gesture) == false ? "HotKeyTaken"
            : null;
        if (problem is not null)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Warning, Localizer.Get("HotKeysTitle"), Localizer.Format("HotKeyRefusedFormat", gesture, Localizer.Get(problem)));
            return;
        }
        capturing = null;
        App.MainWindow.Activated -= MainWindow_Activated;
        SetHotKey(action, gesture.ToString());
        App.HotKeys?.Resume();
    }

    private void SetHotKey(HotKeyAction action, string text)
    {
        hotKeySettings = hotKeySettings.With(action, text);
        UpdateHotKeyCards();
        ScheduleApply();
    }

    private async void BrowseFolder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button button || !button.IsEnabled) return;
        button.IsEnabled = false;
        try
        {
            var picker = new FolderPicker(App.MainWindow.AppWindow.Id);
            var folder = await picker.PickSingleFolderAsync();
            if (folder is null) return;
            if (button.Tag?.ToString() == "saves")
                SavesPath.Text = folder.Path;
            else
                BackupPath.Text = folder.Path;
            ScheduleApply();
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("SettingsTitle.Text"), UserFacingError.FromException(exception));
        }
        finally
        {
            button.IsEnabled = true;
        }
    }

    // Opens the folder the box shows, applied or not. A missing folder is reported, not created:
    // the path may be a typo.
    private void OpenPathFolder_Click(object sender, RoutedEventArgs e)
    {
        var folder = ((sender as Button)?.Tag?.ToString() == "saves" ? SavesPath : BackupPath).Text.Trim();
        try
        {
            if (folder.Length == 0 || !Directory.Exists(folder))
            {
                App.ShowSidebarNotification(InfoBarSeverity.Warning,
                    Localizer.Get("PathSettings.Header"), Localizer.Get("OperationError.FileMissing"));
                return;
            }
            ShellLaunch.Open(Path.GetFullPath(folder));
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("PathSettings.Header"), UserFacingError.FromException(exception));
        }
    }

    private void ScheduleApply()
    {
        if (loading || !IsLoaded) return;
        requestedApply++;
        applyTimer.Stop();
        applyTimer.Start();
    }

    // Not repeating: it has stopped by the time it ticks.
    private async void ApplyTimer_Tick() => await ApplyPendingSettingsAsync();

    private async Task ApplyPendingSettingsAsync()
    {
        if (applying) return;
        applying = true;
        try
        {
            while (completedApply < requestedApply)
            {
                var version = requestedApply;
                try
                {
                    await App.ApplySettingsAsync(ReadSettings());
                    completedApply = version;
                }
                catch (Exception exception)
                {
                    completedApply = version;
                    App.ShowSidebarNotification(InfoBarSeverity.Error,
                        Localizer.Get("SettingsTitle.Text"), UserFacingError.FromConfigurationException(exception));
                    break;
                }
            }
        }
        finally
        {
            applying = false;
            if (completedApply < requestedApply && IsLoaded)
                applyTimer.Start();
        }
    }

    private AppSettings ReadSettings()
    {
        var current = App.Host?.Views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot
            ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
        return new(
        LanguageCatalog.Parse(SelectedTag(LanguageCombo)),
        Enum.Parse<AppTheme>(SelectedTag(ThemeCombo)),
        SavesPath.Text,
        BackupPath.Text,
        checked((int)IntervalNumber.Value),
        checked((int)RetentionNumber.Value),
        DeathBackupToggle.IsOn,
        current.LogDisplayLimit,
        SystemTrayToggle.IsOn,
        current.VerifyStagedCopies,
        Enum.Parse<LogLevel>(current.LogRecordMinimumLevel),
        current.LogMaxEntries,
        GameSaveToggle.IsOn,
        GameSaveCountdownToggle.IsOn,
        AutomaticBackupToggle.IsOn,
        PausePeriodicToggle.IsOn,
        RollingToggle.IsOn,
        RollingModeToggle.IsOn,
        checked((int)Math.Clamp(double.IsNaN(RollingMinutesNumber.Value) ? 1 : RollingMinutesNumber.Value, 1, 10)),
        hotKeySettings,
        UpdateAutoToggle.IsOn);
    }

    // ---- Version and updates ----

    // A check asked for here: it runs whatever the last one was, and its failure is said in the line.
    private bool checkingUpdates, updateCheckFailed;

    // ---- The game's memory ----

    // Set while the list is filled from the game's file, so that is not taken for the player's choice.
    private bool showingGameMemory;
    // Why the last change could not be made, and in what state: said while the file is still as it was then.
    private (string Text, GameMemoryState At)? gameMemoryError;
    private bool applyingGameMemory;

    /// <summary>
    /// The game's memory as its file says: the game's own heap, or one of the heaps this PC can give it, the suggested one
    /// marked. When the file no longer has the chosen heap (a game update put its own back), the list shows the game's
    /// and the line under the name says so; choosing again applies it again.
    /// </summary>
    internal void ApplyGameMemory()
    {
        if (App.GameMemory is not { } memory) return;
        var state = memory.State;
        showingGameMemory = true;
        try
        {
            GameMemoryCombo.Items.Clear();
            var own = state.DefaultMegabytes ?? state.MaximumMegabytes;
            GameMemoryCombo.Items.Add(new ComboBoxItem
            {
                Content = own is { } size ? Localizer.Format("GameMemoryDefaultFormat", Size(size)) : Localizer.Get("GameMemoryDefault"),
                Tag = 0,
            });
            foreach (var choice in memory.Choices)
                GameMemoryCombo.Items.Add(new ComboBoxItem
                {
                    Content = choice.Recommended ? Localizer.Format("GameMemoryRecommendedFormat", Size(choice.Megabytes)) : Size(choice.Megabytes),
                    Tag = choice.Megabytes,
                });
            var shown = state.Status == GameMemoryStatus.Applied ? state.ChosenMegabytes ?? 0 : 0;
            // Put back by the game, the list shows the game's own without selecting it: either choice is then one, the
            // game's own (letting the player's go) as much as the player's again.
            var reverted = state.Status == GameMemoryStatus.Reverted;
            GameMemoryCombo.PlaceholderText = reverted ? (string)((ComboBoxItem)GameMemoryCombo.Items[0]).Content : "";
            GameMemoryCombo.SelectedItem = reverted ? null
                : GameMemoryCombo.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (int)item.Tag == shown) ?? GameMemoryCombo.Items[0];
            GameMemoryCombo.IsEnabled = !applyingGameMemory && state.Status is GameMemoryStatus.Default or GameMemoryStatus.Applied
                or GameMemoryStatus.Reverted;
        }
        finally { showingGameMemory = false; }
        var note = (gameMemoryError is { } error && error.At == state ? error.Text : null) ?? state.Status switch
        {
            GameMemoryStatus.NotFound => Localizer.Get("GameMemoryNotFound"),
            GameMemoryStatus.Unsupported => Localizer.Get("GameMemoryUnsupported"),
            GameMemoryStatus.Reverted when state.ChosenMegabytes is { } chosen => Localizer.Format("GameMemoryRevertedFormat", Size(chosen)),
            _ => null,
        };
        // The running game started with other memory than the file now gives: the choice waits for its next start.
        // Started by a launch script, it read nothing of the file: the choice applies when started from Steam's
        // own launcher, never through that script.
        var waiting = note is not null ? null
            : gameLink.StartedWithoutLauncher ? Localizer.Get("GameMemoryWithoutLauncher")
            : gameLink.GameHeapMegabytes is { } heap && state.MaximumMegabytes is { } next
                && Math.Abs(heap - next) >= 128 ? Localizer.Get("GameMemoryNextStart") : null;
        GameMemorySettingCard.Description = Localizer.Get("GameMemorySetting.Description") + (note is null ? "" : " " + note)
            + (waiting is null ? "" : " " + waiting);
        MarkRunningGameMemory(GameMemoryCombo.IsDropDownOpen);
    }

    // The list, while open, marks the memory the running game was started with ("8 GB · Running"); closed, it shows
    // the choice alone. Each item's own words are kept in its name for screen readers and for taking the mark off.
    private void MarkRunningGameMemory(bool open)
    {
        var heap = gameLink.GameHeapMegabytes;
        var own = App.GameMemory?.State is { } state ? state.DefaultMegabytes ?? state.MaximumMegabytes : null;
        foreach (var item in GameMemoryCombo.Items.OfType<ComboBoxItem>())
        {
            var label = Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(item) is { Length: > 0 } kept ? kept : item.Content as string ?? "";
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, label);
            int megabytes = item.Tag is int tag && tag > 0 ? tag : own ?? -1;
            bool running = open && heap is { } value && megabytes > 0 && Math.Abs(value - megabytes) < 128;
            item.Content = running ? Localizer.Format("GameMemoryRunningMarkFormat", label) : label;
        }
    }

    private void GameMemoryCombo_DropDownOpened(object? sender, object e) => MarkRunningGameMemory(true);
    private void GameMemoryCombo_DropDownClosed(object? sender, object e) => MarkRunningGameMemory(false);

    /// <summary>A heap in gigabytes, as the choices are whole ones: "6 GB".</summary>
    internal static string Size(int megabytes) =>
        Units.Bytes(megabytes * 1024L * 1024);

    private async void GameMemoryCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (showingGameMemory || App.GameMemory is not { } memory || GameMemoryCombo.SelectedItem is not ComboBoxItem { Tag: int megabytes })
            return;
        var state = memory.State;
        // The list showing what the file holds already is no change; put back by the game, either choice is one.
        if (state.Status != GameMemoryStatus.Reverted && megabytes == (state.Status == GameMemoryStatus.Applied ? state.ChosenMegabytes ?? 0 : 0))
            return;
        applyingGameMemory = true;
        gameMemoryError = null;
        try { await memory.ApplyAsync(megabytes == 0 ? null : megabytes); }
        catch (GameMemoryException error)
        {
            gameMemoryError = (Localizer.Get(error.Code switch
            {
                "not-found" => "GameMemoryNotFound",
                "unsupported" => "GameMemoryUnsupported",
                _ => "GameMemoryUnwritable",
            }), memory.State);
        }
        finally
        {
            applyingGameMemory = false;
            ApplyGameMemory();
        }
    }

    /// <summary>The version line: whether a newer one can be had, as last asked, and this version as its value.</summary>
    internal void ApplyUpdate()
    {
        if (App.Updates is not { } updates) return;
        var available = updates.Available;
        UpdateVersionText.Text = "v" + updates.Current.ToString(3);
        UpdateSection.Description = checkingUpdates ? Localizer.Get("UpdateStatusChecking")
            : updateCheckFailed ? Localizer.Get("UpdateStatusFailed")
            : available is not null ? Localizer.Format("UpdateStatusAvailable", "v" + available.Version.ToString(3))
            : updates.State.CheckedAt is null ? Localizer.Get("UpdateStatusUnknown")
            : Localizer.Get("UpdateStatusCurrent");
        UpdateDownloadButton.Visibility = available is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateCheckProgress.IsActive = checkingUpdates;
        UpdateCheckProgress.Visibility = checkingUpdates ? Visibility.Visible : Visibility.Collapsed;
        UpdateCheckButton.IsEnabled = !checkingUpdates;
    }

    private async void UpdateCheck_Click(object sender, RoutedEventArgs e)
    {
        if (App.Updates is not { } updates || checkingUpdates) return;
        (checkingUpdates, updateCheckFailed) = (true, false);
        ApplyUpdate();
        try { await updates.CheckAsync(force: true); }
        // A release list not as expected (a field of another type) fails the check too, not the app.
        catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException
            or IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidOperationException
            or FormatException or KeyNotFoundException)
        {
            updateCheckFailed = true;
        }
        finally
        {
            checkingUpdates = false;
            ApplyUpdate();
        }
    }

    private void UpdateReleasePage_Click(object sender, RoutedEventArgs e) => App.OpenReleasePage(UpdateChecker.ReleasesPage);

    private void UpdateDownload_Click(object sender, RoutedEventArgs e)
    {
        if (App.Updates?.Available is { } release) App.OpenReleasePage(release.Page);
    }

    private void IntervalSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (loading) return;
        Synchronize(() => IntervalNumber.Value = Math.Clamp(Math.Round(e.NewValue), 1, 60));
        ScheduleApply();
    }

    private void IntervalNumber_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (loading || double.IsNaN(args.NewValue)) return;
        var minutes = Math.Clamp(Math.Round(args.NewValue), 1, 60);
        Synchronize(() => IntervalSlider.Value = IntervalNumber.Value = minutes);
        ScheduleApply();
    }

    private void RetentionSlider_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (loading) return;
        Synchronize(() => RetentionNumber.Value = Math.Round(e.NewValue));
        ScheduleApply();
    }

    private void RetentionNumber_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args)
    {
        if (loading || double.IsNaN(args.NewValue)) return;
        Synchronize(() => RetentionSlider.Value = Math.Round(args.NewValue));
        ScheduleApply();
    }

    private async void AutomaticBackupToggle_Toggled(object sender, RoutedEventArgs e)
    {
        UpdateAvailability();
        if (loading || !IsLoaded) return;
        backupEditedHere = true;
        // The switch must not be lost when navigating away before numeric debounce fires.
        requestedApply++;
        applyTimer.Stop();
        await ApplyPendingSettingsAsync();
    }

    private void SettingChanged(object sender, object e)
    {
        UpdateAvailability();
        ScheduleApply();
    }

    private void PathSettingChanged(object sender, RoutedEventArgs e) => ScheduleApply();

    private void OpenConfigurationFolder_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var folder = App.Host?.Settings.ConfigurationRoot
                ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            Directory.CreateDirectory(folder);
            ShellLaunch.Open(folder);
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("AdvancedFiles.Header"), UserFacingError.FromException(exception));
        }
    }

    private async void RestartForConfiguration_Click(object sender, RoutedEventArgs e)
    {
        if (XamlRoot is null) return;
        RestartForConfigurationButton.IsEnabled = false;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = Localizer.Get("AdvancedFiles.Restart"),
                Content = Localizer.Get("AdvancedFiles.RestartConfirmation"),
                PrimaryButtonText = Localizer.Get("AdvancedFiles.Restart"),
                CloseButtonText = Localizer.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            applyTimer.Stop();
            while (applying) await Task.Delay(50);
            if (completedApply < requestedApply)
                await ApplyPendingSettingsAsync();
            await App.RestartForConfigurationAsync();
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("AdvancedFiles.Header"), UserFacingError.FromException(exception));
        }
        finally { RestartForConfigurationButton.IsEnabled = true; }
    }

    private async void ResetConfiguration_Click(object sender, RoutedEventArgs e)
    {
        if (XamlRoot is null) return;
        ResetConfigurationButton.IsEnabled = false;
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = Localizer.Get("AdvancedFiles.Reset"),
                Content = Localizer.Get("AdvancedFiles.ResetConfirmation"),
                PrimaryButtonText = Localizer.Get("AdvancedFiles.Reset"),
                CloseButtonText = Localizer.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            applyTimer.Stop();
            while (applying) await Task.Delay(50);
            if (completedApply < requestedApply)
                await ApplyPendingSettingsAsync();
            await App.RestartForConfigurationAsync(resetToDefaults: true);
        }
        catch (Exception exception)
        {
            App.ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("AdvancedFiles.Header"), UserFacingError.FromException(exception));
        }
        finally { ResetConfigurationButton.IsEnabled = true; }
    }

    private void Synchronize(Action update)
    {
        var wasLoading = loading;
        loading = true;
        try { update(); }
        finally { loading = wasLoading; }
    }

    private static void SelectTag(ComboBox combo, string tag) => combo.SelectedItem =
        combo.Items.OfType<ComboBoxItem>().First(item => item.Tag?.ToString() == tag);

    private static string SelectedTag(ComboBox combo) =>
        ((ComboBoxItem)combo.SelectedItem).Tag!.ToString()!;
}
