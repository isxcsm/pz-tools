using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.SaveBridge;

/// <summary>
/// Tracks accepted requests separately from applied state and rejected desired revisions.
/// One owner calls this sequentially; a heartbeat never erases the latest rejected update reason.
/// </summary>
public sealed class GameExtensionReconciler(RuntimeExtensionStatus initial)
{
    private RuntimeExtensionStatus actual = initial;
    private string? attemptedProcess, attemptedWorld;
    private long attemptedRevision = -1;
    private string? rejection;

    /// <summary>The latest requested revision was rejected, rather than accepted at a pending safe boundary.</summary>
    public bool RequestRejected => rejection is not null;

    public async Task<RuntimeExtensionStatus> ReconcileAsync(IGameExtensionSession session,
        string processSession, string worldSession, long revision, string moduleId, bool forceVersion,
        Func<IReadOnlyDictionary<string, string>> configuration, CancellationToken token)
    {
        if (attemptedProcess == processSession && attemptedWorld == worldSession && attemptedRevision == revision)
        {
            actual = await session.PingAsync(token);
            return Publish(processSession, worldSession);
        }

        // A rejection is scoped to the desired revision, not a permanent module fault.
        attemptedProcess = processSession; attemptedWorld = worldSession; attemptedRevision = revision;
        rejection = null;
        IReadOnlyDictionary<string, string> tuning;
        try { tuning = configuration(); }
        catch (Exception failure) when (failure is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException
            or FormatException or OverflowException)
        {
            rejection = "configuration-rejected";
            actual = await session.PingAsync(token);
            return Publish(processSession, worldSession);
        }

        var response = await session.ApplyAsync(processSession, worldSession, actual.AppliedRevision, revision,
            moduleId, forceVersion, tuning, token);
        if (response.Reason == "revision-conflict")
        {
            // An accepted pending request may have become applied since our previous heartbeat.
            actual = await session.StatusAsync(token);
            if (AppliedToTarget(actual, processSession, worldSession, revision)) return Publish(processSession, worldSession);
            response = await session.ApplyAsync(processSession, worldSession, actual.AppliedRevision, revision,
                moduleId, forceVersion, tuning, token);
        }
        actual = response;
        bool accepted = response.State == RuntimeExtensionState.Pending && response.Reason == "safe-boundary"
            && response.ProcessSession == processSession && response.WorldSession == worldSession && response.Generation is not null;
        if (!accepted && !AppliedToTarget(response, processSession, worldSession, revision))
            rejection = response.Reason ?? "update-not-accepted";
        return Publish(processSession, worldSession);
    }

    private RuntimeExtensionStatus Publish(string processSession, string worldSession)
    {
        if (actual.State == RuntimeExtensionState.Active
            && (actual.ProcessSession != processSession || actual.WorldSession != worldSession))
            throw new ExtensionSessionMismatchException();
        if (rejection is null || actual.State is RuntimeExtensionState.FaultedPassThrough or RuntimeExtensionState.RestartRequired)
            return actual;
        // Retain actual applied revision/identity. Do not label an old good generation as the requested new configuration.
        return actual with { State = actual.State == RuntimeExtensionState.Disabled ? RuntimeExtensionState.Unsupported : actual.State,
            Reason = rejection };
    }

    private static bool AppliedToTarget(RuntimeExtensionStatus value, string processSession, string worldSession, long revision) =>
        value.State == RuntimeExtensionState.Active && value.ProcessSession == processSession
        && value.WorldSession == worldSession && value.AppliedRevision == revision && value.Reason is null;
}
