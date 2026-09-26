using PzTools.Process.Contracts.GameRuntime;
using PzTools.Scheduling;

namespace PzTools.Projections;

/// <summary>Read model only. Calculating a visible countdown cannot reserve or execute a backup.</summary>
public static class RuntimeScheduleProjection
{
    public static ScheduleStatusView Build(BackupSchedulerState control, RuntimeScheduleStorage storage,
        RuntimeObservation observation)
    {
        if (storage.Facts is null || storage.Facts.AuthorityEpoch != observation.AuthorityEpoch
            || storage.Facts.StateRevision < observation.StateRevision || storage.Facts.SemanticKey != observation.SemanticKey)
            observation = RuntimeObservation.Unknown("state-transition-pending");
        var initial = storage.Checkpoint ?? new ActiveTimeScheduleState(control.Generation,
            (long)control.Interval.TotalMilliseconds, (long)control.Interval.TotalMilliseconds);
        var state = ActiveTimeSchedulePolicy.Advance(initial, observation, control.AutomaticEnabled,
            control.Generation, (long)control.Interval.TotalMilliseconds);
        var hold = control.CurrentTarget is null ? state.Hold | ScheduleHold.NoWorld : state.Hold;
        return new ScheduleStatusView(control.SchedulerRevision, control.Mode, control.CurrentTarget, null,
            control.LastRunIndex, control.LastOutcome, control.AutomaticEnabled, control.PendingRuns,
            PauseAware: true, RemainingMilliseconds: Math.Max(0, state.RemainingMilliseconds),
            Hold: hold, CompletionUncertain: state.CompletionUncertain);
    }
}