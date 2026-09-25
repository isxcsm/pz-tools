using PzTools.Process.Contracts;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using PzTools.App.Core;
using PzTools.Projections;
using Microsoft.Windows.Storage.Pickers;

namespace PzTools.App;

public sealed partial class SettingsPage : UserControl
{
    private readonly DispatcherQueueTimer applyTimer;
    private bool loading = true;
    private bool applying;
    private long requestedApply;
    private long completedApply;

    public SettingsPage()
    {
        InitializeComponent();
        foreach (var language in LanguageCatalog.All)
            LanguageCombo.Items.Add(new ComboBoxItem { Content = language.NativeName, Tag = language.Tag });
        applyTimer = DispatcherQueue.CreateTimer();
        applyTimer.Interval = TimeSpan.FromMilliseconds((App.Host?.RuntimeOptions ?? new AppRuntimeOptions()).SettingsDebounceMs);
        applyTimer.IsRepeating = false;
        applyTimer.Tick += ApplyTimer_Tick;
        ApplyLocalizedText();
        loading = false;
        Loaded += OnLoaded;
        Unloaded += (_, _) => applyTimer.Stop();
    }

    private App App => (App)Application.Current;

    private void SettingsPage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        // 작은 창에서는 SettingsCard의 기본 세로 배치를 사용하되 입력 영역도 넘치지 않게 합니다.
        var available = Math.Max(160, e.NewSize.Width - 120);
        SavesPathEditor.Width = BackupPathEditor.Width = Math.Min(420, available);
        IntervalEditor.Width = RetentionEditor.Width = Math.Min(340, available);
    }

    internal void ApplyLocalizedText()
    {
        Language = Localizer.Culture.Name;
        foreach (var toggle in new[] { SystemTrayToggle, GameSaveToggle, GameSaveCountdownToggle, AutomaticBackupToggle, DeathBackupToggle })
        {
            toggle.OnContent = Localizer.Get("SettingEnabled");
            toggle.OffContent = Localizer.Get("SettingDisabled");
        }
        SettingsTitleText.Text = Localizer.Get("SettingsTitle.Text");
        SettingsSubtitleText.Text = Localizer.Get("SettingsSubtitle");
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
        BackupSection.Header = Localizer.Get("AutomaticBackupSettings.Header");
        BackupSection.Description = Localizer.Get("AutomaticBackupSection.Description");
        AutomaticBackupSettingCard.Header = Localizer.Get("AutomaticBackupSetting.Header");
        AutomaticBackupSettingCard.Description = Localizer.Get("AutomaticBackupSetting.Description");
        IntervalSettingCard.Header = Localizer.Get("IntervalSetting.Header");
        IntervalSettingCard.Description =
            Localizer.Get("IntervalSetting.Description");
        RetentionSettingCard.Header = Localizer.Get("RetentionSetting.Header");
        RetentionSettingCard.Description = Localizer.Get("RetentionSetting.Description");
        DeathBackupSettingCard.Header = Localizer.Get("DeathBackupSetting.Header");
        DeathBackupSettingCard.Description = Localizer.Get("DeathBackupSetting.Description");
        GameSaveSettingCard.Header = Localizer.Get("GameSaveSetting.Header");
        GameSaveSettingCard.Description = Localizer.Get("GameSaveSetting.Description");
        GameSaveCountdownSettingCard.Header = Localizer.Get("GameSaveCountdownSetting.Header");
        GameSaveCountdownSettingCard.Description = Localizer.Get("GameSaveCountdownSetting.Description");
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

    private static void SetInputName(DependencyObject control, object header) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(control, header.ToString() ?? "");

    private void OnLoaded(object sender, RoutedEventArgs e) => LoadSettings();

    private void LoadSettings()
    {
        if (App.Host is null) return;
        loading = true;
        try
        {
            var value = App.Host.Views.ReadIfChanged<SettingsView>(
                ViewKey.Settings, 0).Snapshot;
            if (value is null) return;
            SelectTag(LanguageCombo, value.Language);
            SelectTag(ThemeCombo, value.Theme);
            SystemTrayToggle.IsOn = value.UseSystemTray;
            SavesPath.Text = value.SavesRoot;
            BackupPath.Text = value.BackupRoot;
            AutomaticBackupToggle.IsOn = value.AutomaticBackupEnabled;
            IntervalSlider.Value = IntervalNumber.Value = value.BackupIntervalMinutes;
            RetentionSlider.Value = RetentionNumber.Value = value.RetainedRevisions;
            DeathBackupToggle.IsOn = value.BackupOnDeath;
            DeathBackupToggle.IsEnabled = value.AutomaticBackupEnabled;
            GameSaveToggle.IsOn = value.SaveGameBeforeBackup;
            GameSaveCountdownToggle.IsOn = value.GameSaveCountdown;
            GameSaveCountdownToggle.IsEnabled = value.SaveGameBeforeBackup;
        }
        finally
        {
            loading = false;
        }
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

    private void ScheduleApply()
    {
        if (loading || !IsLoaded) return;
        requestedApply++;
        applyTimer.Stop();
        applyTimer.Start();
    }

    private async void ApplyTimer_Tick(DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        await ApplyPendingSettingsAsync();
    }

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
        Enum.Parse<LogLevel>(current.LogMinimumLevel),
        current.LogDisplayLimit,
        SystemTrayToggle.IsOn,
        current.VerifyStagedCopies,
        Enum.Parse<LogLevel>(current.LogRecordMinimumLevel),
        current.LogMaxEntries,
        GameSaveToggle.IsOn,
        GameSaveCountdownToggle.IsOn,
        AutomaticBackupToggle.IsOn);
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
        if (DeathBackupToggle is not null)
            DeathBackupToggle.IsEnabled = AutomaticBackupToggle.IsOn;
        if (loading || !IsLoaded) return;
        // A pause switch must not be lost when navigating away before numeric debounce fires.
        requestedApply++;
        applyTimer.Stop();
        await ApplyPendingSettingsAsync();
    }

    private void SettingChanged(object sender, object e)
    {
        if (GameSaveCountdownToggle is not null)
            GameSaveCountdownToggle.IsEnabled = GameSaveToggle.IsOn;
        if (AutomaticBackupToggle is not null && DeathBackupToggle is not null)
            DeathBackupToggle.IsEnabled = AutomaticBackupToggle.IsOn;
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
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(folder)
            {
                UseShellExecute = true,
            });
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
