using System.Text.Json;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.State;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

var started = DateTimeOffset.UtcNow;
var runIndex = 1L;
string? stateDb = null;
string? configurationPath = null;
var hasRunIndex = false;
try
{
    var values = Parse(args);
    stateDb = Required(values, "--state-db");
    var savesRoot = Required(values, "--saves-root");
    configurationPath = values.GetValueOrDefault("--config");
    if (values.TryGetValue("--run-index", out var run))
    {
        runIndex = long.Parse(run);
        if (runIndex <= 0) throw new ArgumentOutOfRangeException("--run-index");
    }
    else
    {
        runIndex = await new RunIndexAllocator(
            values.GetValueOrDefault("--control-db")).AllocateAsync();
    }
    hasRunIndex = true;
    var workerDirectory = values.GetValueOrDefault("--worker-directory") ?? AppContext.BaseDirectory;
    var mutex = NamedMutexRunner.CreateName("StateCollection", Path.GetFullPath(stateDb));
    var mutexResult = await NamedMutexRunner.TryRunAsync(mutex, async token =>
    {
        var host = new ChildProcessHost();
        var reactorArguments = new List<string> { "--state-db", stateDb, "--run-index", runIndex.ToString() };
        var reactorPath = Path.Combine(Path.GetFullPath(workerDirectory), "PzTools.State.Reactor.Cli.exe");
        var collectorPath = Path.Combine(Path.GetFullPath(workerDirectory), "PzTools.State.Collector.Cli.exe");
        var database = await StateDatabase.CreateOrOpenAsync(stateDb, token);
        // Recovery is required only after an interrupted run. Avoid an entire extra
        // process launch and telemetry write on every healthy polling cycle.
        var recovery = await database.HasPendingBatchesAsync(token)
            ? await RunChildAsync(host, reactorPath, "state-reactor", runIndex, reactorArguments, token)
            : null;
        var collection = await RunChildAsync(host, collectorPath, "state-collector", runIndex,
            ["--state-db", stateDb, "--saves-root", savesRoot, "--run-index", runIndex.ToString()], token);
        var applied = await RunChildAsync(
            host, reactorPath, "state-reactor", runIndex, reactorArguments, token);
        return JsonSerializer.Serialize(new { recovery, collection, applied });
    });
    if (!mutexResult.Acquired)
    {
        var busy = ProcessResultEnvelope<RunnerExecutionResult>.Success(
            "state-runner", runIndex, ProcessOutcome.Busy, started,
            new RunnerExecutionResult(false, null, "", "", false));
        Console.WriteLine(ProcessResultJson.Serialize(busy));
        return ProcessExitCodes.Busy;
    }
    await TryTelemetryAsync(
        stateDb, runIndex, "state-runner.completed", configurationPath);
    var envelope = ProcessResultEnvelope<RunnerExecutionResult>.Success(
        "state-runner", runIndex, ProcessOutcome.Succeeded, started,
        new RunnerExecutionResult(true, 0, mutexResult.Value!, "", mutexResult.WasAbandoned));
    Console.WriteLine(ProcessResultJson.Serialize(envelope));
    return 0;
}
catch (OperationCanceledException)
{
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        "state-runner", runIndex, ProcessOutcome.Cancelled, started,
        "cancelled", "State runner was cancelled.")));
    return ProcessExitCodes.Cancelled;
}
catch (Exception exception)
{
    if (hasRunIndex && stateDb is not null)
        await BestEffortProcessTelemetry.TryRecordAsync(
            stateDb, "state-runner", runIndex, "state-runner.failed",
            FailureTelemetry.FromException(
                "state-runner-failed", exception, phase: "state-check",
                operation: "state-check"),
            configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        "state-runner", runIndex, ProcessOutcome.Failed, started,
        "state-runner-failed", exception.Message)));
    return ProcessExitCodes.Failure;
}

static async Task<string> RunChildAsync(
    ChildProcessHost host,
    string executable,
    string expectedComponent,
    long expectedRunIndex,
    IReadOnlyList<string> arguments,
    CancellationToken token)
{
    var child = await host.RunAsync(executable, arguments, token);
    if (!child.Started)
    {
        throw new InvalidOperationException(
            string.IsNullOrWhiteSpace(child.StandardError)
                ? $"Child '{Path.GetFileName(executable)}' failed."
                : child.StandardError);
    }
    var envelope = ProcessResultValidator.Read<JsonElement>(child.StandardOutput,
        expectedComponent, expectedRunIndex, child.ExitCode, child.StandardError);
    if (envelope.Outcome != ProcessOutcome.Succeeded)
    {
        throw new InvalidOperationException(
            $"{expectedComponent}: "
            + (envelope.Error?.Message ?? $"Child outcome was {envelope.Outcome}."));
    }
    return child.StandardOutput.Trim();
}

static Dictionary<string, string> Parse(string[] arguments)
{
    var allowed = new HashSet<string>(StringComparer.Ordinal)
    {
        "--state-db", "--saves-root", "--run-index", "--worker-directory",
        "--config", "--control-db",
    };
    var values = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var index = 0; index < arguments.Length; index++)
    {
        var name = arguments[index];
        if (!allowed.Contains(name)) throw new ArgumentException($"Unknown option '{name}'.");
        if (++index >= arguments.Length) throw new ArgumentException($"{name} requires a value.");
        var value = arguments[index];
        values.Add(name, value);
    }
    return values;
}
static string Required(Dictionary<string, string> values, string name) =>
    values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
        ? value : throw new ArgumentException($"{name} is required.");
static async Task TryTelemetryAsync(
    string identity,
    long run,
    string name,
    string? configurationPath)
{
    await BestEffortProcessTelemetry.TryRecordAsync(
        identity, "state-runner", run, name,
        configurationPath: configurationPath);
}
