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
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cancellation.Cancel();
};
// A stop request is passed on to the collector or reactor running at the time, and this runner reports the
// cancellation, instead of all of them being ended outright.
using var stopRequest = ProcessStopSignal.Listen(cancellation);
string? stateDb = null;
string? configurationPath = null;
var hasRunIndex = false;
try
{
    var values = CommandLine.Parse(args,
        ["--state-db", "--saves-root", "--run-index", "--worker-directory", "--config", "--control-db"]);
    stateDb = CommandLine.Required(values, "--state-db");
    var savesRoot = CommandLine.Required(values, "--saves-root");
    configurationPath = values.GetValueOrDefault("--config");
    if (values.TryGetValue("--run-index", out var run))
    {
        runIndex = CommandLine.Int64(run, "--run-index");
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
        // The children would otherwise take this lock themselves, and find it held by this process.
        var reactorArguments = new List<string> { "--state-db", stateDb, "--run-index", runIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), "--runner-holds-lock" };
        var reactorPath = Path.Combine(Path.GetFullPath(workerDirectory), "PzTools.State.Reactor.Cli.exe");
        var collectorPath = Path.Combine(Path.GetFullPath(workerDirectory), "PzTools.State.Collector.Cli.exe");
        var database = await StateDatabase.CreateOrOpenAsync(stateDb, token);
        // Recovery is required only after an interrupted run. Avoid an entire extra
        // process launch and telemetry write on every healthy polling cycle.
        var recovery = await database.HasPendingBatchesAsync(token)
            ? await RunChildAsync(host, reactorPath, "state-reactor", runIndex, reactorArguments, token)
            : null;
        var collection = await RunChildAsync(host, collectorPath, "state-collector", runIndex,
            ["--state-db", stateDb, "--saves-root", savesRoot, "--run-index", runIndex.ToString(System.Globalization.CultureInfo.InvariantCulture), "--runner-holds-lock"], token);
        var applied = await RunChildAsync(
            host, reactorPath, "state-reactor", runIndex, reactorArguments, token);
        return JsonSerializer.Serialize(new { recovery, collection, applied });
    }, cancellation.Token);
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
catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
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
    var child = await host.RunAsync(executable, arguments, token,
        shutdownGraceMs: ChildProcessHost.NestedShutdownGraceMs);
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
