using System.Buffers.Binary;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record StoredFileCapture(
    StableFileCaptureResult Capture,
    Guid PackId,
    bool Reused);

public sealed class DeduplicatingFileCapturer(StableFileCapturer capturer) : IAsyncDisposable
{
    private readonly Dictionary<ContentKey, List<PackObjectDescriptor>> runCandidates = [];
    private Guid? activePackId;
    private readonly ValidatedPackReaderCache readers = new();
    private bool disposed;
    internal int PackValidationCount => readers.ValidationCount;

    // Injected runners may reuse the capturer, but never carry handles past a run.
    internal async ValueTask EndRunAsync()
    {
        await readers.ClearAsync();
        runCandidates.Clear();
        activePackId = null;
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        disposed = true;
        await readers.DisposeAsync();
        runCandidates.Clear();
    }

    public async Task<StoredFileCapture> CaptureAsync(
        RepositoryDatabase repository,
        string path,
        PackWriter writer,
        ChecksumAlgorithm checksum,
        CompressionAlgorithm compression,
        bool contentDeduplication,
        CancellationToken cancellationToken = default,
        Func<FileCopyProgress, ValueTask>? progress = null)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(writer);
        if (contentDeduplication && checksum != ChecksumAlgorithm.Sha256)
            throw new InvalidOperationException("Content deduplication requires SHA-256.");
        if (checksum is not (ChecksumAlgorithm.None or ChecksumAlgorithm.XxHash64 or ChecksumAlgorithm.Sha256)
            || compression is not (CompressionAlgorithm.None or CompressionAlgorithm.Brotli))
            throw new ArgumentException("Resolve storage algorithms before capturing files.");

        if (activePackId != writer.PackId)
        {
            await EndRunAsync();
            activePackId = writer.PackId;
        }

        try
        {
            await using var staged = await capturer.StageAsync(path, writer, cancellationToken, progress,
                requireFullHash: contentDeduplication);

            async Task<StoredFileCapture> ReuseAsync(PackObjectDescriptor descriptor, Guid packId)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (progress is not null)
                    await progress(new FileCopyProgress(staged.Content.Length, staged.Content.Length, 1, "deduplication"));
                cancellationToken.ThrowIfCancellationRequested();
                return new StoredFileCapture(staged.Reuse(descriptor), packId, Reused: true);
            }

            if (!contentDeduplication)
                return new StoredFileCapture(await staged.CaptureAsync(
                    writer, checksum, compression, cancellationToken, progress), writer.PackId, Reused: false);

            // Hash while staging, search before compression, and still compare every byte.
            // A short change fingerprint is NEVER a deduplication key.
            var digest = staged.FullSha256;
            var key = ContentKey.Create(staged.Content.Length, digest.Span);
            if (runCandidates.TryGetValue(key, out var localCandidates))
            {
                foreach (var candidate in localCandidates)
                {
                    if (await ContentEqualsAsync(staged.Content, writer, candidate, cancellationToken))
                        return await ReuseAsync(candidate, writer.PackId);
                }
            }

            var candidates = await repository.FindDeduplicationCandidatesAsync(
                staged.Content.Length, digest.ToArray(), cancellationToken);
            foreach (var candidate in candidates)
            {
                if (!await ContentEqualsAsync(repository.RepositoryPath, staged.Content, candidate, cancellationToken))
                    continue;
                var descriptor = new PackObjectDescriptor(
                    candidate.ObjectId, candidate.PackOffset, PayloadOffset: 0,
                    candidate.OriginalLength, candidate.StoredLength,
                    Enum.Parse<ChecksumAlgorithm>(candidate.ChecksumAlgorithm), candidate.Checksum,
                    Enum.Parse<CompressionAlgorithm>(candidate.CompressionAlgorithm), candidate.Flags);
                return await ReuseAsync(descriptor, candidate.PackId);
            }

            var captured = await staged.CaptureAsync(writer, checksum, compression, cancellationToken, progress);
            (localCandidates ??= []).Add(captured.Object);
            runCandidates[key] = localCandidates;
            return new StoredFileCapture(captured, writer.PackId, Reused: false);
        }
        catch
        {
            // Even direct callers must not seal a run after a failed/cancelled comparison.
            writer.Invalidate("deduplication capture failed");
            await EndRunAsync();
            throw;
        }

    }

    private async Task<bool> ContentEqualsAsync(
        Stream stagedContent,
        PackWriter writer,
        PackObjectDescriptor candidate,
        CancellationToken cancellationToken)
    {
        stagedContent.Position = 0;
        await using var comparer = new ContentComparisonStream(stagedContent);
        try
        {
            await writer.CopyObjectToAsync(candidate, comparer, cancellationToken);
        }
        catch (ContentComparisonStream.ContentMismatchException)
        {
            return false;
        }

        if (!await comparer.IsSourceExhaustedAsync(cancellationToken))
        {
            return false;
        }

        return true;
    }

    private async Task<bool> ContentEqualsAsync(
        string repositoryPath,
        Stream stagedContent,
        DeduplicationCandidate candidate,
        CancellationToken cancellationToken)
    {
        stagedContent.Position = 0;
        var packPath = ResolveRepositoryPath(repositoryPath, candidate.PackRelativePath);
        await using var comparer = new ContentComparisonStream(stagedContent);
        try
        {
            await readers.CopyObjectAtAsync(
                packPath,
                candidate.PackId,
                candidate.ObjectId,
                candidate.PackOffset,
                comparer,
                cancellationToken);
        }
        catch (ContentComparisonStream.ContentMismatchException)
        {
            return false;
        }

        if (!await comparer.IsSourceExhaustedAsync(cancellationToken))
        {
            return false;
        }

        return true;
    }

    private static string ResolveRepositoryPath(string repositoryPath, string relativePath)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(repositoryPath));
        var path = Path.GetFullPath(Path.Combine(
            root,
            relativePath.Replace('/', Path.DirectorySeparatorChar)));
        if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Deduplication candidate pack escapes the repository.");
        }

        return path;
    }

    // Avoid a 64-character hex string allocation for each captured file.
    private readonly record struct ContentKey(long Length, ulong A, ulong B, ulong C, ulong D)
    {
        public static ContentKey Create(long length, ReadOnlySpan<byte> digest)
        {
            if (digest.Length != 32) throw new InvalidDataException("A full SHA-256 digest is required for deduplication.");
            return new(length,
                BinaryPrimitives.ReadUInt64BigEndian(digest),
                BinaryPrimitives.ReadUInt64BigEndian(digest[8..]),
                BinaryPrimitives.ReadUInt64BigEndian(digest[16..]),
                BinaryPrimitives.ReadUInt64BigEndian(digest[24..]));
        }
    }
}
