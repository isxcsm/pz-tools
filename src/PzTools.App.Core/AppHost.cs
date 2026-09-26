using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Projections;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.App.Core;

public sealed record AppHostPaths(
    string RuntimeRoot,
    string WorkerDirectory,
    string StateDatabasePath,
    string SchedulerDatabasePath,
    string? ControlDatabasePath = null,
    string? OperationsRoot = null);

public sealed class AppHost : IAsyncDisposable
{
    public static ViewKey SchedulerHostsViewKey { get; } = new("scheduler-hosts");

    private readonly AppHostPaths paths;
    private readonly IManagedProcessLauncher launcher;
    private readonly Func<int, TimeSpan> restartDelay;
    private readonly CancellationTokenSource lifetime = new();
    private readonly List<Task> supervisors = [];
    private readonly Dictionary<string, SchedulerHostStatus> schedulerStatuses =
        new(StringComparer.Ordinal);
    private readonly object statusGate = new();
    private bool started;
    private readonly SemaphoreSlim refreshGate = new(1, 1);
    private readonly object disposalGate = new();
    private Task? disposalTask;
    private readonly AppRuntimeOptions runtime;
    private readonly Exception? runtimeConfigurationError;
    public AppRuntimeOptions RuntimeOptions => runtime;

    public AppHost(
        AppHostPaths paths,
        IManagedProcessLauncher? launcher = null,
        RevisionedViewStore? views = null,
        ProjectionHost? projections = null,
        TelemetrySourceCatalog? telemetrySources = null,
        Func<int, TimeSpan>? restartDelay = null)
    {
        this.paths = paths with
        {
            RuntimeRoot = Path.GetFullPath(paths.RuntimeRoot),
            WorkerDirectory = Path.GetFullPath(paths.WorkerDirectory),
            StateDatabasePath = Path.GetFullPath(paths.StateDatabasePath),
            SchedulerDatabasePath = Path.GetFullPath(paths.SchedulerDatabasePath),
            ControlDatabasePath = Path.GetFullPath(paths.ControlDatabasePath
                ?? Path.Combine(paths.RuntimeRoot, "control.db")),
            OperationsRoot = Path.GetFullPath(paths.OperationsRoot
                ?? Path.Combine(paths.RuntimeRoot, "operations")),
        };
        try
        {
            runtime = AppRuntimeOptions.Read(ComponentConfiguration.Load(this.paths.RuntimeRoot, "app",
                configurationRoot: Path.Combine(this.paths.RuntimeRoot, "config")));
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException or Tomlyn.TomlException)
        {
            // Keep settings repair available, but never start workers with rejected tuning.
            runtime = new();
            runtimeConfigurationError = exception;
        }
        Thumbnails = new ThumbnailCache(runtime.ThumbnailCacheMib * 1024L * 1024,
            runtime.ThumbnailMaximumMib * 1024L * 1024);
        this.launcher = launcher ?? new ManagedProcessLauncher(runtime.ShutdownGraceMs);
        this.restartDelay = restartDelay
            ?? (attempt => TimeSpan.FromMilliseconds(runtime.SchedulerRestartBaseMs * Math.Pow(2, attempt - 1)));
        Views = views ?? new RevisionedViewStore();
        SettingsProjector = new SettingsProjector(Views);
        Projections = projections ?? new ProjectionHost();
        TelemetrySources = telemetrySources ?? new TelemetrySourceCatalog();
        Settings = new AppSettingsService(this.paths.RuntimeRoot, HasRunningOperation);
        GameExtensions = new GameExtensionController(this.paths.RuntimeRoot, Views, () => Settings.Load().SaveGameBeforeBackup);
    }

