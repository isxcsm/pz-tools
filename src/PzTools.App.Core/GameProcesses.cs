namespace PzTools.App.Core;

/// <summary>How many copies of the game are running, by the same process names the game link uses.</summary>
public static class GameProcesses
{
    private static readonly string[] Names = ["ProjectZomboid64", "ProjectZomboid32", "ProjectZomboid"];

    /// <summary>Lists processes: cheap enough for a click or a check every few seconds, not for every frame.</summary>
    public static int Count()
    {
        var found = Names.SelectMany(System.Diagnostics.Process.GetProcessesByName).ToArray();
        foreach (var process in found) process.Dispose();
        return found.Length;
    }
}
