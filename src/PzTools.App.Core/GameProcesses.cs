namespace PzTools.App.Core;

/// <summary>How many copies of the game are running, by the same process names the game link uses.</summary>
public static class GameProcesses
{
    /// <summary>One system process snapshot: cheap enough for a click or a check every few seconds, not for every frame.</summary>
    public static int Count() => PzTools.Process.Contracts.GameProcessFinder.Count();
}