    public RevisionedViewStore Views { get; }
    public ProjectionHost Projections { get; }
    public TelemetrySourceCatalog TelemetrySources { get; }
    public AppSettingsService Settings { get; }
    public GameExtensionController GameExtensions { get; }
    public SettingsProjector SettingsProjector { get; }
    public RepositoryDatabase? Repository { get; private set; }
    public SchedulerDatabase? Scheduler { get; private set; }
    public string? ActiveSavesRoot { get; private set; }
    public OperationCoordinator? Operations { get; private set; }
    public TelemetryProjectionHost? Telemetry { get; private set; }
    public LogInboxStore? LogInbox { get; private set; }
    public ThumbnailCache Thumbnails { get; }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (runtimeConfigurationError is not null)
            throw new InvalidDataException("Cannot start workers: invalid app runtime configuration.", runtimeConfigurationError);
        if (started) return;
        started = true;
        var observationBoundary = DateTimeOffset.UtcNow;
        Directory.CreateDirectory(paths.RuntimeRoot);
        var state = await StateDatabase.CreateOrOpenAsync(paths.StateDatabasePath, cancellationToken);
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(
            paths.SchedulerDatabasePath, cancellationToken);
        Scheduler = scheduler;
        var settings = Settings.Load();
        foreach (var (identity, component) in new[]
        {
            (paths.SchedulerDatabasePath, "backup-scheduler"),
            (paths.SchedulerDatabasePath, "state-scheduler"),
            (paths.StateDatabasePath, "state-runner"),
            (paths.StateDatabasePath, "state-collector"),
            (paths.StateDatabasePath, "state-reactor"),
            (settings.BackupRoot, "backup-runner"),
            (settings.BackupRoot, "maintenance-runner"),
            (settings.BackupRoot, "maintenance-worker"),
            (settings.BackupRoot, "backup-worker"),
            (settings.BackupRoot, "archive-worker"),
            (settings.BackupRoot, "restore-worker"),
            (settings.BackupRoot, "character-recovery"),
        })
        {
            if (component != "backup-worker")
                await Settings.EnsureComponentConfigurationAsync(
                    identity, component, cancellationToken);
        }
        Settings.ValidateEditableConfiguration();
        PublishSettings(settings);
        ActiveSavesRoot = settings.SavesRoot;
        LogInbox = await LogInboxStore.CreateOrOpenAsync(
            Path.Combine(paths.RuntimeRoot, "logs.db"), cancellationToken);
        await LogInbox.ConfigureStorageAsync(settings.LogRecordMinimumLevel,
            settings.LogMaxEntries, cancellationToken);
        var telemetry = new TelemetryProjectionHost(
            TelemetrySources, Views, TimeSpan.FromSeconds(runtime.TelemetryStaleSeconds),
            maximumPagesPerProjection: runtime.TelemetryPagesPerRefresh, logInbox: LogInbox,
            initialReadGrace: TimeSpan.FromMilliseconds(runtime.TelemetryReadGraceMs),
            successCardLifetime: TimeSpan.FromSeconds(runtime.SuccessCardSeconds),
            failureCardLifetime: TimeSpan.FromSeconds(runtime.FailureCardSeconds),
            retireSource: new OperationTelemetryCleanup(paths.OperationsRoot!).TryRemove,
            readTimeoutSeconds: runtime.TelemetryReadTimeoutSeconds);
        telemetry.ConfigureRecordingLevel(settings.LogRecordMinimumLevel);
        telemetry.ConfigureLogs(new LogProjectionOptions(
            settings.LogRecordMinimumLevel, settings.LogDisplayLimit));
        Telemetry = telemetry;
        // 저장소와 예전 이벤트 재생이 끝나기 전에도 보관된 로그를 표시합니다.
        await telemetry.RefreshLogViewAsync(cancellationToken);
        await Settings.SaveAndApplyAsync(
            settings, scheduler, cancellationToken);
        var repository = await RepositoryDatabase.CreateOrOpenAsync(
            settings.BackupRoot, cancellationToken);
        InterruptedOperationRecoveryResult recovery;
        try
        {
            recovery = await new InterruptedOperationRecoveryService().TryRunAsync(
                repository, settings.SavesRoot, cancellationToken);
        }
        catch (RepositoryBusyException) { recovery = new(true, 0, 0, 0, []); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
        { recovery = new(false, 0, 0, 0, [new(repository.RepositoryPath, exception.Message)]); }
        try
        {
            await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
            await repository.AssignMissingRevisionNamesAsync(lease,
                settings.Language, cancellationToken);
        }
        catch (RepositoryBusyException) { }
        if (recovery.RecoveredWorkflows + recovery.RecoveredSaves + recovery.DeletedArtifacts > 0 || recovery.Problems.Count > 0)
        {
            var recoveryRun = await new RunIndexAllocator(paths.ControlDatabasePath).AllocateAsync(cancellationToken: cancellationToken);
            await BestEffortProcessTelemetry.TryRecordAsync(repository.RepositoryPath, "maintenance-worker", recoveryRun,
                recovery.Problems.Count == 0 ? "maintenance.recovery.completed" : "maintenance.recovery.failed",
                System.Text.Json.JsonSerializer.Serialize(recovery));
        }
        Repository = repository;
        Operations = new OperationCoordinator(
            repository, paths.WorkerDirectory, TelemetrySources, launcher,
            new RunIndexAllocator(paths.ControlDatabasePath),
            paths.OperationsRoot!, runtime, LogInbox);
        var stateProjector = new StateProjector(state, Views, observationBoundary);
        var backupProjector = new BackupProjector(repository, Views);
        var characterMetadata = new PzTools.Zomboid.Backup.RevisionCharacterMetadataCollector(
            runtime.CharacterMetadataBatchSize, runtime.CharacterMetadataRetrySeconds);
        var schedulerProjector = new SchedulerProjector(scheduler, Views, repository, requireActiveState: true);
        var composer = new SaveDetailComposer(Views);
        RegisterTelemetrySources(settings, state, scheduler, repository);
        var projectionInterval = TimeSpan.FromMilliseconds(runtime.ProjectionIntervalMs);
        Projections.AddLoop("state", stateProjector.ProjectOnceAsync, projectionInterval);
        Projections.AddLoop("backup", backupProjector.ProjectOnceAsync, projectionInterval);
        Projections.AddLoop("character-metadata", token => characterMetadata.CollectOnceAsync(repository, token), projectionInterval);
        Projections.AddLoop("scheduler", schedulerProjector.ProjectOnceAsync, projectionInterval);
        Projections.AddLoop("details", composer.ComposeOnceAsync, projectionInterval);
        Projections.AddLoop("telemetry", token => telemetry.ProjectOnceAsync(cancellationToken: token),
            projectionInterval);
        Projections.AddLoop("health", _ =>
        {
            Views.Publish(
                ViewKey.ProjectorHealth,
                new ProjectorHealthView(Projections.Statuses
                    .Where(item => item.Name != "health").ToArray()),
                comparer: ViewComparers.Health);
            return Task.CompletedTask;
        }, projectionInterval);
        // A new app session starts a full interval, never catches up an overdue
        // periodic reservation. Worker restarts and settings refreshes do not reset it.
        await scheduler.RestartPeriodicScheduleAsync(DateTimeOffset.UtcNow, cancellationToken);
        Projections.Start();

        var backupArguments = new[]
        {
            "run", "--scheduler-db", scheduler.DatabasePath,
            "--worker-directory", paths.WorkerDirectory,
            "--control-db", paths.ControlDatabasePath!,
        };
        var stateArguments = new[]
        {
            "--scheduler-db", scheduler.DatabasePath,
            "--state-db", state.DatabasePath,
            "--saves-root", settings.SavesRoot,
            "--repository", settings.BackupRoot,
            "--worker-directory", paths.WorkerDirectory,
            "--control-db", paths.ControlDatabasePath!,
        };
        supervisors.Add(SuperviseAsync(
            "backup-scheduler",
            Path.Combine(paths.WorkerDirectory, "PzTools.Backup.Scheduler.exe"),
            backupArguments,
            lifetime.Token));
        supervisors.Add(SuperviseAsync(
            "state-scheduler",
            Path.Combine(paths.WorkerDirectory, "PzTools.State.Scheduler.exe"),
            stateArguments,
            lifetime.Token));
        // 과거 작업 로그의 발견은 첫 세이브 목록/상세 투영을 막지 않습니다.
        await RegisterHistoricalOperationTelemetrySourcesAsync(cancellationToken);
    }

