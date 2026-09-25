using PzTools.Backup.Storage.Repository;

namespace PzTools.Projections;

public sealed class ThumbnailCache(long maximumBytes = 64 * 1024 * 1024,
    long maximumImageBytes = 16 * 1024 * 1024)
{
    private readonly object gate = new();
    private readonly Dictionary<string, CacheEntry> entries = new(StringComparer.Ordinal);
    private readonly long maximumBytes = maximumBytes > 0
        ? maximumBytes : throw new ArgumentOutOfRangeException(nameof(maximumBytes));
    // Bound concurrent pack I/O on cache misses without retaining pack handles in UI.
    private readonly SemaphoreSlim revisionReadGate = new(1, 1);
    private long bytes;
    private long accessSequence;

    public async Task<byte[]?> ReadRevisionThumbnailAsync(
        string cacheKey,
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await revisionReadGate.WaitAsync(cancellationToken);
        try
        {
            // Check the revision is still available before serving cached content.
            // Repository identity prevents aliasing across reset repositories.
            var locator = await repository.TryLocateRevisionFileAsync(
                sourceId, revision, "thumb.png", cancellationToken);
            if (locator is null) return null;
            var objectKey = $"object:{repository.Identity.RepositoryId:D}:{locator.ObjectId:D}";
            if (TryGet(objectKey, out var cached)) return cached;
            var value = await new RevisionFileReader(repository).ReadBytesAsync(
                locator, Math.Min(maximumBytes, maximumImageBytes), cancellationToken);
            if (!IsPng(value)) return null;
            Add(objectKey, value);
            return value;
        }
        catch (Exception exception) when (
            exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            return null;
        }
        finally { revisionReadGate.Release(); }
    }

    public async Task<byte[]?> ReadLiveThumbnailAsync(
        string cacheKey,
        string savePath,
        CancellationToken cancellationToken = default)
    {
        if (TryGet(cacheKey, out var cached)) return cached;
        var path = Path.Combine(Path.GetFullPath(savePath), "thumb.png");
        try
        {
            await using var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (stream.Length <= 0 || stream.Length > Math.Min(maximumBytes, maximumImageBytes))
                return null;
            var value = new byte[checked((int)stream.Length)];
            await stream.ReadExactlyAsync(value, cancellationToken);
            if (!IsPng(value)) return null;
            Add(cacheKey, value);
            return value;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private bool TryGet(string key, out byte[]? value)
    {
        lock (gate)
        {
            if (!entries.TryGetValue(key, out var entry))
            {
                value = null;
                return false;
            }
            entries[key] = entry with { AccessSequence = ++accessSequence };
            value = entry.Value;
            return true;
        }
    }

    private void Add(string key, byte[] value)
    {
        if (value.LongLength > maximumBytes) return;
        lock (gate)
        {
            if (entries.Remove(key, out var previous)) bytes -= previous.Value.LongLength;
            entries.Add(key, new CacheEntry(value, ++accessSequence));
            bytes += value.LongLength;
            while (bytes > maximumBytes && entries.Count > 0)
            {
                var oldest = entries.MinBy(item => item.Value.AccessSequence);
                entries.Remove(oldest.Key);
                bytes -= oldest.Value.Value.LongLength;
            }
        }
    }

    private static bool IsPng(byte[] value) =>
        value.Length >= 8
        && value.AsSpan(0, 8).SequenceEqual(
            new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });

    private sealed record CacheEntry(byte[] Value, long AccessSequence);
}
