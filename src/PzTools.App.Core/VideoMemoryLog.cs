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
    /// <summary>About as often as a recording reads the heap (every 250 ms): a graph of the run, not of single frames.</summary>
    public static readonly TimeSpan Interval = TimeSpan.FromMilliseconds(200);
    // Windows without the counters (or a driver that does not report them) is asked again only now and then.
    private static readonly TimeSpan ReopenAfter = TimeSpan.FromSeconds(5);
    // Kept a little longer than asked: the window a save cuts begins when the game is asked, a moment after the app.
    private static readonly TimeSpan Slack = TimeSpan.FromSeconds(5);

    private readonly Func<int?> findGame = game ?? OneGame;
    private readonly Func<int, IVideoMemoryReader?> openReader = open ?? (id => GpuProcessMemory.TryOpen(id));
    private readonly TimeProvider time = timeProvider ?? TimeProvider.System;
    private readonly object gate = new();
    private readonly object sampling = new();
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
            // Nothing records any more: what was read belonged to recordings that are written. Turned on again since,
            // a newer loop has the reader.
            lock (sampling) lock (gate)
                if (!active) { readings.Clear(); reader?.Dispose(); reader = null; process = null; }
        }
    }

    // One reading at a time (a loop stopped and started again may overlap the next for a tick). The counters are opened
    // and read outside the lock that Between and Configure take, so neither waits on Windows' counters.
    internal void SampleOnce()
    {
        lock (sampling) Sample();
    }

    private void Sample()
    {
        var id = findGame();
        var now = time.GetUtcNow();
        if (id is { } game && game != process)
        {
            // Another game: what was read belongs to the one before. No game found this once (a snapshot between two
            // processes, a lookup that failed) is no reason to drop what was read.
            reader?.Dispose();
            (reader, process, openedAt) = (null, game, DateTimeOffset.MinValue);
            lock (gate) readings.Clear();
        }
        if (reader is null && id is { } open && now - openedAt >= ReopenAfter)
        {
            openedAt = now;
            reader = openReader(open);
        }
        var reading = id is null ? null : reader?.Read();
        lock (gate)
        {
            if (reading is { } read) readings.Add(new(now, read.Dedicated, read.Shared));
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
