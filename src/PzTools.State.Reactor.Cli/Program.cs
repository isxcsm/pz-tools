using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.State;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

// Passed only by the state runner, which starts this program while it holds the collection lock itself.
const string RunnerHoldsLock = "--runner-holds-lock";
var started = DateTimeOffset.UtcNow;
var runIndex = 1L;
Dictionary<string, string?> values;
string statePath;
long? givenRunIndex;
try
{
    values = CommandLine.Parse(args, ["--state-db", "--run-index", "--config", "--control-db"], [RunnerHoldsLock]);
    givenRunIndex = CommandLine.OptionalInt64(values.GetValueOrDefault("--run-index"), "--run-index");
    runIndex = givenRunIndex ?? runIndex;
    statePath = CommandLine.Required(values, "--state-db");
}
catch (ArgumentException exception)
{
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "state-reactor", runIndex, ProcessOutcome.Failed, started,
            "invalid-arguments", exception.Message)));
    return ProcessExitCodes.InvalidArguments;
}
var configurationPath = values.GetValueOrDefault("--config");
var hasRunIndex = false;
try
{
    var database = await StateDatabase.CreateOrOpenAsync(statePath);
    runIndex = givenRunIndex
        ?? await new RunIndexAllocator(values.GetValueOrDefault("--control-db")).AllocateAsync();
    if (runIndex <= 0) throw new ArgumentOutOfRangeException("--run-index");
    hasRunIndex = true;
    // Run on its own, it takes the lock every other state writer takes, so it never applies batches
    // while the app's own check is between reading the saves and applying what it saw.
    var reacted = values.ContainsKey(RunnerHoldsLock)
        ? new MutexRunResult<ReactorResult>(true, false, await new StateReactor().RunAsync(database))
        : await NamedMutexRunner.TryRunAsync(
            NamedMutexRunner.CreateName("StateCollection", Path.GetFullPath(statePath)),
            token => new StateReactor().RunAsync(database, token));
    if (!reacted.Acquired)
    {
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Success("state-reactor", runIndex, ProcessOutcome.Busy, started)));
        return ProcessExitCodes.Busy;
    }
    await TryTelemetryAsync(
        statePath, runIndex, "reactor.completed", configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<ReactorResult>.Success(
            "state-reactor", runIndex, ProcessOutcome.Succeeded, started, reacted.Value)));
    return 0;
}
catch (Exception exception)
{
    if (hasRunIndex)
        await BestEffortProcessTelemetry.TryRecordAsync(
            statePath, "state-reactor", runIndex, "reactor.failed",
            FailureTelemetry.FromException(
                "reactor-failed", exception, phase: "state-reaction",
                operation: "state-reaction"),
            configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "state-reactor", runIndex, ProcessOutcome.Failed, started, "reactor-failed", exception.Message)));
    return 1;
}
static async Task TryTelemetryAsync(
    string identity,
    long run,
    string name,
    string? configurationPath)
{
    await BestEffortProcessTelemetry.TryRecordAsync(
        identity, "state-reactor", run, name,
        configurationPath: configurationPath);
}
