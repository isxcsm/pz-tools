using System.ComponentModel;

namespace PzTools.Zomboid.State;

/// <summary>Live eligibility for automatic work, independent of persisted/debounced UI state.</summary>
public static class AutomaticBackupActivity
{
    public static ActivityState Probe(string sourcePath)
    {
        var running = false;
        try
        {
            var processes = PzTools.Process.Contracts.GameProcessFinder.Find();
            try { running = processes.Any(process => !process.HasExited); }
            finally { foreach (var process in processes) process.Dispose(); }
        }
        catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
        {
            return ActivityState.Unknown;
        }
        if (!running) return ActivityState.Inactive;
        // A process at the main menu, or one playing another save, is not enough.
        return new GameActivityLane().Probe(Path.Combine(sourcePath, "players.db")).State;
    }
}
