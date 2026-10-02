using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.App.Core;

/// <summary>
/// Which game-dependent features cannot work right now. Each feature is judged by what it needs,
/// so one unreadable value does not switch off the rest.
/// </summary>
/// <param name="RestartRequired">The link is unavailable because the game still runs an older bridge; a
/// game restart is known to bring it back. Any other unavailable link may not come back with a restart.</param>
/// <param name="Cause">What stops the link when it is known and the player can change it: the game run as
/// administrator (<see cref="RuntimeObservation.ElevationReason"/>) or with connecting turned off
/// (<see cref="RuntimeObservation.AttachDisabledReason"/>).</param>
public sealed record GameLinkView(bool LinkUnavailable = false, bool SleepUnavailable = false, bool RestartRequired = false,
    string? Cause = null)
{
    public static GameLinkView Available { get; } = new();
}

/// <summary>
/// Turns the live observation into lasting conditions. A value is briefly unreadable while the game
/// starts or loads; only one that stays unreadable is reported. Display only: scheduling decides for itself.
/// </summary>
public sealed class GameLinkMonitor(TimeProvider? timeProvider = null, TimeSpan? linkGrace = null,
    TimeSpan? valueGrace = null, Func<bool>? gameRunning = null)
{
    private readonly TimeProvider time = timeProvider ?? TimeProvider.System;
    private readonly TimeSpan linkGrace = linkGrace ?? PzTools.Scheduling.RuntimeScheduleController.DefaultLinkGrace;
    private readonly TimeSpan valueGrace = valueGrace ?? TimeSpan.FromSeconds(30);
    private long? linkSince, sleepSince, lastProcessCheck;
    private bool running, restartRequired;
    private string? cause;

    public GameLinkView Update(RuntimeObservation observation)
    {
        // Without a game there is nothing to connect to, whatever the feed says.
        bool unusable = observation.IsLinkUnusable && IsGameRunning();
        linkSince = unusable ? linkSince ?? time.GetTimestamp() : null;
        // Each retry reports "connecting" before it fails again: keep the reason for the whole outage.
        restartRequired = unusable && (restartRequired || observation.Reason == RuntimeObservation.RestartRequiredReason);
        cause = !unusable ? null : observation.Reason is RuntimeObservation.ElevationReason or RuntimeObservation.AttachDisabledReason
            ? observation.Reason : cause;
        bool sleepUnknown = observation is { IsFresh: true, Snapshot: { IsWorldReady: true, Sleep: RuntimeSleep.Unknown } };
        sleepSince = sleepUnknown ? sleepSince ?? time.GetTimestamp() : null;
        bool linkUnavailable = linkSince is { } link && time.GetElapsedTime(link) >= linkGrace;
        return new(linkUnavailable, sleepSince is { } sleep && time.GetElapsedTime(sleep) >= valueGrace,
            linkUnavailable && restartRequired, linkUnavailable ? cause : null);
    }

    private bool IsGameRunning()
    {
        if (gameRunning is not null) return gameRunning();
        // Listing processes is not free; once a second is plenty for a condition that takes a minute.
        if (lastProcessCheck is { } last && time.GetElapsedTime(last) < TimeSpan.FromSeconds(1)) return running;
        lastProcessCheck = time.GetTimestamp();
        running = GameProcesses.Count() > 0;
        return running;
    }
}
