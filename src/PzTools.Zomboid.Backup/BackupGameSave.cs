using PzTools.GameBridge;
using PzTools.Zomboid.State;

namespace PzTools.Zomboid.Backup;

public sealed record GameSaveResult(string Outcome, string? Detail = null);

/// <summary>Skip inactive saves before attaching; the game revalidates active worlds before saving.</summary>
public sealed class BackupGameSave(Func<string, CancellationToken, Task<string>> saveRunningGame,
    Func<string, ActivityState>? activityProbe = null)
{
    public BackupGameSave(string bridgeDirectory, int connectionTimeoutSeconds = 30, int completionTimeoutSeconds = 150,
        int queueTimeoutSeconds = 15, string? notificationLanguage = "en", DateTimeOffset? scheduledSaveUtc = null)
        : this(new GameSaveClient(bridgeDirectory, connectionTimeoutSeconds, completionTimeoutSeconds,
            queueTimeoutSeconds, notificationLanguage, scheduledSaveUtc).SaveRunningGameAsync) { }

    /// <summary>The game could not be reached; the backup continues with the files as they are on disk.</summary>
    public const string SaveUnavailable = "save-unavailable";

    public async Task<GameSaveResult> PrepareAsync(string sourcePath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // Read the selected save now, not the debounced UI/scheduler snapshot. A
        // running game process may be at its menu or playing a different world.
        var activity = (activityProbe ?? ProbeActivity)(sourcePath);
        if (activity == ActivityState.Inactive)
            return new("not-in-world", "The selected save is inactive. No game connection or save request was made.");
        // Unknown is not evidence of inactivity (missing DB, access denied, etc.).
        // Keep the game's own world/path validation and fail-closed error handling.
        try
        {
            return new("saved", await saveRunningGame(sourcePath, cancellationToken));
        }
        catch (GameSaveException exception) when (exception.Code is
            "game-not-running" or "not-in-world" or "save-mismatch")
        {
            // These responses are produced before save(true), not after an uncertain save.
            return new(exception.Code, exception.Message);
        }
        catch (GameSaveException exception) when (exception.LinkUnavailable)
        {
            // Nothing was asked of the game. A backup of what is on disk beats no backup at all.
            return new(SaveUnavailable, exception.Diagnostics ?? exception.Message);
        }
    }

    private static ActivityState ProbeActivity(string sourcePath) =>
        new GameActivityLane().Probe(Path.Combine(sourcePath, "players.db")).State;

    /// <summary>The game waits in its Lua debugger: the backup takes its last completed save, without asking it.</summary>
    public const string GameInDebugger = "game-debugger";

    /// <summary>
    /// A backup of a save whose game waits in its Lua debugger (RuntimeObservation.DebuggerStopFor). The game cannot
    /// save until its player goes on, so it is not asked, and nothing waits for it: what is on disk is its last
    /// completed save, unless it stopped while writing one. That is known from where the game stopped (inside its save)
    /// and from a database transaction left open in the save's folder (a rollback journal): then the files may be half
    /// written, and the backup is refused rather than keep them.
    /// </summary>
    public static GameSaveResult FromLastSave(string sourcePath, bool stoppedWhileSaving)
    {
        if (stoppedWhileSaving)
            throw new GameStoppedMidSaveException("The game stopped in its Lua debugger while saving.");
        if (OpenTransaction(sourcePath) is { } journal)
            throw new GameStoppedMidSaveException($"A save database transaction is open ({journal}).");
        return new(GameInDebugger, "The game is stopped in its Lua debugger; its last completed save is backed up.");
    }

    private static string? OpenTransaction(string sourcePath)
    {
        try
        {
            return Directory.EnumerateFiles(sourcePath, "*.db-journal", SearchOption.TopDirectoryOnly)
                .Select(Path.GetFileName).FirstOrDefault();
        }
        catch (DirectoryNotFoundException) { return null; }
    }
}

/// <summary>The game stopped in the middle of writing its save: a backup now would keep a half-written save.</summary>
public sealed class GameStoppedMidSaveException(string detail) : IOException($"{Code}: {detail}")
{
    public const string Code = "game-stopped-mid-save";
}
