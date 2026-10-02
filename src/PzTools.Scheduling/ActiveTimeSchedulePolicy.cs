using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Scheduling;

public sealed record ActiveTimeScheduleState(long Generation, long IntervalMilliseconds, long RemainingMilliseconds,
    string? WorldSession = null, string? ClockIdentity = null, long LastActiveMilliseconds = 0,
    bool Anchored = false, long EligibilityEpoch = -1, long Slot = 0, string? AttemptId = null,
    ScheduleHold Hold = ScheduleHold.Unknown, bool CompletionUncertain = false,
    // Set while the game cannot be observed: backups then follow the wall clock, without a game save.
    DateTimeOffset? FallbackDueUtc = null);

/// <summary>Pure time/policy reducer. No UTC arithmetic, database, JVM calls or UI dependencies.</summary>
public static class ActiveTimeSchedulePolicy
{
    public static ActiveTimeScheduleState Advance(ActiveTimeScheduleState state, RuntimeObservation observation,
        bool enabled, long generation, long intervalMilliseconds)
    {
        if (intervalMilliseconds <= 0) throw new ArgumentOutOfRangeException(nameof(intervalMilliseconds));
        if (state.Generation != generation || state.IntervalMilliseconds != intervalMilliseconds)
            state = new(generation, intervalMilliseconds, intervalMilliseconds);
        var hold = enabled ? ScheduleHold.None : ScheduleHold.Disabled;
        if (observation.Quality == RuntimeQuality.Offline) hold |= ScheduleHold.GameOffline | ScheduleHold.NoWorld;
        else if (observation.Quality == RuntimeQuality.Ambiguous) hold |= ScheduleHold.Ambiguous;
        else if (observation.Quality == RuntimeQuality.Unsupported) hold |= ScheduleHold.Unsupported;
        else if (!observation.IsFresh) hold |= ScheduleHold.Unknown;
        var sample = observation.Snapshot;
        if (!observation.IsFresh || sample is null)
            return state with { Anchored = false, Hold = hold };
        if (!sample.IsWorldReady)
        {
            bool ended = sample.Phase is WorldPhase.Menu or WorldPhase.Unloading;
            return state with { Anchored = false,
                Hold = hold | (sample.Mode != RuntimeMode.LocalSinglePlayer ? ScheduleHold.Unsupported : ended ? ScheduleHold.NoWorld : ScheduleHold.Unknown),
                WorldSession = ended ? null : state.WorldSession,
                RemainingMilliseconds = ended ? intervalMilliseconds : state.RemainingMilliseconds, AttemptId = null };
        }
        if (sample.Pause == GamePause.Paused) hold |= ScheduleHold.GamePaused;
        else if (sample.Pause != GamePause.Running) hold |= ScheduleHold.Unknown;
        // Sleep that cannot be read only loses the sleep pause; it does not stop backups.
        if (sample.Sleep == RuntimeSleep.Asleep) hold |= ScheduleHold.Sleeping;
        // Backups of a dead character would only push the living ones out of the retained history.
        bool dead = sample.CharacterLife == RuntimeCharacterLife.Dead;
        if (dead) hold |= ScheduleHold.CharacterDead;
        if (state.WorldSession is not null && state.WorldSession != sample.WorldSession)
            state = new(generation, intervalMilliseconds, intervalMilliseconds);
        string identity = $"{observation.StreamEpoch}/{sample.ProcessSession}/{sample.ObserverEpoch}/{sample.WorldSession}/{sample.ClockEpoch}";
        var remaining = state.RemainingMilliseconds;
        if (state.Anchored && state.ClockIdentity == identity && sample.ActiveMilliseconds < state.LastActiveMilliseconds)
            return state with { Anchored = false, Hold = hold | ScheduleHold.Unknown, AttemptId = null };
        if (state.Anchored && state.ClockIdentity == identity && enabled
            && sample.Pause != GamePause.Unknown
            && sample.ActiveMilliseconds >= state.LastActiveMilliseconds)
            remaining -= sample.ActiveMilliseconds - state.LastActiveMilliseconds;
        // A new character starts a full interval; time spent dead is not counted.
        if (dead) remaining = intervalMilliseconds;
        // An unknown outcome sits out one full interval of play, then backups resume by themselves.
        bool uncertain = state.CompletionUncertain && remaining > 0 && !dead;
        if (uncertain) hold |= ScheduleHold.Unknown;
        return state with { RemainingMilliseconds = remaining, CompletionUncertain = uncertain, WorldSession = sample.WorldSession,
            ClockIdentity = identity, LastActiveMilliseconds = sample.ActiveMilliseconds,
            Anchored = enabled && !dead && sample.Pause != GamePause.Unknown,
            EligibilityEpoch = sample.EligibilityEpoch, Hold = hold,
            AttemptId = state.ClockIdentity != identity || state.EligibilityEpoch != sample.EligibilityEpoch || hold != ScheduleHold.None
                ? null : state.AttemptId };
    }

    public static ActiveTimeScheduleState Complete(ActiveTimeScheduleState state, ScheduleDisposition disposition)
    {
        // Whether the game saved is unknown, so do not ask it again right away. A save still in
        // flight has long finished after one interval, which is when the next attempt becomes due.
        if (disposition == ScheduleDisposition.CompletionUnknown)
            return state with { CompletionUncertain = true, RemainingMilliseconds = state.IntervalMilliseconds,
                Slot = state.Slot + 1, Hold = state.Hold | ScheduleHold.Unknown, AttemptId = null };
        if (disposition == ScheduleDisposition.Preserve)
            return state with { RemainingMilliseconds = Math.Max(0, state.RemainingMilliseconds), AttemptId = null };
        // Keep cadence; missed active-time slots do not produce catch-up backup bursts.
        long remaining = state.RemainingMilliseconds;
        if (remaining <= 0) remaining = state.IntervalMilliseconds - ((-remaining) % state.IntervalMilliseconds);
        else remaining = state.IntervalMilliseconds;
        return state with { RemainingMilliseconds = remaining, Slot = state.Slot + 1, AttemptId = null };
    }
}