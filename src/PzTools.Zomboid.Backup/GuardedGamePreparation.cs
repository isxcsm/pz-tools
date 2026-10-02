using PzTools.SaveBridge;

namespace PzTools.Zomboid.Backup;

/// <summary>Runtime-authoritative path; file-lock heuristics cannot override the game-thread guard.</summary>
public sealed class GuardedGamePreparation(GameSaveClient client)
{
    public async Task<GameSaveResult> PrepareAsync(string sourcePath, bool saveGame, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        try
        {
            var result = saveGame ? await client.SaveRunningGameAsync(sourcePath, token)
                : await client.ProbeRunningGameAsync(sourcePath, token);
            return new GameSaveResult(saveGame ? "saved" : "disabled", result);
        }
        catch (GameSaveException exception) when (exception.LinkUnavailable)
        {
            // The scheduler already found this backup due from the observed game. Only the request
            // channel is down, and nothing was asked of the game: back up what is on disk.
            return new GameSaveResult(BackupGameSave.SaveUnavailable, exception.Message);
        }
    }
}