    public ValueTask DisposeAsync()
    {
        // Shutdown can begin on the UI thread. Cancellation callbacks and process
        // teardown must not run there, and repeated callers await the same cleanup.
        lock (disposalGate)
            return new ValueTask(disposalTask ??= Task.Run(DisposeCoreAsync));
    }

    private async Task DisposeCoreAsync()
    {
        lifetime.Cancel();
        Projections.RequestStop();
        try
        {
            // Stop projections now, not after both scheduler processes exit.
            await Task.WhenAll(
                WaitForSupervisorsAsync(),
                DrainProjectionsAsync()).ConfigureAwait(false);
        }
        finally { lifetime.Dispose(); }

        async Task WaitForSupervisorsAsync()
        {
            try { await Task.WhenAll(supervisors).ConfigureAwait(false); }
            catch (OperationCanceledException) { }
        }

        async Task DrainProjectionsAsync()
        {
            // RefreshSaveViewsAsync may still be unwinding a ProjectNowAsync
            // call. Keep its cancellation source alive until refresh has left.
            await refreshGate.WaitAsync().ConfigureAwait(false);
            refreshGate.Release();
            await Projections.DisposeAsync().ConfigureAwait(false);
        }
    }

    public void PublishSettings(AppSettings settings)
        => SettingsProjector.Project(settings);

