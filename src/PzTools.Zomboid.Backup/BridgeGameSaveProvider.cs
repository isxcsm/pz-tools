using PzTools.GameExtensions;
using PzTools.SaveBridge;

namespace PzTools.Zomboid.Backup;

/// <summary>The JVM selects compatibility and fallback before starting, within the same authenticated request.</summary>
internal sealed class BridgeGameSaveProvider(GameSaveClient client) : IGameSaveProvider
{
    public string Id => ExtensionIds.SeamlessSave;
    public ValueTask<SaveProviderSupport> InspectAsync(string sourcePath, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(new SaveProviderSupport(true));
    }
    public async Task<SavePreparationReceipt> PrepareAsync(string sourcePath, CancellationToken cancellationToken)
    {
        var result = await client.PrepareRunningGameAsync(sourcePath, Id, cancellationToken);
        return new(result.ProviderId, result.Completion switch
        {
            GameSaveCompletion.StandardCallReturned => SaveCompletionKind.StandardCallReturned,
            GameSaveCompletion.DetachedWritesCommitted => SaveCompletionKind.CheckpointCommitted,
            GameSaveCompletion.GameSaveAndDatabaseQueuesDrained => SaveCompletionKind.GameSaveAndDatabaseQueuesDrained,
            _ => throw new GameSaveException("invalid-response", "Unknown save completion."),
        }, result.Detail, result.FallbackReason);
    }
}
