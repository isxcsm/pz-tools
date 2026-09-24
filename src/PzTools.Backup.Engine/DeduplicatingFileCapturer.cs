using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record StoredFileCapture(
    StableFileCaptureResult Capture,
    Guid PackId,
    bool Reused);

public sealed class DeduplicatingFileCapturer(StableFileCapturer capturer)
{
    private readonly Dictionary<ContentKey, List<PackObjectDescriptor>> runCandidates = [];
    private Guid? activePackId;

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
        if (activePackId != writer.PackId)
        {
            runCandidates.Clear();
            activePackId = writer.PackId;
        }

        await using var staged = await capturer.StageAsync(path, writer, cancellationToken, progress);
        var captured = await staged.CaptureAsync(writer, checksum, compression, cancellationToken, progress);
        if (!contentDeduplication)
        {
            return new StoredFileCapture(captured, writer.PackId, Reused: false);
        }

        if (captured.Object.ChecksumAlgorithm != ChecksumAlgorithm.Sha256)
        {
            throw new InvalidOperationException("Content deduplication requires SHA-256.");
        }

        var key = new ContentKey(
            captured.Object.OriginalLength,
            Convert.ToHexString(captured.Object.Checksum));
        if (runCandidates.TryGetValue(key, out var localCandidates))
        {
            foreach (var candidate in localCandidates)
            {
                if (!await ContentEqualsAsync(
                        staged.Content,
                        writer,
                        candidate,
                        cancellationToken))
                {
                    continue;
                }

                writer.DiscardLastObject(captured.Object);
                return new StoredFileCapture(
                    captured with { Object = candidate },
                    writer.PackId,
                    Reused: true);
            }
        }

        var candidates = await repository.FindDeduplicationCandidatesAsync(
            captured.Object.OriginalLength,
            captured.Object.Checksum,
            cancellationToken);
        foreach (var candidate in candidates)
        {
            if (!await ContentEqualsAsync(
                repository.RepositoryPath,
                staged.Content,
                candidate,
                cancellationToken))
            {
                continue;
            }

            writer.DiscardLastObject(captured.Object);
            var reusedDescriptor = new PackObjectDescriptor(
                candidate.ObjectId,
                candidate.PackOffset,
                PayloadOffset: 0,
                candidate.OriginalLength,
                candidate.StoredLength,
                Enum.Parse<ChecksumAlgorithm>(candidate.ChecksumAlgorithm),
                candidate.Checksum,
                Enum.Parse<CompressionAlgorithm>(candidate.CompressionAlgorithm),
                candidate.Flags);
            return new StoredFileCapture(
                captured with { Object = reusedDescriptor },
                candidate.PackId,
                Reused: true);
        }

        (localCandidates ??= []).Add(captured.Object);
        runCandidates[key] = localCandidates;
        return new StoredFileCapture(captured, writer.PackId, Reused: false);
    }

    private async Task<bool> ContentEqualsAsync(
        Stream stagedContent,
        PackWriter writer,
        PackObjectDescriptor candidate,
        CancellationToken cancellationToken)
    {
        stagedContent.Position = 0;
        await using var comparer = new ComparingWriteStream(stagedContent);
        try
        {
            await writer.CopyObjectToAsync(candidate, comparer, cancellationToken);
        }
        catch (ContentMismatchException)
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
        await using var reader = await PackReader.OpenForLocatedReadsAsync(
            packPath,
            candidate.PackId,
            cancellationToken);
        await using var comparer = new ComparingWriteStream(stagedContent);
        try
        {
            await reader.CopyObjectAtAsync(
                candidate.ObjectId,
                candidate.PackOffset,
                comparer,
                cancellationToken);
        }
        catch (ContentMismatchException)
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

    private sealed class ComparingWriteStream(Stream source) : Stream
    {
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public async Task<bool> IsSourceExhaustedAsync(CancellationToken cancellationToken)
        {
            var buffer = new byte[1];
            return await source.ReadAsync(buffer, cancellationToken) == 0;
        }

        public override async ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            var actual = new byte[buffer.Length];
            await source.ReadExactlyAsync(actual, cancellationToken);
            if (!buffer.Span.SequenceEqual(actual))
            {
                throw new ContentMismatchException();
            }
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            var actual = new byte[count];
            source.ReadExactly(actual);
            if (!buffer.AsSpan(offset, count).SequenceEqual(actual))
            {
                throw new ContentMismatchException();
            }
        }

        public override void Flush()
        {
        }

        public override Task FlushAsync(CancellationToken cancellationToken) => Task.CompletedTask;
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }

    private sealed class ContentMismatchException : Exception;

    private readonly record struct ContentKey(long Length, string Sha256);
}
