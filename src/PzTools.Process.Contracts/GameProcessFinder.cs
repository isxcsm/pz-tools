using System.Diagnostics;

namespace PzTools.Process.Contracts;

/// <summary>
/// The running game's processes. Asking for each process name separately took a snapshot of every
/// process on the system per name; one snapshot, filtered here, answers for all of them.
/// </summary>
public static class GameProcessFinder
{
    /// <summary>The executable names the game runs under.</summary>
    public static IReadOnlyList<string> Names { get; } = ["ProjectZomboid64", "ProjectZomboid32", "ProjectZomboid"];

    /// <summary>The game processes now running. The caller disposes them.</summary>
    public static System.Diagnostics.Process[] Find()
    {
        var all = System.Diagnostics.Process.GetProcesses();
        var found = new List<System.Diagnostics.Process>(1);
        foreach (var process in all)
        {
            bool game;
            try { game = Names.Contains(process.ProcessName, StringComparer.OrdinalIgnoreCase); }
            catch (InvalidOperationException) { game = false; } // exited during the snapshot
            if (game) found.Add(process);
            else process.Dispose();
        }
        return found.ToArray();
    }

    /// <summary>How many game processes are running.</summary>
    public static int Count()
    {
        var found = Find();
        foreach (var process in found) process.Dispose();
        return found.Length;
    }
}
