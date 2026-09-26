using PzTools.Process.Contracts.GameRuntime;
using PzTools.SaveBridge;

namespace PzTools.Zomboid.Backup;

/// <summary>Runtime-authoritative path; file-lock heuristics cannot override the game-thread guard.</summary>
public sealed class GuardedGamePreparation(GameSaveClient client)
{
    public async Task<GameSaveResult> PrepareAsync(string sourcePath, bool saveGame, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var result = saveGame ? await client.SaveRunningGameAsync(sourcePath, token)
            : await client.ProbeRunningGameAsync(sourcePath, token);
        return new GameSaveResult(saveGame ? "saved" : "disabled", result);
    }
}