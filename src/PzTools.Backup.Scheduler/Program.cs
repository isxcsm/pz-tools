using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

if (args.FirstOrDefault() is "help" or "--help" or "-h")
{
    Console.WriteLine("PzTools Backup Scheduler");
    Console.WriteLine("  configure --scheduler-db <path> --repository <path> [--interval-minutes <0..60>]");
    Console.WriteLine("  run --scheduler-db <path> [--control-db <path>] [--worker-directory <path>] [--once]");
    return 0;
}

try
{
    var command = args.FirstOrDefault() ?? "run";
    var options = Parse(args.Skip(1).ToArray());
    var schedulerPath = Required(options, "--scheduler-db");
    var configurationPath = options.GetValueOrDefault("--config");
    var configuration = ComponentConfiguration.Load(schedulerPath, "backup-scheduler", configurationPath);
    var schedulerOptions = BackupSchedulerOptions.Read(configuration);
    var wakeInterval = schedulerOptions.WakeIntervalMs;
    var database = await SchedulerDatabase.CreateOrOpenAsync(schedulerPath);
    if (command == "configure")
    {
        var configuredMinutes = long.Parse(
            options.GetValueOrDefault("--interval-minutes")
            ?? "5",
            System.Globalization.CultureInfo.InvariantCulture);
        if (configuredMinutes is < 0 or > 60)
            throw new ArgumentOutOfRangeException("--interval-minutes");
        var effectiveMinutes = configuredMinutes == 0 ? 5 : configuredMinutes;
        await database.ConfigureBackupAsync(
            Required(options, "--repository"),
            automaticEnabled: configuredMinutes != 0,
            TimeSpan.FromMinutes(effectiveMinutes),
            DateTimeOffset.UtcNow);
        return 0;
    }

    if (command != "run") throw new ArgumentException("Expected configure or run.");
    var runtimeSnapshot = new RuntimeSnapshotStore();
    var adapter = new RunnerProcessAdapter(
        options.GetValueOrDefault("--worker-directory") ?? AppContext.BaseDirectory,
        options.GetValueOrDefault("--control-db"),
        sourcePath => runtimeSnapshot.Read().GameVersionFor(sourcePath));
    var allocator = new RunIndexAllocator(options.GetValueOrDefault("--control-db"));
    var runtimeSchedule = new RuntimeScheduleController(database, runtimeSnapshot);
    var scheduler = new BackupScheduler(
        database,
        token => allocator.AllocateAsync(cancellationToken: token),
        adapter.RunBackupAsync,
        adapter.RunMaintenanceAsync,
        configurationPath,
        TimeSpan.FromSeconds(schedulerOptions.PreparationLeadSeconds),
        target => AutomaticBackupActivity.Probe(target.SourcePath) == ActivityState.Active,
        runtimeSchedule, (admission, run, token) => adapter.RunGuardedBackupAsync(admission, run, token, database.DatabasePath));
    using var cancellation = new CancellationTokenSource();
    Console.CancelKeyPress += (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        cancellation.Cancel();
    };
    var mutex = NamedMutexRunner.CreateName(
        "BackupScheduler", database.DatabasePath);
    var result = await NamedMutexRunner.TryRunAsync(mutex, async token =>
    {
        using var feedCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
        var feed = RuntimeStateFeed.FollowAsync(schedulerPath, runtimeSnapshot, feedCancellation.Token);
        try
        {
        do
        {
            var tick = await scheduler.TickAsync(DateTimeOffset.UtcNow, token);
            if (tick.Due)
                Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(tick));
            if (options.ContainsKey("--once")) break;
            await Task.Delay(wakeInterval, token);
        } while (!token.IsCancellationRequested);
        return 0;
        }
        finally { await feedCancellation.CancelAsync(); try { await feed; } catch (OperationCanceledException) { } }
    }, cancellation.Token);
    return result.Acquired ? 0 : 75;
}
catch (OperationCanceledException)
{
    return 2;
}
catch (Exception exception) when (
    exception is ArgumentException or FormatException or OverflowException)
{
    Console.Error.WriteLine(exception.Message);
    return 64;
}
catch (Exception exception)
{
    Console.Error.WriteLine(exception.Message);
    return 1;
}

static Dictionary<string, string?> Parse(string[] arguments)
{
    var allowed = new HashSet<string>(StringComparer.Ordinal)
    {
        "--scheduler-db", "--repository", "--interval-minutes",
        "--worker-directory", "--once", "--config", "--control-db",
    };
    var result = new Dictionary<string, string?>(StringComparer.Ordinal);
    for (var index = 0; index < arguments.Length; index++)
    {
        var name = arguments[index];
        if (!allowed.Contains(name))
            throw new ArgumentException($"Unknown option '{name}'.");
        if (name == "--once")
        {
            result.Add(name, null);
            continue;
        }
        if (++index >= arguments.Length)
            throw new ArgumentException($"{name} requires a value.");
        result.Add(name, arguments[index]);
    }
    return result;
}

static string Required(Dictionary<string, string?> values, string name) =>
    values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
        ? value
        : throw new ArgumentException($"{name} is required.");
