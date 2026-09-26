using PzTools.SaveBridge;
using PzTools.Zomboid.State;
using PzTools.Process.Contracts;

namespace PzTools.Zomboid.Backup;

public sealed record GameSaveResult(string Outcome, string? Detail = null);

/// <summary>Skip inactive saves before attaching; the game revalidates active worlds before saving.</summary>
public sealed class BackupGameSave(Func<string, CancellationToken, Task<string>> saveRunningGame,
    Func<string, ActivityState>? activityProbe = null)
{
    public BackupGameSave(string bridgeDirectory, int connectionTimeoutSeconds = 30, int completionTimeoutSeconds = 150,
        int queueTimeoutSeconds = 15, string? notificationLanguage = "en", DateTimeOffset? scheduledSaveUtc = null)
        : this(ConfiguredGameSaveProviders.Create(
            new GameSaveClient(bridgeDirectory, connectionTimeoutSeconds, completionTimeoutSeconds,
                queueTimeoutSeconds, notificationLanguage, scheduledSaveUtc),
            PzToolsPathLayout.CreateDefault().DataRoot)) { }

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
    }

    private static ActivityState ProbeActivity(string sourcePath) =>
        new GameActivityLane().Probe(Path.Combine(sourcePath, "players.db")).State;
}
