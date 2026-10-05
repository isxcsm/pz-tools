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
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cancellation.Cancel();
};
// The state runner passes its stop request on. A collection asked to stop writes no batch and says it was
// cancelled, instead of being ended outright with nothing said.
using var stopRequest = ProcessStopSignal.Listen(cancellation);
Dictionary<string, string?> values;
string statePath, savesRoot;
long? givenRunIndex;
try
{
    values = CommandLine.Parse(args, ["--state-db", "--saves-root", "--run-index", "--config", "--control-db"],
        [RunnerHoldsLock]);
    givenRunIndex = CommandLine.OptionalInt64(values.GetValueOrDefault("--run-index"), "--run-index");
    runIndex = givenRunIndex ?? runIndex;
    statePath = CommandLine.Required(values, "--state-db");
    savesRoot = CommandLine.Required(values, "--saves-root");
}
catch (ArgumentException exception)
{
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "state-collector", runIndex, ProcessOutcome.Failed, started,
            "invalid-arguments", exception.Message)));
    return ProcessExitCodes.InvalidArguments;
}
var configurationPath = values.GetValueOrDefault("--config");
var hasRunIndex = false;
try
{
    var database = await StateDatabase.CreateOrOpenAsync(statePath, cancellation.Token);
    runIndex = givenRunIndex
        ?? await new RunIndexAllocator(values.GetValueOrDefault("--control-db")).AllocateAsync(cancellationToken: cancellation.Token);
    if (runIndex <= 0) throw new ArgumentOutOfRangeException("--run-index");
    hasRunIndex = true;
    Task<StateCollectionResult> CollectAsync(CancellationToken token) =>
        new StateCollector().RunAsync(database, savesRoot, runIndex, token);
    // Run on its own, it takes the lock every other state writer takes, so it never writes a batch
    // while the app's own check is between reading the saves and applying what it saw.
    var collected = values.ContainsKey(RunnerHoldsLock)
        ? new MutexRunResult<StateCollectionResult>(true, false, await CollectAsync(cancellation.Token))
        : await NamedMutexRunner.TryRunAsync(
            NamedMutexRunner.CreateName("StateCollection", Path.GetFullPath(statePath)), CollectAsync, cancellation.Token);
    if (!collected.Acquired)
    {
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Success("state-collector", runIndex, ProcessOutcome.Busy, started)));
        return ProcessExitCodes.Busy;
    }
    await TryTelemetryAsync(
        statePath, runIndex, "collector.completed", configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<StateCollectionResult>.Success(
            "state-collector", runIndex, ProcessOutcome.Succeeded, started, collected.Value)));
    return 0;
}
catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
{
    if (hasRunIndex)
        await TryTelemetryAsync(statePath, runIndex, "collector.cancelled", configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "state-collector", runIndex, ProcessOutcome.Cancelled, started,
            "cancelled", "The state collector was asked to stop.")));
    return ProcessExitCodes.Cancelled;
}
catch (Exception exception)
{
    if (hasRunIndex)
        await BestEffortProcessTelemetry.TryRecordAsync(
            statePath, "state-collector", runIndex, "collector.failed",
            FailureTelemetry.FromException(
                "collector-failed", exception, phase: "state-collection",
                operation: "state-collection"),
            configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "state-collector", runIndex, ProcessOutcome.Failed, started,
            "collector-failed", exception.Message)));
    return 1;
}
static async Task TryTelemetryAsync(
    string identity,
    long run,
    string name,
    string? configurationPath)
{
    await BestEffortProcessTelemetry.TryRecordAsync(
        identity, "state-collector", run, name,
        configurationPath: configurationPath);
}
