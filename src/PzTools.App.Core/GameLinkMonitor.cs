using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.App.Core;

/// <summary>
/// Which game-dependent features cannot work right now. Each feature is judged by what it needs,
/// so one unreadable value does not switch off the rest.
/// </summary>
public sealed record GameLinkView(bool LinkUnavailable = false, bool SleepUnavailable = false)
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
    private bool running;

    public GameLinkView Update(RuntimeObservation observation)
    {
        // Without a game there is nothing to connect to, whatever the feed says.
        bool unusable = observation.IsLinkUnusable && IsGameRunning();
        linkSince = unusable ? linkSince ?? time.GetTimestamp() : null;
        bool sleepUnknown = observation is { IsFresh: true, Snapshot: { IsWorldReady: true, Sleep: RuntimeSleep.Unknown } };
        sleepSince = sleepUnknown ? sleepSince ?? time.GetTimestamp() : null;
        return new(linkSince is { } link && time.GetElapsedTime(link) >= linkGrace,
            sleepSince is { } sleep && time.GetElapsedTime(sleep) >= valueGrace);
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
