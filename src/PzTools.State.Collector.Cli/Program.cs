using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.State;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

var started = DateTimeOffset.UtcNow;
var runIndex = 1L;
string? statePath = null;
string? configurationPath = null;
var hasRunIndex = false;
try
{
    var values = CommandLine.Parse(args, ["--state-db", "--saves-root", "--run-index", "--config", "--control-db"]);
    statePath = CommandLine.Required(values, "--state-db");
    configurationPath = values.GetValueOrDefault("--config");
    var database = await StateDatabase.CreateOrOpenAsync(statePath);
    runIndex = values.TryGetValue("--run-index", out var run)
        ? CommandLine.Int64(run, "--run-index")
        : await new RunIndexAllocator(values.GetValueOrDefault("--control-db")).AllocateAsync();
    if (runIndex <= 0) throw new ArgumentOutOfRangeException("--run-index");
    hasRunIndex = true;
    var result = await new StateCollector().RunAsync(
        database, CommandLine.Required(values, "--saves-root"), runIndex);
    await TryTelemetryAsync(
        statePath, runIndex, "collector.completed", configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<StateCollectionResult>.Success(
            "state-collector", runIndex, ProcessOutcome.Succeeded, started, result)));
    return 0;
}
catch (Exception exception)
{
    if (hasRunIndex && statePath is not null)
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
