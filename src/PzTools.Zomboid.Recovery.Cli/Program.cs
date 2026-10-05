using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.Recovery;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

const string component = "character-recovery";
var started = DateTimeOffset.UtcNow;
var runIndex = 1L;
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cancellation.Cancel();
};
// The app asks a worker it cancels to stop. The edit honours that only before its commit point, so a stop never
// leaves half a save; without listening, the worker was ended outright and wrote nothing about why.
using var stopRequest = ProcessStopSignal.Listen(cancellation);
string root, saveId, repository, telemetryIdentity;
long? playerId;
string? remains;
try
{
    runIndex = CommandLine.Int64(Required("--run-index"), "--run-index");
    root = Required("--saves-root");
    saveId = Required("--save-id");
    repository = Required("--repository");
    telemetryIdentity = Required("--telemetry-identity");
    // Only when the save holds several characters: the one the user chose.
    playerId = CommandLine.Optional(args, "--player-id") is { } player
        ? CommandLine.Int64(player, "--player-id") : null;
    // A dead character's remains as the user chose them in the preview, or "none" to revive without them.
    remains = CommandLine.Optional(args, "--remains");
}
catch (ArgumentException exception)
{
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        component, runIndex, ProcessOutcome.Failed, started, "invalid-arguments", exception.Message)));
    return ProcessExitCodes.InvalidArguments;
}

ProcessTelemetrySession? telemetry = null;
try
{
    telemetry = await ProcessTelemetrySession.StartAsync(telemetryIdentity, component, runIndex);
    telemetry.RecordEvent("run.started");
    await using var heartbeat = ProcessTelemetryHeartbeat.Start(telemetry);
    var locked = await OperationMutexSet.TryRunAsync([
        new OperationMutexRequest(OperationMutexScope.SaveWrite, Path.Combine(root, saveId)),
        new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repository)],
        token => new CharacterRecoveryService().RecoverAsync(root, saveId, playerId, remains, token), cancellation.Token);
    var outcome = locked.Acquired ? ProcessOutcome.Succeeded : ProcessOutcome.Busy;
    telemetry.RecordEvent(locked.Acquired ? "run.committed" : "run.busy",
        locked.Acquired ? System.Text.Json.JsonSerializer.Serialize(locked.Value) : null);
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<CharacterRecoveryResult>.Success(
        component, runIndex, outcome, started, locked.Value)));
    return locked.Acquired ? ProcessExitCodes.Success : ProcessExitCodes.Busy;
}
catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
{
    telemetry?.RecordEvent("run.cancelled");
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        component, runIndex, ProcessOutcome.Cancelled, started, "cancelled", "Character recovery was cancelled.")));
    return ProcessExitCodes.Cancelled;
}
catch (Exception exception)
{
    telemetry?.RecordEvent("run.failed", FailureTelemetry.FromException("character-recovery-failed", exception));
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        component, runIndex, ProcessOutcome.Failed, started, "character-recovery-failed", ErrorCode(exception))));
    return ProcessExitCodes.Failure;
}
finally { if (telemetry is not null) await telemetry.DisposeAsync(); }

string Required(string key) => CommandLine.Required(args, key);

// The message is the code the app explains (UserFacingErrorCatalog.FromProcessError). The recovery's own codes and
// the save-edit journal's pass through as they are: a conflicting or unreadable journal is an unfinished earlier
// edit, not a save in a format that cannot be healed. Any other unreadable data is the format the recovery refuses.
static string ErrorCode(Exception exception) => exception switch
{
    IOException io when (io.HResult & 0xffff) is 32 or 33 => "recovery-save-busy",
    InvalidDataException when exception.Message.StartsWith("recovery-", StringComparison.Ordinal)
        || exception.Message.StartsWith("save-edit-", StringComparison.Ordinal) => exception.Message,
    InvalidDataException => "recovery-unsupported-format",
    _ => exception.Message,
};
