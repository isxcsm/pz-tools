using System.Diagnostics;
using DiagnosticsProcess = System.Diagnostics.Process;

namespace PzTools.Process.Contracts;

/// <summary>
/// The running game's processes. Asking for each process name separately took a snapshot of every
/// process on the system per name; one snapshot, filtered here, answers for all of them.
/// </summary>
public static class GameProcessFinder
{
    /// <summary>The executable names the game runs under.</summary>
    public static IReadOnlyList<string> Names { get; } = ["ProjectZomboid64", "ProjectZomboid32", "ProjectZomboid"];

    private static readonly object Gate = new();
    private static (long Taken, (int Id, DateTime Started)[] Games)? recent;

    /// <summary>The game processes now running. The caller disposes them.</summary>
    public static DiagnosticsProcess[] Find()
    {
        var all = DiagnosticsProcess.GetProcesses();
        var games = new List<DiagnosticsProcess>(1);
        foreach (var process in all)
        {
            bool game;
            try { game = Names.Contains(process.ProcessName, StringComparer.OrdinalIgnoreCase); }
            catch (InvalidOperationException) { game = false; } // exited during the snapshot
            if (game) games.Add(process);
            else process.Dispose();
        }
        var found = games.ToArray();
        Remember(found);
        return found;
    }

    /// <summary>
    /// Like <see cref="Find"/>, but reuses a snapshot taken within <paramref name="maximumAge"/>: for loops
    /// that only watch for the game to come or go. A listing of every process on the machine is what such a
    /// loop costs; two loops a second each taking one was most of an idle scheduler's CPU. A process from
    /// that snapshot is returned only while it still runs as the same instance (same start time).
    /// </summary>
    public static DiagnosticsProcess[] Find(TimeSpan maximumAge)
    {
        (int Id, DateTime Started)[]? games = null;
        lock (Gate)
            if (recent is { } last && Stopwatch.GetElapsedTime(last.Taken) <= maximumAge) games = last.Games;
        if (games is null) return Find();
        var result = new List<DiagnosticsProcess>(games.Length);
        foreach (var (id, started) in games)
        {
            DiagnosticsProcess? process = null;
            try
            {
                process = DiagnosticsProcess.GetProcessById(id);
                if (!process.HasExited && process.StartTime == started) { result.Add(process); process = null; }
            }
            catch (Exception exception) when (exception is ArgumentException or InvalidOperationException
                or System.ComponentModel.Win32Exception or NotSupportedException) { }
            finally { process?.Dispose(); }
        }
        return [.. result];
    }

    /// <summary>How many game processes are running.</summary>
    public static int Count()
    {
        var found = Find();
        foreach (var process in found) process.Dispose();
        return found.Length;
    }

    private static void Remember(DiagnosticsProcess[] games)
    {
        var known = new List<(int, DateTime)>(games.Length);
        foreach (var game in games)
        {
            try { known.Add((game.Id, game.StartTime)); }
            catch (Exception exception) when (exception is InvalidOperationException
                or System.ComponentModel.Win32Exception or NotSupportedException)
            {
                // A game whose start time cannot be read is not remembered; the next call takes a new snapshot.
                lock (Gate) recent = null;
                return;
            }
        }
        lock (Gate) recent = (Stopwatch.GetTimestamp(), [.. known]);
    }
}
