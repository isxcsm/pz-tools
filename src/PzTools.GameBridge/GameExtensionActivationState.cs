using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.GameBridge;

/// <summary>
/// Single-owner management state. Applied feature values require a matching JVM acknowledgement.
/// Ordinary failures are scoped to a process/world and settings revision. RestartRequired remains
/// latched for the entire process, including world changes; this type never writes settings itself.
/// </summary>
public sealed class GameExtensionActivationState
{
    /// <summary>The reason given while an update of the app waits for the game's restart.</summary>
    public const string BootstrapUpdateReason = "bootstrap-update";

    private string? process, world;
    private readonly Dictionary<long, RuntimeVehicleOptions> requests = [];
    private RuntimeExtensionStatus? lastGood;
    private RuntimeExtensionStatus? failure;
    private long blockedRevision = -1;

    public bool Bind(string processSession, string worldSession)
    {
        static bool Id(string value) => value is { Length: 32 } && Guid.TryParseExact(value, "N", out _);
        if (!Id(processSession) || !Id(worldSession))
            throw new ArgumentException("A live process and world identity are required.");
        if (process == processSession && world == worldSession) return false;
        var restartRequired = process == processSession && failure?.State == RuntimeExtensionState.RestartRequired
            ? failure with { WorldSession = worldSession, AgeMilliseconds = 0 } : null;
        process = processSession; world = worldSession;
        requests.Clear(); lastGood = null; failure = restartRequired; blockedRevision = -1;
        return true;
    }

    /// <summary>Connection loss invalidates applied evidence, but must not unlock the same failed request.</summary>
    public void Disconnect() { requests.Clear(); lastGood = null; }

    public RuntimeExtensionStatus? Blocked(long revision) =>
        failure?.State == RuntimeExtensionState.RestartRequired || revision == blockedRevision ? failure : null;
    public RuntimeExtensionStatus? Failure => failure;

    /// <summary>Validate a control response before issuing any follow-up command for the current world.</summary>
    public void VerifyTarget(RuntimeExtensionStatus actual, long requestedRevision) => _ = Scope(actual, requestedRevision);

    public void RecordRequest(long revision, RuntimeVehicleOptions options)
    {
        if (process is null || revision < 0) throw new InvalidOperationException("Bind a live request first.");
        requests[revision] = options;
        // Only the most recent pending configurations can still be acknowledged. Keep memory bounded.
        if (requests.Count > 32) requests.Remove(requests.Keys.Min());
    }

    public RuntimeExtensionStatus Observe(RuntimeExtensionStatus actual, long requestedRevision)
    {
        var scoped = Scope(actual, requestedRevision);
        // A reconnect can report Disabled before consulting the poisoned host. It is not proof of recovery.
        if (failure?.State == RuntimeExtensionState.RestartRequired) return failure;
        if (IsDefinitiveFailure(actual, requestRejected: false)) return scoped;
        if (actual.State == RuntimeExtensionState.Active && actual.Reason is null
            && requests.TryGetValue(actual.AppliedRevision, out var applied))
            lastGood = scoped with { ControlReady = true, AppliedVehicleOptions = applied };
        RuntimeVehicleOptions? options = null;
        if (actual.State is RuntimeExtensionState.Active or RuntimeExtensionState.Pending
            && lastGood is { } good && actual.Generation == good.Generation && actual.AppliedRevision == good.AppliedRevision)
            options = good.AppliedVehicleOptions;
        if (actual.State == RuntimeExtensionState.Disabled) lastGood = null;
        return scoped with { ControlReady = true, AppliedVehicleOptions = options };
    }

    public static bool IsDefinitiveFailure(RuntimeExtensionStatus actual, bool requestRejected) => requestRejected
        || actual.State is RuntimeExtensionState.Unsupported or RuntimeExtensionState.FaultedPassThrough or RuntimeExtensionState.RestartRequired;

    /// <summary>
    /// Call only after revoking the control lease. The current-session check runs immediately before
    /// the caller's compare-and-swap write. Null means another settings revision won and is never overwritten.
    /// The returned failure remains attributed to the original request, even when the OFF write creates a new revision.
    /// </summary>
    public bool FailClosed(RuntimeExtensionStatus actual, long requestedRevision,
        Func<bool> isCurrentSession, Func<long, long?> disableAtRevision)
    {
        var scoped = Scope(actual, requestedRevision);
        if (!isCurrentSession()) return false;
        // A later, less severe failure cannot downgrade a process-scoped restart requirement.
        if (failure?.State == RuntimeExtensionState.RestartRequired) return true;
        Disconnect();
        failure = scoped with
        {
            State = actual.State is RuntimeExtensionState.Unsupported or RuntimeExtensionState.FaultedPassThrough or RuntimeExtensionState.RestartRequired
                ? actual.State : RuntimeExtensionState.Unsupported,
            ControlReady = false, AppliedVehicleOptions = null,
        };
        blockedRevision = requestedRevision;
        // An update of the app that waits for the game's restart is not a failure of the extension: the latch keeps it
        // off in this game, and it comes back with the next one. The player's preference is left as it is. A restart
        // forced by a failure turns the extension off, as every other failure does.
        if (failure is { State: RuntimeExtensionState.RestartRequired, Reason: BootstrapUpdateReason }) return true;
        var disabledRevision = disableAtRevision(requestedRevision);
        if (disabledRevision is { } revision) blockedRevision = revision;
        return true;
    }

    private RuntimeExtensionStatus Scope(RuntimeExtensionStatus actual, long requestedRevision)
    {
        actual.Validate();
        if (process is null || world is null || requestedRevision < 0
            || actual.ProcessSession != process
            || actual.WorldSession is not null && actual.WorldSession != world && actual.State != RuntimeExtensionState.RestartRequired)
            throw new ExtensionSessionMismatchException();
        return actual with { WorldSession = world, RequestedRevision = requestedRevision, AgeMilliseconds = 0,
            ControlReady = false, AppliedVehicleOptions = null };
    }
}

/// <summary>A stale/foreign response must invalidate evidence, never roll back the current world's preferences.</summary>
public sealed class ExtensionSessionMismatchException()
    : IOException("Extension response belongs to another process or world.");
