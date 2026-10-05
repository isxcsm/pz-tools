using System.Diagnostics.CodeAnalysis;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.App.Core;

/// <summary>
/// Preference controls display the committed request, not a runtime acknowledgement. Runtime
/// pending/failure/applied values are separate hints and diagnostics; they do not lock settings.
/// Unsupported capabilities, a current process restart requirement and a running game outside the
/// supported version range still fail closed.
/// </summary>
public sealed record ExtensionActivationView(bool IsOn, bool CanToggle, bool IsBusy, bool CanEditOptions,
    string? FailureReason = null, VehicleDrivetrainPreference? AppliedVehicleOptions = null, bool IsPerSave = false)
{
    private const long MaximumRuntimeStatusAgeMilliseconds = 3000;
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
            if (!observation.IsFresh || snapshot is null || snapshot.ProcessSession != status.ProcessSession)
                return new(RuntimeExtensionState.Pending, "waiting-for-local-world");
            if (status.State == RuntimeExtensionState.RestartRequired)
                return status with { WorldSession = snapshot.WorldSession, AgeMilliseconds = 0,
                    ControlReady = false, AppliedVehicleOptions = null };
            if (!snapshot.IsWorldReady || status.WorldSession is not null && snapshot.WorldSession != status.WorldSession)
                return new(RuntimeExtensionState.Pending, "waiting-for-local-world");
        }
        // Age is an admission check, not a semantic UI change on every heartbeat.
        return status with { AgeMilliseconds = 0 };
    }

    public static ExtensionActivationView Project(ExtensionCardView card, bool gameSavingEnabled,
        bool runtimeWorldReady, RuntimeExtensionStatus? runtime)
    {
        var kind = card.Definition.ActivationKind;
        if (kind == ExtensionActivationKind.Unsupported)
            return new(false, false, false, false, FailureReason: "unsupported-capability");
        if (kind == ExtensionActivationKind.PerSave)
        {
            // This is deliberately not a claim that a save adapter is initialized or executing.
            // Save policy and compatibility are checked when a save is requested, not when editing preferences.
            return new(card.Enabled, true, false, true, IsPerSave: true);
        }

        var fresh = IsFresh(runtime);
        var failed = fresh && runtime!.State is RuntimeExtensionState.Unsupported
            or RuntimeExtensionState.FaultedPassThrough or RuntimeExtensionState.RestartRequired;
        var applied = runtimeWorldReady && fresh
            && runtime!.State is RuntimeExtensionState.Active or RuntimeExtensionState.Pending
            && runtime.AppliedRevision >= 0 && runtime.ProcessSession.Length != 0
            && runtime.WorldSession is not null && runtime.Generation is not null
            && runtime.AppliedVehicleOptions is not null;
        var busy = runtimeWorldReady && fresh && !failed
            && (runtime!.State == RuntimeExtensionState.Pending
                || card.Enabled && runtime.RequestedRevision != card.SettingsRevision
                || !card.Enabled && applied);
        var restartRequired = fresh && runtime!.State == RuntimeExtensionState.RestartRequired
            && runtime.ProcessSession.Length != 0;
        var options = applied ? runtime!.AppliedVehicleOptions : null;
        // Neither a restart requirement nor a version outside the range may prevent turning a saved ON request OFF.
        return new(card.Enabled, card.Enabled || !restartRequired && !card.OutsideKnownSupportedRange, busy, true,
            failed ? runtime!.Reason : null,
            options is null ? null : new(options.TorqueEnabled, options.ReverseEnabled, options.SteeringEnabled, options.AreaLightEnabled));
    }
}
