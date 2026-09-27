using PzTools.Backup.Storage.Packs;

namespace PzTools.Backup.Engine;

// A small per-backup LRU, not a process-global "this path was validated" cache.
// Readers retain verified handles, not whole object indexes. Every object read
// still validates its header, declared lengths, decompression and full checksum.
internal sealed class ValidatedPackReaderCache(int capacity = 8) : IAsyncDisposable
{
    private sealed record Entry(string Path, Guid PackId, PackReader Reader);
    private readonly LinkedList<Entry> recent = new();
    private readonly SemaphoreSlim gate = new(1, 1);
    private bool disposed;
    internal int ValidationCount { get; private set; }
    internal int CachedCount => recent.Count;

    internal async Task CopyObjectAtAsync(
        string path, Guid packId, Guid objectId, long offset, Stream destination,
        CancellationToken cancellationToken = default)
    {
        if (capacity is < 1 or > 64) throw new ArgumentOutOfRangeException(nameof(capacity));
        ArgumentNullException.ThrowIfNull(destination);
        path = Path.GetFullPath(path);
        await gate.WaitAsync(cancellationToken);
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            // FileShare.Read is a Windows deny-write/delete contract. Do not assume
            // that contract on Unix and reuse an unpinned path there.
            if (!OperatingSystem.IsWindows())
            {
                await using var uncached = await PackReader.OpenForLocatedReadsAsync(path, packId, cancellationToken);
                ValidationCount++;
                await uncached.CopyObjectAtAsync(objectId, offset, destination, cancellationToken);
                return;
            }
            var node = recent.First;
            while (node is not null && !(node.Value.PackId == packId
                   && StringComparer.OrdinalIgnoreCase.Equals(node.Value.Path, path)))
                node = node.Next;
            if (node is null)
            {
                // Evict before opening: never exceed the handle budget, even briefly.
                if (recent.Count == capacity) await RemoveAsync(recent.Last!);
                var reader = await PackReader.OpenPinnedForLocatedReadsAsync(path, packId, cancellationToken);
                ValidationCount++;
                node = recent.AddFirst(new Entry(path, packId, reader));
            }
            else
            {
                recent.Remove(node);
                recent.AddFirst(node);
            }
            try
            {
                await node.Value.Reader.CopyObjectAtAsync(objectId, offset, destination, cancellationToken);
            }
            catch
            {
                // Includes checksum failures, content mismatches and cancellation.
                // No partial comparison is remembered as a successful validation.
                await RemoveAsync(node);
                throw;
            }
        }
        finally { gate.Release(); }
    }

    private async ValueTask RemoveAsync(LinkedListNode<Entry> node)
    {
        recent.Remove(node);
        await node.Value.Reader.DisposeAsync();
    }

    internal async ValueTask ClearAsync()
    {
        await gate.WaitAsync();
        try
        {
            while (recent.Last is { } node) await RemoveAsync(node);
        }
        finally { gate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (disposed) return;
            disposed = true;
            while (recent.Last is { } node) await RemoveAsync(node);
        }
        finally { gate.Release(); }
        // No WaitHandle is allocated. Keep the managed gate valid for any queued
        // caller so it can observe ObjectDisposedException rather than race disposal.
    }
}
