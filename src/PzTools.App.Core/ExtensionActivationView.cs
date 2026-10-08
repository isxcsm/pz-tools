using System.Diagnostics.CodeAnalysis;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.App.Core;

/// <summary>
/// Preference controls display the committed request, not a runtime acknowledgement. Runtime
/// pending/failure/applied values are separate hints and diagnostics; they do not lock settings.
/// A card without the continuous capability, a current process restart requirement and a running
/// game outside the supported version range still fail closed.
/// </summary>
public sealed record ExtensionActivationView(bool IsOn, bool CanToggle, bool IsBusy, string? FailureReason = null)
{
    private const long MaximumRuntimeStatusAgeMilliseconds = 3000;

    /// <summary>
    /// The game runs the bootstrap from before an update of the app, and the extension waits for its restart
    /// (GameExtensionActivationState.BootstrapUpdateReason). Nothing failed: restarting the game is the whole answer.
    /// </summary>
    public bool AwaitsGameRestart => FailureReason == "bootstrap-update";
    private static bool IsFresh([NotNullWhen(true)] RuntimeExtensionStatus? status) =>
        status is { AgeMilliseconds: >= 0 and <= MaximumRuntimeStatusAgeMilliseconds };

    /// <summary>
    /// Readiness is session evidence even when no revision has been applied. Keep only current,
    /// fresh evidence; a restart requirement is process-scoped and follows that process's world.
    /// </summary>
    /// <param name="moduleId">The module whose status is wanted; null for the connection as a whole.</param>
    public static RuntimeExtensionStatus? SelectCurrentStatus(RuntimeObservation observation, string? moduleId = null)
    {
        var status = moduleId is null ? observation.Extension : observation.ExtensionFor(moduleId);
        if (!IsFresh(status)) return null;
        if (status.ProcessSession.Length != 0 || status.WorldSession is not null)
        {
            var snapshot = observation.Snapshot;
            if (!observation.IsExtensionFresh || snapshot is null || snapshot.ProcessSession != status.ProcessSession)
                return new(RuntimeExtensionState.Pending, "waiting-for-local-world");
            if (status.State == RuntimeExtensionState.RestartRequired)
                return status with { WorldSession = snapshot.WorldSession, AgeMilliseconds = 0,
                    ControlReady = false, AppliedConfiguration = null };
            if (!snapshot.IsExtensionWorldReady || status.WorldSession is not null && snapshot.WorldSession != status.WorldSession)
                return new(RuntimeExtensionState.Pending, "waiting-for-local-world");
        }
        // Age is an admission check, not a semantic UI change on every heartbeat.
        return status with { AgeMilliseconds = 0 };
    }

    public static ExtensionActivationView Project(ExtensionCardView card, bool runtimeWorldReady, RuntimeExtensionStatus? runtime)
    {
        // The app runs continuous modules only (GameExtensionService gives no other cards).
        if (!card.SupportsActivation) return new(false, false, false, FailureReason: "unsupported-capability");

        var fresh = IsFresh(runtime);
        var failed = fresh && runtime!.State is RuntimeExtensionState.Unsupported
            or RuntimeExtensionState.FaultedPassThrough or RuntimeExtensionState.RestartRequired;
        // The game runs a revision this app requested, with the configuration it sent for it: the module is applied,
        // whatever the module is. Turning it off is then in progress until the game reports it gone.
        var applied = runtimeWorldReady && fresh
            && runtime!.State is RuntimeExtensionState.Active or RuntimeExtensionState.Pending
            && runtime.AppliedRevision >= 0 && runtime.ProcessSession.Length != 0
            && runtime.WorldSession is not null && runtime.Generation is not null
            && runtime.AppliedConfiguration is not null;
        var busy = runtimeWorldReady && fresh && !failed
            && (runtime!.State == RuntimeExtensionState.Pending
                || card.Enabled && runtime.RequestedRevision != card.SettingsRevision
                || !card.Enabled && applied);
        var restartRequired = fresh && runtime!.State == RuntimeExtensionState.RestartRequired
            && runtime.ProcessSession.Length != 0;
        // Neither a restart requirement nor a version outside the range may prevent turning a saved ON request OFF.
        return new(card.Enabled, card.Enabled || !restartRequired && !card.OutsideKnownSupportedRange, busy,
            failed ? runtime!.Reason : null);
    }
}
