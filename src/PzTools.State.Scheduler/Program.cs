using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Scheduling;
using PzTools.Zomboid.State;
using PzTools.State.Scheduler;

if (args.FirstOrDefault() is "help" or "--help" or "-h")
{
    Console.WriteLine("PzTools State Scheduler");
    Console.WriteLine("  --scheduler-db <path> --state-db <path> --saves-root <path>");
    Console.WriteLine("  [--repository <path>] [--control-db <path>] [--interval-seconds <n>] [--worker-directory <path>] [--once]");
    return 0;
}

try
{
    var options = Parse(args);
    var schedulerPath = Required(options, "--scheduler-db");
    var configurationPath = options.GetValueOrDefault("--config");
    var configuration = ComponentConfiguration.Load(
        schedulerPath, "state-scheduler", configurationPath);
    var settings = StateSchedulerOptions.Read(configuration);
    var wakeInterval = TimeSpan.FromMilliseconds(settings.WakeIntervalMs);
    var confirmationDelay = TimeSpan.FromMilliseconds(settings.ConfirmationDelayMs);
    var cleanupInterval = settings.CleanupIntervalSeconds;
    var schedulerDb = await SchedulerDatabase.CreateOrOpenAsync(schedulerPath);
    var stateDb = await StateDatabase.CreateOrOpenAsync(Required(options, "--state-db"));
    var savesRoot = Required(options, "--saves-root");
    var interval = TimeSpan.FromSeconds(long.Parse(
        options.GetValueOrDefault("--interval-seconds")
        ?? settings.IntervalSeconds.ToString(
            System.Globalization.CultureInfo.InvariantCulture)));
    var runtime = new RuntimeSnapshotStore();
    var extensions = new RuntimeExtensionStatusStore();
    bool useRuntime = false;
    var stateChecks = new StateCheckPipeline(() => useRuntime ? runtime.Read() : null);
    var allocator = new RunIndexAllocator(options.GetValueOrDefault("--control-db"));
    var scheduler = new StateScheduler(
        schedulerDb, interval,
        token => allocator.AllocateAsync(cancellationToken: token),
        (run, token) => stateChecks.RunAsync(stateDb, savesRoot, run, token),
        configurationPath);
    var relay = new StateOutboxRelay();
    var orphanCleanup = options.GetValueOrDefault("--repository") is { } repositoryPath
        ? new OrphanCleanupDispatcher(repositoryPath, savesRoot,
            options.GetValueOrDefault("--worker-directory") ?? AppContext.BaseDirectory,
            options.GetValueOrDefault("--control-db"), cleanupInterval) : null;
    using var cancellation = new CancellationTokenSource();
    Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };
    var mutex = NamedMutexRunner.CreateName("StateScheduler", schedulerDb.DatabasePath + "|" + stateDb.DatabasePath);
    var result = await NamedMutexRunner.TryRunAsync(mutex, async token =>
    {
        using var runtimeCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
        var runtimeFeed = RuntimeStateFeed.ServeAsync(schedulerPath, runtime, runtimeCancellation.Token, extensions);
        var observation = new RuntimeObservationCoordinator(stateDb, schedulerDb, savesRoot,
            Path.Combine(options.GetValueOrDefault("--worker-directory") ?? AppContext.BaseDirectory, "save-bridge"), runtime,
            options.GetValueOrDefault("--runtime-root") ?? Path.GetDirectoryName(Path.GetFullPath(schedulerPath))!, extensions);
        var runtimeObservation = observation.RunAsync(runtimeCancellation.Token);
        try
        {
        using var gameExitWatcher = new GameProcessExitWatcher();
        async Task<bool> RunAndRelayAsync(bool force)
        {
            useRuntime = (await schedulerDb.ReadRuntimeScheduleAsync(token)).Enabled;
            var tick = await scheduler.TickAsync(DateTimeOffset.UtcNow, token, force);
            if (!tick.Due) return false;
            await relay.RelayAsync(stateDb, schedulerDb, token);
            Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(tick));
            return tick.Runner is { Started: true, Outcome: ProcessOutcome.Succeeded };
        }

        var confirmationsRemaining = 2;
        do
        {
            // Failed background observation/feed tasks must reach the existing host supervisor.
            if (runtimeObservation.IsCompleted) { await runtimeObservation; throw new IOException("Runtime observation stopped."); }
            if (runtimeFeed.IsCompleted) { await runtimeFeed; throw new IOException("Runtime state feed stopped."); }
            gameExitWatcher.Refresh();
            // Persisted due times must not delay the first probe after launching the app.
            var confirmed = await RunAndRelayAsync(force: confirmationsRemaining > 0);
            if (confirmed && confirmationsRemaining > 0) confirmationsRemaining--;
            if (orphanCleanup is not null) await orphanCleanup.TickAsync(DateTimeOffset.UtcNow, token);
            if (options.ContainsKey("--once")) break;
            if (confirmationsRemaining > 0)
            {
                // Busy/failed acquisition is not an observation. Keep confirming instead of
                // sleeping until a previously persisted (possibly very distant) due time.
                await Task.Delay(confirmationDelay, token);
                continue;
            }
            if (await gameExitWatcher.WaitAsync(wakeInterval, token))
                confirmationsRemaining = 2;
        } while (!token.IsCancellationRequested);
        return 0;
        }
        finally
        {
            await runtimeCancellation.CancelAsync();
            try { await Task.WhenAll(runtimeFeed, runtimeObservation); } catch (OperationCanceledException) { }
        }
    }, cancellation.Token);
    return result.Acquired ? 0 : 75;
}
catch (OperationCanceledException) { return 2; }
catch (Exception exception) when (
    exception is ArgumentException or FormatException or OverflowException)
{
    Console.Error.WriteLine(exception.Message);
    return 64;
}
catch (Exception exception) { Console.Error.WriteLine(exception.Message); return 1; }

static Dictionary<string, string?> Parse(string[] arguments)
{
    var allowed = new HashSet<string>(StringComparer.Ordinal)
    {
        "--scheduler-db", "--state-db", "--saves-root", "--interval-seconds",
        "--worker-directory", "--once", "--config", "--control-db", "--repository", "--runtime-root",
    };
    var result = new Dictionary<string, string?>(StringComparer.Ordinal);
    for (var index = 0; index < arguments.Length; index++)
    {
        var name = arguments[index];
        if (!allowed.Contains(name)) throw new ArgumentException($"Unknown option '{name}'.");
        if (name == "--once") { result.Add(name, null); continue; }
        if (++index >= arguments.Length) throw new ArgumentException($"{name} requires a value.");
        var value = arguments[index];
        result.Add(name, value);
    }
    return result;
}
static string Required(Dictionary<string, string?> values, string name) =>
    values.TryGetValue(name, out var value) && value is not null ? value : throw new ArgumentException($"{name} is required.");
