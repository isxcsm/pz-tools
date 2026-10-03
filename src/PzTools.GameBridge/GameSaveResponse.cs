namespace PzTools.GameBridge;

public enum GameSaveCompletion
{
    StandardCallReturned,
    DetachedWritesCommitted,
    GameSaveAndDatabaseQueuesDrained,
    GameSaveAndPendingWritesDrained,
}

/// <summary>A completion observation, not a promise of a transaction across the whole world.</summary>
public sealed record GameSaveResponse(string ProviderId, GameSaveCompletion Completion,
    string Detail, string? FallbackReason = null);