    public async Task RefreshSaveViewsAsync(bool collectState = true, CancellationToken cancellationToken = default)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token, cancellationToken);
        linked.CancelAfter(TimeSpan.FromSeconds(runtime.StateRefreshTimeoutSeconds));
        await refreshGate.WaitAsync(linked.Token);
        try
        {
            if (collectState)
                await (Operations ?? throw new InvalidOperationException("The app host is not ready."))
                    .RefreshStateAsync(paths.StateDatabasePath, ActiveSavesRoot!, linked.Token);
            // 정기 루프와 직렬화하고, 상세 합성 전에 원본 뷰를 갱신합니다.
            foreach (var name in new[] { "state", "backup", "details", "health" })
                await Projections.ProjectNowAsync(name, linked.Token);
        }
        finally { refreshGate.Release(); }
    }

    public async Task ApplySettingsAsync(
        AppSettings settings,
        CancellationToken cancellationToken = default)
    {
        var scheduler = Scheduler
            ?? throw new InvalidOperationException("The app host is not ready.");
        await Settings.SaveAndApplyAsync(
            settings,
            scheduler,
            cancellationToken);
        if (LogInbox is not null)
            await LogInbox.ConfigureStorageAsync(settings.LogRecordMinimumLevel,
                settings.LogMaxEntries, cancellationToken);
        Telemetry?.ConfigureLogs(new LogProjectionOptions(
            settings.LogRecordMinimumLevel, settings.LogDisplayLimit));
        Telemetry?.ConfigureRecordingLevel(settings.LogRecordMinimumLevel);
        PublishSettings(settings);
    }

    public async Task ApplyLogOptionsAsync(LogLevel minimumLevel, int displayLimit)
    {
        var settings = await Settings.SaveLogOptionsAsync(minimumLevel, displayLimit);
        Telemetry?.ConfigureLogs(new LogProjectionOptions(minimumLevel, displayLimit));
        PublishSettings(settings);
    }

    public async Task<LogsView> AcknowledgeLogIssueAsync(
        string incidentKey, CancellationToken cancellationToken = default)
    {
        await (LogInbox ?? throw new InvalidOperationException("The log inbox is not ready."))
            .AcknowledgeIssueAsync(incidentKey, long.MaxValue, cancellationToken);
        return await (Telemetry ?? throw new InvalidOperationException("Log projection is not ready."))
            .RefreshLogViewAsync(cancellationToken);
    }

    public async Task<LogsView> AcknowledgeAllLogIssuesAsync(
        CancellationToken cancellationToken = default)
    {
        await (LogInbox ?? throw new InvalidOperationException("The log inbox is not ready."))
            .AcknowledgeAllAsync(cancellationToken);
        return await (Telemetry ?? throw new InvalidOperationException("Log projection is not ready."))
            .RefreshLogViewAsync(cancellationToken);
    }

    private async Task SuperviseAsync(
        string name,
        string executable,
        IReadOnlyList<string> arguments,
        CancellationToken token)
    {
        var maximumRestarts = runtime.SchedulerRestartAttempts;
        var restart = 0;
        while (!token.IsCancellationRequested)
        {
            PublishStatus(new SchedulerHostStatus(
                name,
                restart == 0 ? SchedulerHostState.Starting : SchedulerHostState.Restarting,
                restart, null, null));
            ManagedProcessExit exit;
            try
            {
                var running = launcher.RunAsync(
                    executable, arguments, _ => { }, _ => { }, token);
                PublishStatus(new SchedulerHostStatus(
                    name, SchedulerHostState.Running, restart, null, null));
                exit = await running;
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                PublishStatus(new SchedulerHostStatus(
                    name, SchedulerHostState.Stopped, restart, null, null));
                return;
            }
            catch (Exception exception)
            {
                exit = new ManagedProcessExit(
                    false,
                    null,
                    $"launcher-{exception.GetType().Name}");
            }
            if (++restart > maximumRestarts)
            {
                PublishStatus(new SchedulerHostStatus(
                    name, SchedulerHostState.Faulted, restart - 1,
                    exit.ExitCode, exit.FailureCode));
                return;
            }
            await Task.Delay(restartDelay(restart), token);
        }
    }

    private void PublishStatus(SchedulerHostStatus status)
    {
        SchedulerHostStatus[] snapshot;
        lock (statusGate)
        {
            schedulerStatuses[status.Name] = status;
            snapshot = schedulerStatuses.Values.OrderBy(item => item.Name).ToArray();
        }
        Views.Publish(
            SchedulerHostsViewKey,
            new SchedulerHostView(snapshot),
            comparer: SchedulerHostView.Comparer);
    }

    public bool HasRunningOperation() =>
        Operations?.IsDeletionRunning == true || Views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot?.Operations
            .Any(item => item.Status == OperationStatus.Running) == true;

    private void RegisterTelemetrySources(
        AppSettings settings,
        StateDatabase state,
        SchedulerDatabase scheduler,
        RepositoryDatabase repository)
    {
        TelemetrySources.Register(new TelemetrySourceRegistration(
            "backup-worker",
            "backup-worker",
            repository.RepositoryPath,
            Path.Combine(repository.RepositoryPath, "telemetry.db"),
            TelemetryDatabaseKind.Backup,
            true));
        foreach (var (id, component, identity) in new[]
        {
            ("backup-scheduler", "backup-scheduler", scheduler.DatabasePath),
            ("state-scheduler", "state-scheduler", scheduler.DatabasePath),
            ("state-runner", "state-runner", state.DatabasePath),
            ("state-collector", "state-collector", state.DatabasePath),
            ("state-reactor", "state-reactor", state.DatabasePath),
            ("maintenance-worker", "maintenance-worker", settings.BackupRoot),
        })
        {
            TelemetrySources.Register(new TelemetrySourceRegistration(
                id,
                component,
                identity,
                Path.Combine(
                    ComponentRuntimePaths.GetComponentDirectory(identity, component),
                    "telemetry.db"),
                TelemetryDatabaseKind.Process,
                true));
        }
        foreach (var lane in MaintenanceLaneSignal.HeavyLanes)
        {
            var component = $"maintenance-lane-{lane}";
            TelemetrySources.Register(new TelemetrySourceRegistration(
                component,
                component,
                settings.BackupRoot,
                Path.Combine(
                    ComponentRuntimePaths.GetComponentDirectory(settings.BackupRoot, component),
                    "telemetry.db"),
                TelemetryDatabaseKind.Process,
                true));
        }
        foreach (var component in new[] { "backup-runner", "maintenance-runner" })
        {
            TelemetrySources.Register(new TelemetrySourceRegistration(
                component, component, settings.BackupRoot,
                Path.Combine(ComponentRuntimePaths.GetComponentDirectory(settings.BackupRoot, component), "telemetry.db"),
                TelemetryDatabaseKind.Process, true, LogsOnly: true));
        }
    }

    private async Task RegisterHistoricalOperationTelemetrySourcesAsync(
        CancellationToken cancellationToken)
    {
        var imported = await (LogInbox ?? throw new InvalidOperationException("The log inbox is not ready."))
            .ReadImportedSourcesAsync(cancellationToken);
        var cleanup = new OperationTelemetryCleanup(paths.OperationsRoot!);
        foreach (var (component, pattern) in new[]
                 {
                     ("archive-worker", "archive-*"),
                     ("restore-worker", "restore-*"),
                     ("character-recovery", "character-recovery-*"),
                 })
        {
            var operationRoot = Path.Combine(paths.OperationsRoot!, component);
            if (!Directory.Exists(operationRoot)) continue;
            foreach (var identity in Directory.EnumerateDirectories(
                         operationRoot, pattern, SearchOption.TopDirectoryOnly))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var sourceId = Path.GetFileName(identity);
                var databasePath = Path.Combine(
                    ComponentRuntimePaths.GetComponentDirectory(identity, component),
                    "telemetry.db");
                if (!File.Exists(databasePath) && !imported.Contains(sourceId)) continue;
                // Import once into logs.db without resurrecting completed operation cards.
                var completed = DateTimeOffset.MinValue;
                var source = new TelemetrySourceRegistration(
                    sourceId, component, identity, databasePath,
                    TelemetryDatabaseKind.Process, true,
                    new WorkflowOperation($"history:{sourceId}", component, 0,
                        OperationStatus.Succeeded, completed, completed),
                    Transient: true, LogsOnly: true);
                if (imported.Contains(sourceId) && cleanup.TryRemove(source))
                {
                    await LogInbox!.ForgetImportedSourceAsync(sourceId, cancellationToken);
                    continue;
                }
                TelemetrySources.Register(source);
            }
        }
    }
}
