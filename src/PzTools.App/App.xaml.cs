using PzTools.Process.Contracts;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PzTools.App.Core;
using PzTools.Process.Hosting;
using PzTools.Scheduling;

namespace PzTools.App;

public partial class App : Application
{
    // Keep the handle rooted until process exit, including tray mode and asynchronous shutdown.
    private static ApplicationInstanceLease? instanceLease;
    private Window? window;
    private SupportedLanguage currentLanguage;
    private string? runtimeRoot;
    private readonly SemaphoreSlim settingsGate = new(1, 1);
    private SystemTrayIcon? trayIcon;
    private bool useSystemTray;
    private bool exitConfirmed;
    private bool exitDialogOpen;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) =>
        {
            System.Diagnostics.Debug.WriteLine(args.Exception);
        };
    }

    public AppHost? Host { get; private set; }
    public Window MainWindow => window ?? throw new InvalidOperationException(Localizer.Get("WindowNotCreated"));

    internal void ShowSidebarNotification(InfoBarSeverity severity, string title, string message)
    {
        if (window?.Content is MainWindowShell shell)
            shell.ShowSidebarNotification(severity, title, message);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        runtimeRoot = PzTools.Process.Contracts.PzToolsPathLayout.CreateDefault().DataRoot;
        instanceLease = ApplicationInstanceLease.TryAcquire(runtimeRoot);
        if (instanceLease is null)
        {
            Exit();
            return;
        }
        Host = CreateHost(runtimeRoot);
        AppSettings settings;
        Exception? configurationError = null;
        try { settings = Host.Settings.Load(); }
        catch (Exception exception)
        {
            settings = AppSettings.CreateDefault().Validate();
            configurationError = exception;
        }
        Host.PublishSettings(settings);
        ApplyLanguage(settings.Language, reloadContent: false);
        window = new MainWindow();
        window.AppWindow.Closing += MainWindow_Closing;
        window.Closed += async (_, _) =>
        {
            trayIcon?.Dispose();
            trayIcon = null;
            if (Host is not null) await Host.DisposeAsync();
        };
        ApplyTheme(settings.Theme);
        window.Activate();
        if (configurationError is not null)
            ShowSidebarNotification(InfoBarSeverity.Error,
                Localizer.Get("SettingsTitle.Text"),
                UserFacingError.FromConfigurationException(configurationError));
        ConfigureTray(settings.UseSystemTray);
        _ = StartHostAsync();
    }

    public void ApplyTheme(AppTheme theme)
    {
        if (window?.Content is FrameworkElement root)
        {
            root.RequestedTheme = theme switch
            {
                AppTheme.Light => ElementTheme.Light,
                AppTheme.Dark => ElementTheme.Dark,
                _ => ElementTheme.Default,
            };
        }
    }

    public async Task ApplySettingsAsync(AppSettings settings)
    {
        await settingsGate.WaitAsync();
        try
        {
            // 다른 화면에서 갱신한 로그 옵션을 오래된 설정 화면 값으로 덮어쓰지 않습니다.
            var current = Host?.Settings.Load()
                ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            await ApplySettingsCoreAsync(settings with
            {
                LogMinimumLevel = settings.LogRecordMinimumLevel != current.LogRecordMinimumLevel
                    ? settings.LogRecordMinimumLevel : current.LogMinimumLevel,
                LogDisplayLimit = current.LogDisplayLimit,
            });
        }
        finally { settingsGate.Release(); }
    }

    public async Task ApplyLogOptionsAsync(PzTools.Projections.LogLevel minimumLevel, int displayLimit)
    {
        await settingsGate.WaitAsync();
        try
        {
            var host = Host ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            await host.ApplyLogOptionsAsync(minimumLevel, displayLimit);
        }
        finally { settingsGate.Release(); }
    }

    public async Task RestartForConfigurationAsync(bool resetToDefaults = false)
    {
        await settingsGate.WaitAsync();
        try
        {
            var host = Host ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
            if (host.HasRunningOperation())
                throw new InvalidOperationException(
                    Localizer.Get("OperationError.SettingsBusy"));
            if (!resetToDefaults)
            {
                try { host.Settings.ValidateEditableConfiguration(); }
                catch (Exception exception)
                {
                    throw new InvalidOperationException(UserFacingError.FromConfigurationException(exception), exception);
                }
            }
            var repository = host.Repository?.RepositoryPath;
            if (repository is not null)
            {
                var stopped = await OperationMutexSet.TryRunAsync(
                    [new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repository)],
                    async _ =>
                    {
                        await host.DisposeAsync();
                        return true;
                    });
                if (!stopped.Acquired)
                    throw new InvalidOperationException(
                        Localizer.Get("OperationError.SettingsBusy"));
            }
            else await host.DisposeAsync();
            Host = null;
            try
            {
                if (resetToDefaults)
                {
                    await host.Settings.ResetEditableConfigurationAsync();
                    host.Settings.ValidateEditableConfiguration();
                }
                // 성공하면 현재 프로세스가 종료됩니다. 실패한 경우에만 호출이 돌아옵니다.
                var failure = Microsoft.Windows.AppLifecycle.AppInstance.Restart("");
                throw new InvalidOperationException(Localizer.Get("OperationError.RestartFailed"),
                    new InvalidOperationException($"App restart failed: {failure}"));
            }
            catch
            {
                Host = CreateHost(runtimeRoot!);
                await Host.StartAsync();
                RefreshShellAfterHostReplacement(Host.Settings.Load());
                throw;
            }
        }
        finally { settingsGate.Release(); }
    }

    private async Task ApplySettingsCoreAsync(AppSettings settings)
    {
        var host = Host ?? throw new InvalidOperationException(Localizer.Get("HostNotReady"));
        var previous = host.Settings.Load();
        var pathsChanged = !StringComparer.OrdinalIgnoreCase.Equals(
                previous.SavesRoot, settings.SavesRoot)
            || !StringComparer.OrdinalIgnoreCase.Equals(
                previous.BackupRoot, settings.BackupRoot);

        await host.ApplySettingsAsync(settings);
        if (pathsChanged)
        {
            await host.DisposeAsync();
            var replacement = CreateHost(runtimeRoot!);
            try
            {
                replacement.PublishSettings(settings);
                await replacement.StartAsync();
                Host = replacement;
            }
            catch (Exception replacementFailure)
            {
                await replacement.DisposeAsync();
                var rollback = CreateHost(runtimeRoot!);
                Host = rollback;
                try
                {
                    var layout = PzTools.Process.Contracts.PzToolsPathLayout.CreateDefault(
                        dataRoot: runtimeRoot!);
                    var scheduler = await SchedulerDatabase.CreateOrOpenAsync(
                        layout.SchedulerDatabasePath);
                    await rollback.Settings.SaveAndApplyAsync(
                        previous,
                        scheduler);
                    rollback.PublishSettings(previous);
                    await rollback.StartAsync();
                    RefreshShellAfterHostReplacement(previous);
                }
                catch (Exception rollbackFailure)
                {
                    throw new AggregateException(
                        Localizer.Get("OperationError.SettingsRecoveryFailed"),
                        replacementFailure,
                        rollbackFailure);
                }

                throw new InvalidOperationException(
                    Localizer.Get("OperationError.SettingsReverted"),
                    replacementFailure);
            }
        }

        if (pathsChanged)
            RefreshShellAfterHostReplacement(settings);
        else
        {
            ApplyLanguage(settings.Language);
            ApplyTheme(settings.Theme);
            ConfigureTray(settings.UseSystemTray);
        }
    }

    private void RefreshShellAfterHostReplacement(AppSettings settings)
    {
        // A shell owns subscriptions and view revision cursors for one host.
        // Recovery must replace it just like a successful data-root switch.
        ApplyLanguage(settings.Language, reloadContent: false);
        if (window is not null) window.Content = new MainWindowShell();
        ApplyTheme(settings.Theme);
        ConfigureTray(settings.UseSystemTray);
    }

    public void ApplyLanguage(SupportedLanguage language, bool reloadContent = true)
    {
        var changed = currentLanguage != language;
        currentLanguage = language;
        Localizer.SetLanguage(language);
        trayIcon?.RefreshTooltip();
        if (changed && reloadContent && window?.Content is MainWindowShell shell)
            shell.RefreshLocalization();
    }

    private async Task StartHostAsync()
    {
        try { await Task.Run(() => Host!.StartAsync()); }
        catch (Exception exception)
        {
            if (window?.Content is MainWindowShell shell)
                shell.ShowHostError(exception);
        }
    }

    private void MainWindow_Closing(
        Microsoft.UI.Windowing.AppWindow sender,
        Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (exitConfirmed) return;
        args.Cancel = true;
        if (exitDialogOpen) return;
        if (useSystemTray && trayIcon?.IsAvailable == true)
        {
            sender.Hide();
            return;
        }
        _ = ConfirmExitAsync();
    }

    private void ConfigureTray(bool enabled)
    {
        useSystemTray = enabled;
        if (window is null) return;
        if (!enabled)
        {
            if (!window.AppWindow.IsVisible) RestoreWindow();
            trayIcon?.Dispose();
            trayIcon = null;
            return;
        }
        if (trayIcon is not null) return;
        try
        {
            trayIcon = new SystemTrayIcon(
                window,
                Path.Combine(AppContext.BaseDirectory, "Assets", "Navigation", "pztools.ico"),
                RestoreWindow,
                () => _ = ConfirmExitAsync());
        }
        catch (Exception exception)
        {
            // 트레이를 사용할 수 없어도 창을 숨기지 않고 일반 종료 확인으로 전환합니다.
            System.Diagnostics.Debug.WriteLine(exception);
            useSystemTray = false;
        }
    }

    private void RestoreWindow()
    {
        if (window is null) return;
        window.AppWindow.Show();
        window.Activate();
    }

    private async Task ConfirmExitAsync()
    {
        if (exitDialogOpen || window is null) return;
        exitDialogOpen = true;
        try
        {
            if (!window.AppWindow.IsVisible) RestoreWindow();
            if (window.Content is not FrameworkElement root || root.XamlRoot is null)
                return;
            var dialog = new ContentDialog
            {
                XamlRoot = root.XamlRoot,
                Title = Localizer.Get("ConfirmExitTitle"),
                Content = Localizer.Get("ConfirmExitBody"),
                PrimaryButtonText = Localizer.Get("TrayExit"),
                CloseButtonText = Localizer.Get("Cancel"),
                DefaultButton = ContentDialogButton.Close,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var host = Host;
            Host = null;
            try
            {
                if (host is not null) await host.DisposeAsync();
            }
            catch (Exception exception)
            {
                System.Diagnostics.Debug.WriteLine(exception);
            }
            exitConfirmed = true;
            window.Close();
        }
        catch (Exception exception)
        {
            // 다른 대화 상자가 열려 있으면 현재 종료 요청만 취소합니다.
            System.Diagnostics.Debug.WriteLine(exception);
        }
        finally { exitDialogOpen = false; }
    }

    private static AppHost CreateHost(string runtime)
    {
        var layout = PzTools.Process.Contracts.PzToolsPathLayout.CreateDefault(
            dataRoot: runtime);
        var workerDirectory = AppWorkerDirectoryResolver.Resolve(
            AppContext.BaseDirectory,
            Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR"));
        return new AppHost(new AppHostPaths(
            runtime,
            workerDirectory,
            layout.StateDatabasePath,
            layout.SchedulerDatabasePath,
            layout.ControlDatabasePath,
            layout.OperationsRoot));
    }
}
