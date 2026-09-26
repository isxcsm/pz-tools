using PzTools.Process.Contracts.GameRuntime;
using PzTools.Projections;

namespace PzTools.App.Core;

public sealed record CountdownPresentation(string MessageKey, long? RemainingSeconds = null, bool Suspended = false);

/// <summary>Display policy only. Never starts, postpones or consumes a backup.</summary>
public static class ScheduleCountdownPresentation
{
    public static CountdownPresentation Resolve(ScheduleStatusView? schedule, DateTimeOffset now, bool unavailable = false)
    {
        if (unavailable) return new("SchedulerStatusUnavailable");
        if (schedule is null) return new("NextBackupWaitingDynamic");
        if ((schedule.Hold & ScheduleHold.GameOffline) != 0) return new("RuntimeBackupOffline");
        if (!schedule.AutomaticEnabled) return new("AutomaticBackupOff");
        if (schedule.PauseAware)
        {
            if (schedule.CompletionUncertain) return new("RuntimeBackupCompletionUnknown");
            long? seconds = schedule.RemainingMilliseconds is { } ms ? (long)Math.Ceiling(Math.Max(0, ms) / 1000d) : null;
            if ((schedule.Hold & ScheduleHold.Ambiguous) != 0) return new("RuntimeBackupAmbiguous", seconds, true);
            if ((schedule.Hold & (ScheduleHold.Unknown | ScheduleHold.Unsupported)) != 0) return new("RuntimeBackupWaiting", seconds, true);
            if ((schedule.Hold & ScheduleHold.NoWorld) != 0) return new("NextBackupWaitingDynamic");
            if ((schedule.Hold & ScheduleHold.Sleeping) != 0) return new("RuntimeBackupSleeping", seconds, true);
            if ((schedule.Hold & ScheduleHold.GamePaused) != 0) return new("RuntimeBackupPaused", seconds, true);
            return new(seconds == 0 ? WaitingKey(schedule) : "ProjectorArea.Schedule", seconds);
        }
        if (schedule.NextDueUtc is not { } due) return new("NextBackupWaitingDynamic");
        return due <= now ? new(WaitingKey(schedule))
            : new("ProjectorArea.Schedule", (long)Math.Ceiling((due - now).TotalSeconds));
    }
    private static string WaitingKey(ScheduleStatusView s) => s.PeriodicBackupInProgress
        ? "NextBackupWaitingForCurrent" : "NextBackupWaitingToStart";
}
