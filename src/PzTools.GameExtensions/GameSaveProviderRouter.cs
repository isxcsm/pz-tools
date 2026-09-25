namespace PzTools.GameExtensions;

public enum SaveCompletionKind { StandardCallReturned, CheckpointCommitted }
public sealed record SavePreparationReceipt(string ProviderId, SaveCompletionKind Completion,
    string Detail, string? FallbackReason = null);
public sealed record SaveProviderSupport(bool Supported, string? Reason = null);

// Saving is a capability, not the common module lifecycle. Driving modules need not implement it.
public interface IGameSaveProvider
{
    string Id { get; }
    ValueTask<SaveProviderSupport> InspectAsync(string sourcePath, CancellationToken cancellationToken);
    Task<SavePreparationReceipt> PrepareAsync(string sourcePath, CancellationToken cancellationToken);
}

/// <summary>Fallback is permitted only BEFORE a provider starts. A failed or uncertain save is never replayed.</summary>
public sealed class GameSaveProviderRouter(IGameSaveProvider standard, IGameSaveProvider? extension = null)
{
    public async Task<SavePreparationReceipt> PrepareAsync(string path, bool enabled,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!enabled || extension is null)
            return await standard.PrepareAsync(path, cancellationToken);
        var support = await extension.InspectAsync(path, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        if (!support.Supported)
            return (await standard.PrepareAsync(path, cancellationToken)) with { FallbackReason = support.Reason };
        // Do not catch and retry: PrepareAsync may have changed the world before failing.
        return await extension.PrepareAsync(path, cancellationToken);
    }
}
