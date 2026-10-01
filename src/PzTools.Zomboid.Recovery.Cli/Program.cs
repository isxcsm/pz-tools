using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.Recovery;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

const string component = "character-recovery";
var started = DateTimeOffset.UtcNow;
var runIndex = 1L;
ProcessTelemetrySession? telemetry = null;
try
{
    runIndex = CommandLine.Int64(Required("--run-index"), "--run-index");
    var root = Required("--saves-root");
    var saveId = Required("--save-id");
    telemetry = await ProcessTelemetrySession.StartAsync(Required("--telemetry-identity"), component, runIndex);
    telemetry.RecordEvent("run.started");
    await using var heartbeat = ProcessTelemetryHeartbeat.Start(telemetry);
    var locked = await OperationMutexSet.TryRunAsync([
        new OperationMutexRequest(OperationMutexScope.SaveWrite, Path.Combine(root, saveId)),
        new OperationMutexRequest(OperationMutexScope.RepositoryAccess, Required("--repository"))],
        token => new CharacterRecoveryService().RecoverAsync(root, saveId, token));
    var outcome = locked.Acquired ? ProcessOutcome.Succeeded : ProcessOutcome.Busy;
    telemetry.RecordEvent(locked.Acquired ? "run.committed" : "run.busy",
        locked.Acquired ? System.Text.Json.JsonSerializer.Serialize(locked.Value) : null);
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<CharacterRecoveryResult>.Success(
        component, runIndex, outcome, started, locked.Value)));
    return locked.Acquired ? ProcessExitCodes.Success : ProcessExitCodes.Busy;
}
catch (Exception exception)
{
    var error = exception is IOException io && (io.HResult & 0xffff) is 32 or 33
        ? "recovery-save-busy"
        : exception is InvalidDataException && !exception.Message.StartsWith("recovery-", StringComparison.Ordinal)
            ? "recovery-unsupported-format" : exception.Message;
    telemetry?.RecordEvent("run.failed", FailureTelemetry.FromException("character-recovery-failed", exception));
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        component, runIndex, ProcessOutcome.Failed, started, "character-recovery-failed", error)));
    return ProcessExitCodes.Failure;
}
finally { if (telemetry is not null) await telemetry.DisposeAsync(); }

string Required(string key) => CommandLine.Required(args, key);
