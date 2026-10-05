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
    private HotKeyController? hotKeys;
    private bool useSystemTray;
    private bool exitConfirmed;
    private bool exitDialogOpen;

    private IDisposable? activationListener;
    private static int fatalReported;
    private UpdateChecker? updates;
    private readonly CancellationTokenSource updateLoop = new();

    /// <summary>What the app knows of its newer releases; null before the window exists.</summary>
    internal UpdateChecker? Updates => updates;
    private GameMemory? gameMemory;
    /// <summary>The game's memory setting, in the game's own launcher file.</summary>
    internal GameMemory? GameMemory => gameMemory;

    public App()
    {
        InitializeComponent();
        // The process ends after either of these. Leave a report and say so, instead of only
        // Windows' generic "unknown software exception" dialog.
        UnhandledException += (_, args) => ReportFatal("ui-thread", args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
            ReportFatal("background-thread", args.ExceptionObject as Exception);
    }

    private static void ReportFatal(string origin, Exception? exception)
    {
        if (Interlocked.Exchange(ref fatalReported, 1) != 0) return;
        System.Diagnostics.Debug.WriteLine(exception);
        string directory;
        try { directory = Path.Combine(PzToolsPathLayout.CreateDefault().DataRoot, "crash"); }
        catch (Exception) { directory = Path.Combine(Path.GetTempPath(), "PzTools", "crash"); }
        var report = CrashReport.TryWrite(directory, origin, exception, DateTimeOffset.UtcNow);
        string message;
        try { message = Localizer.Format("FatalErrorMessageFormat", report ?? "—"); }
        catch (Exception) { message = $"PZ Tools has to close because of an unexpected error. Error report: {report ?? "—"}"; }
        ShowFatalMessage(message);
    }

    // A native dialog: it works before the first window exists and while XAML is failing.
    private static void ShowFatalMessage(string message)
    {
        const uint IconError = 0x10, SetForeground = 0x10000;
        try { _ = MessageBoxW(nint.Zero, message, "PZ Tools", IconError | SetForeground); }
        catch (Exception) { }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int MessageBoxW(nint window, string text, string caption, uint type);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool AllowSetForegroundWindow(int processId);

    public AppHost? Host { get; private set; }
    public Window MainWindow => window ?? throw new InvalidOperationException(Localizer.Get("WindowNotCreated"));
    /// <summary>The key combinations the app holds for its actions; null before the window exists.</summary>
    internal HotKeyController? HotKeys => hotKeys;

    internal void ShowSidebarNotification(InfoBarSeverity severity, string title, string message)
    {
        if (window?.Content is MainWindowShell shell)
            shell.ShowSidebarNotification(severity, title, message);
    }

    /// <summary>Opens Settings at the switch that has the game keep its last minutes.</summary>
    internal void ShowRollingSetting()
    {
        if (window?.Content is MainWindowShell shell) shell.ShowSetting(SettingTarget.Rolling);
    }

    internal void ExplainOnOperationCard(string operationId, string message)
    {
        if (window?.Content is MainWindowShell shell)
            shell.ExplainOnOperationCard(operationId, message);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        runtimeRoot = PzTools.Process.Contracts.PzToolsPathLayout.CreateDefault().DataRoot;
        instanceLease = ApplicationInstanceLease.TryAcquire(runtimeRoot);
        if (instanceLease is null)
        {
            // Already running, possibly hidden in the tray. Bring that window forward rather than
            // exit with no sign of life; this launch may hand over its right to take the foreground.
            AllowSetForegroundWindow(-1);
            ApplicationActivationSignal.TrySignal(runtimeRoot);
            Exit();
            return;
        }
        try { Host = CreateHost(runtimeRoot); }
        catch (DirectoryNotFoundException exception)
        {
            // An incomplete copy of the app cannot be repaired from inside it: explain and leave.
            ShowFatalMessage(UserFacingError.FromException(exception));
            Exit();
            return;
        }
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
        updates = new UpdateChecker(Path.Combine(runtimeRoot, "update.json"),
            typeof(App).Assembly.GetName().Version ?? new Version(0, 0, 0));
        gameMemory = new GameMemory(Path.Combine(runtimeRoot, "game-memory.json"));
        window = new MainWindow();
        // Log entries the app wrote in another language are shown in today's; the table for that takes a second.
        Localizer.Warm();
        window.AppWindow.Closing += MainWindow_Closing;
        var dispatcher = window.DispatcherQueue;
        activationListener = ApplicationActivationSignal.Listen(runtimeRoot, () => dispatcher.Enqueue(RestoreWindow));
        window.Closed += async (_, _) =>
        {
            activationListener?.Dispose();
            activationListener = null;
            updateLoop.Cancel();
            hotKeys?.Dispose();
            hotKeys = null;
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
        hotKeys = new HotKeyController(this, window);
        hotKeys.Apply(settings);
        _ = StartHostAsync();
        _ = CheckForUpdatesAsync(updateLoop.Token);
        _ = WatchGameMemoryAsync(updateLoop.Token);
        _ = CheckInstallAsync(updateLoop.Token);
    }

    /// <summary>What is wrong with the app folder, once checked; none while it is whole or unchecked.</summary>
    internal InstallProblem? InstallProblem { get; private set; }

    // The app folder against the list of files it was published with, a little after the start, on a background thread
    // (the first start of a release reads every file once). A folder that is not whole says so on a card, and the
    // files go to the log.
    private async Task CheckInstallAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(8), cancellationToken);
            var root = runtimeRoot ?? throw new InvalidOperationException("No data folder.");
            var problem = await Task.Run(() => InstallIntegrity.Check(AppContext.BaseDirectory,
                Path.Combine(root, "install-check.json"), cancellationToken), cancellationToken);
            if (problem is null) return;
            InstallProblem = problem;
            Host?.RecordActionIssue(Localizer.Get("InstallBrokenTitle"), Localizer.Get("InstallBrokenMessage"), failed: true,
                diagnostics: problem.Describe());
            window?.DispatcherQueue.Enqueue(() => (window?.Content as MainWindowShell)?.ApplyInstallProblem());
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { System.Diagnostics.Debug.WriteLine(exception); }
    }

    // The game's file is read soon after the start and then every two minutes: a game update that puts its own memory
    // back is noticed while the app runs, not only at the next start. It is one small file.
    private async Task WatchGameMemoryAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
            using var timer = new PeriodicTimer(TimeSpan.FromMinutes(2));
            do
            {
                if (gameMemory is { } memory)
                {
                    try { await memory.RefreshAsync(cancellationToken); }
                    catch (Exception exception) when (exception is not OperationCanceledException)
                    {
                        System.Diagnostics.Debug.WriteLine(exception);
                    }
                }
            }
            while (await timer.WaitForNextTickAsync(cancellationToken));
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Opens Settings at the game's memory.</summary>
    internal void ShowGameMemorySetting()
    {
        if (window?.Content is MainWindowShell shell) shell.ShowSetting(SettingTarget.GameMemory);
    }

    // A while after the start, then every hour (unless the last check is under an hour old, after a restart). A failed
    // check is silent; the settings say when the last one succeeded, and checking there reports its failure.
    private async Task CheckForUpdatesAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(20), cancellationToken);
            using var timer = new PeriodicTimer(TimeSpan.FromHours(1));
            do
            {
                if (updates is { } checker && Host?.Views.ReadIfChanged<PzTools.Projections.SettingsView>(
                        PzTools.Projections.ViewKey.Settings, 0).Snapshot?.CheckForUpdates == true)
                {
                    try { await checker.CheckAsync(force: false, cancellationToken); }
                    catch (Exception exception) when (exception is not OperationCanceledException)
                    {
                        System.Diagnostics.Debug.WriteLine(exception);
                    }
                }
            }
            while (await timer.WaitForNextTickAsync(cancellationToken));
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>Opens a release page of this app's repository in the browser.</summary>
    internal bool OpenReleasePage(Uri page)
    {
        try
        {
            // The browser as the player's, not with this app's administrator rights.
            ShellLaunch.Open(page.AbsoluteUri);
            return true;
        }
        catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            ShowSidebarNotification(InfoBarSeverity.Error, Localizer.Get("UpdateSection.Header"), UserFacingError.FromException(exception));
            return false;
        }
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
        try { await ApplySettingsCoreAsync(settings); }
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
                // On success this process ends; the call returns only on failure.
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
            hotKeys?.Apply(settings);
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
        hotKeys?.Apply(settings);
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
            // Without a tray the window is not hidden; the usual exit confirmation is asked instead.
            System.Diagnostics.Debug.WriteLine(exception);
            useSystemTray = false;
        }
    }

    private void RestoreWindow()
    {
        if (window is null) return;
        window.AppWindow.Show();
        if (window.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter
            { State: Microsoft.UI.Windowing.OverlappedPresenterState.Minimized } presenter)
            presenter.Restore();
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
            // With another dialog open, only this exit request is cancelled.
            System.Diagnostics.Debug.WriteLine(exception);
        }
        finally { exitDialogOpen = false; }
    }

    private static AppHost CreateHost(string runtime)
    {
        var layout = PzTools.Process.Contracts.PzToolsPathLayout.CreateDefault(
            dataRoot: runtime);
        // The workers this app starts as administrator come from its own folder. Pointing it at others by an
        // environment variable is a development aid only: in a release build any program of the player's could set
        // it and have its own executables started with these rights.
        var workerDirectory = AppWorkerDirectoryResolver.Resolve(
            AppContext.BaseDirectory,
#if DEBUG
            Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR"));
#else
            null);
#endif
        return new AppHost(new AppHostPaths(
            runtime,
            workerDirectory,
            layout.StateDatabasePath,
            layout.SchedulerDatabasePath,
            layout.ControlDatabasePath,
            layout.OperationsRoot), dispatchCleanupOnExit: true, checkComponentLaunch: true);
    }
}
