using PzTools.Process.Contracts.GameRuntime;
using PzTools.Scheduling;

namespace PzTools.Projections;

/// <summary>Read model only. Calculating a visible countdown cannot reserve or execute a backup.</summary>
public static class RuntimeScheduleProjection
{
    public static ScheduleStatusView Build(BackupSchedulerState control, RuntimeScheduleStorage storage,
        RuntimeObservation observation)
    {
        // Presentation can immediately show a confirmed process/world state, even while
        // its scheduler transition is committing. This does not grant execution permission.
        bool offline = observation.Quality == RuntimeQuality.Offline;
        var fallbackDue = control.AutomaticEnabled && observation.IsLinkUnusable ? storage.Checkpoint?.FallbackDueUtc : null;
        var gamePhase = ObservedGamePhase(observation);
        if (storage.Facts is null || storage.Facts.AuthorityEpoch != observation.AuthorityEpoch
            || storage.Facts.StateRevision < observation.StateRevision || storage.Facts.SemanticKey != observation.SemanticKey)
            observation = RuntimeObservation.Unknown("state-transition-pending");
        var initial = storage.Checkpoint ?? new ActiveTimeScheduleState(control.Generation,
            (long)control.Interval.TotalMilliseconds, (long)control.Interval.TotalMilliseconds);
        var state = ActiveTimeSchedulePolicy.Advance(initial, observation, control.AutomaticEnabled,
            control.Generation, (long)control.Interval.TotalMilliseconds);
        var hold = control.CurrentTarget is null ? state.Hold | ScheduleHold.NoWorld : state.Hold;
        if (offline) hold |= ScheduleHold.GameOffline | ScheduleHold.NoWorld;
        if (fallbackDue is { } due)
            return new ScheduleStatusView(control.SchedulerRevision, control.Mode, control.CurrentTarget, due,
                control.LastRunIndex, control.LastOutcome, control.AutomaticEnabled, control.PendingRuns,
                PauseAware: true, Hold: hold, GamePhase: gamePhase, Fallback: true);
        return new ScheduleStatusView(control.SchedulerRevision, control.Mode, control.CurrentTarget, null,
            control.LastRunIndex, control.LastOutcome, control.AutomaticEnabled, control.PendingRuns,
            PauseAware: true, RemainingMilliseconds: Math.Max(0, state.RemainingMilliseconds),
            Hold: hold, CompletionUncertain: state.CompletionUncertain, GamePhase: gamePhase);
    }

    internal static WorldPhase ObservedGamePhase(RuntimeObservation observation) =>
        observation.IsFresh ? observation.Snapshot!.Phase
        // Busy while leaving a world (saving it, unloading it, reloading the mods) is still leaving it. Busy anywhere
        // else outside a world (the menu, no phase): the game is loading something, and backups say they wait for it.
        : observation.Reason == RuntimeObservation.GameBusyReason
            ? observation.Snapshot?.Phase == WorldPhase.Unloading ? WorldPhase.Unloading : WorldPhase.Loading
            : WorldPhase.Unknown;
}
