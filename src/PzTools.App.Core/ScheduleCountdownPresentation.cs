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
        // The game cannot be read, so backups follow the clock and take the files as they are.
        if (schedule.Fallback && schedule.NextDueUtc is { } fallbackDue)
            return fallbackDue <= now ? new(WaitingKey(schedule))
                : new("RuntimeBackupFallback", (long)Math.Ceiling((fallbackDue - now).TotalSeconds));
        // The skipped interval keeps counting down; backups resume when it ends.
        if (schedule.PauseAware && schedule.CompletionUncertain)
            return new("RuntimeBackupCompletionUnknown", schedule.RemainingMilliseconds is { } left
                ? (long)Math.Ceiling(Math.Max(0, left) / 1000d) : null);
        if (schedule.GamePhase == WorldPhase.Menu) return new("RuntimeBackupMainMenu");
        if (schedule.GamePhase == WorldPhase.Loading) return new("RuntimeBackupLoading");
        if ((schedule.Hold & ScheduleHold.CharacterDead) != 0) return new("RuntimeBackupCharacterDead");
        if (schedule.PauseAware)
        {
            long? seconds = schedule.RemainingMilliseconds is { } ms ? (long)Math.Ceiling(Math.Max(0, ms) / 1000d) : null;
            if ((schedule.Hold & ScheduleHold.Ambiguous) != 0) return new("RuntimeBackupAmbiguous", seconds, true);
            // While the state is unknown a remaining time says nothing; show the message alone.
            if ((schedule.Hold & (ScheduleHold.Unknown | ScheduleHold.Unsupported)) != 0) return new(CheckingKey);
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
    internal const string CheckingKey = "RuntimeBackupWaiting";
}

/// <summary>
/// "Checking game status" normally lasts a moment (app start, the game connecting). Keep what
/// was shown before and say so only when the state stays unknown. Display only, like the above.
/// </summary>
public sealed class CountdownDisplayStabilizer(TimeSpan? patience = null)
{
    private readonly TimeSpan patience = patience ?? TimeSpan.FromSeconds(3);
    private CountdownPresentation? settled;
    private DateTimeOffset? checkingSince;

    public CountdownPresentation Apply(CountdownPresentation display, DateTimeOffset now)
    {
        if (display.MessageKey != ScheduleCountdownPresentation.CheckingKey)
        {
            checkingSince = null;
            return settled = display;
        }
        checkingSince ??= now;
        return now - checkingSince < patience ? settled ?? new("NextBackupWaitingDynamic") : display;
    }
}
