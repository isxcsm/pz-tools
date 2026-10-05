using PzTools.Process.Contracts;
using PzTools.Profiling;

namespace PzTools.App.Core;

/// <summary>
/// The game's video memory while a recording runs, the one asked for or the rolling one: the game cannot measure it, so
/// it is read here, from outside, and joined to each recording as it is written (<see cref="Between"/>). One reader for
/// every kind of recording, so none goes without it.
/// </summary>
public sealed class VideoMemoryLog(Func<int?>? game = null, Func<int, IVideoMemoryReader?>? open = null,
    TimeProvider? timeProvider = null)
{
    /// <summary>As often as a recording's own readings of the heap: a graph of the run, not of single frames.</summary>
    public static readonly TimeSpan Interval = TimeSpan.FromMilliseconds(200);
    // Windows without the counters (or a driver that does not report them) is asked again only now and then.
    private static readonly TimeSpan ReopenAfter = TimeSpan.FromSeconds(5);
    // Kept a little longer than asked: the window a save cuts begins when the game is asked, a moment after the app.
    private static readonly TimeSpan Slack = TimeSpan.FromSeconds(5);

    private readonly Func<int?> findGame = game ?? OneGame;
    private readonly Func<int, IVideoMemoryReader?> openReader = open ?? (id => GpuProcessMemory.TryOpen(id));
    private readonly TimeProvider time = timeProvider ?? TimeProvider.System;
    private readonly object gate = new();
    private readonly List<VideoMemoryReading> readings = [];
    private IVideoMemoryReader? reader;
    private int? process;
    private DateTimeOffset openedAt = DateTimeOffset.MinValue;
    private bool active;
    private TimeSpan keep;
    private DateTimeOffset? holdFrom;
    private CancellationTokenSource? running;

    /// <summary>Reads on its own while active; tests read with <see cref="SampleOnce"/> instead.</summary>
    internal bool Background { get; init; } = true;

    /// <summary>
    /// What is recording: read while <paramref name="active"/>, keeping the last <paramref name="keep"/> (the rolling
    /// window) and everything since <paramref name="holdFrom"/> (a recording under way).
    /// </summary>
    public void Configure(bool active, TimeSpan keep, DateTimeOffset? holdFrom)
    {
        CancellationTokenSource? stop = null;
        lock (gate)
        {
            (this.active, this.keep, this.holdFrom) = (active, keep, holdFrom);
            if (active && running is null && Background)
            {
                var token = (running = new CancellationTokenSource()).Token;
                _ = Task.Run(() => RunAsync(token));
            }
            else if (!active && running is not null) (stop, running) = (running, null);
        }
        stop?.Cancel();
    }

    /// <summary>The readings taken between the two times, both included.</summary>
    public IReadOnlyList<VideoMemoryReading> Between(DateTimeOffset from, DateTimeOffset to)
    {
        lock (gate) return readings.Where(item => item.At >= from && item.At <= to).ToArray();
    }

    private async Task RunAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(Interval, time);
        try
        {
            do
            {
                try { SampleOnce(); }
                // A reading is extra: whatever the counters do, the recording goes on without it.
                catch (Exception exception) when (exception is not OutOfMemoryException) { }
            }
            while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) { }
        finally
        {
            lock (gate)
            {
                // Nothing records any more: what was read belonged to recordings that are written.
                if (!active) { readings.Clear(); reader?.Dispose(); reader = null; process = null; }
            }
        }
    }

    internal void SampleOnce()
    {
        var id = findGame();
        var now = time.GetUtcNow();
        lock (gate)
        {
            if (id != process)
            {
                // Another game, or none: what was read belongs to the one before.
                reader?.Dispose();
                (reader, process, openedAt) = (null, id, DateTimeOffset.MinValue);
                readings.Clear();
            }
            if (reader is null && id is { } game && now - openedAt >= ReopenAfter)
            {
                openedAt = now;
                reader = openReader(game);
            }
            if (reader?.Read() is { } reading) readings.Add(new(now, reading.Dedicated, reading.Shared));
            var before = now - keep - Slack;
            if (holdFrom is { } held && held - Slack < before) before = held - Slack;
            var old = readings.FindIndex(item => item.At >= before);
            readings.RemoveRange(0, old < 0 ? readings.Count : old);
        }
    }

    private static int? OneGame()
    {
        var games = GameProcessFinder.Find(GameProcessFinder.WatchSnapshotAge);
        try { return games.Length == 1 ? games[0].Id : null; }
        finally { foreach (var game in games) game.Dispose(); }
    }
}
