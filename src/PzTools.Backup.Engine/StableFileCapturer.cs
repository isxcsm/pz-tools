using System.Buffers;
using System.Diagnostics;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;

namespace PzTools.Backup.Engine;

public sealed record StableFileCaptureResult(
    PackObjectDescriptor Object,
    FileCaptureMetadata SourceMetadata,
    byte[]? ContentHash = null)
{
    public string? ContentHashAlgorithm => ContentHash is null ? null : ContentFingerprint.AlgorithmName;
}

public sealed record FileCopyProgress(long CopiedBytes, long TotalBytes, int Attempt, string Phase = "copy");

public sealed class StagedFileCapture(
    Stream content, FileCaptureMetadata sourceMetadata, byte[]? contentHash = null,
    byte[]? fullSha256 = null)
    : IAsyncDisposable
{
    public Stream Content { get; } = content;
    public FileCaptureMetadata SourceMetadata { get; } = sourceMetadata;

    // This digest describes the private staged copy, never a later live source read.
    internal ReadOnlyMemory<byte> FullSha256 { get; } = fullSha256 ?? [];

    internal StableFileCaptureResult Reuse(PackObjectDescriptor storedObject) =>
        new(storedObject, SourceMetadata, contentHash);

    public async Task<StableFileCaptureResult> CaptureAsync(
        PackWriter packWriter,
        ChecksumAlgorithm checksumAlgorithm,
        CompressionAlgorithm compressionAlgorithm,
        CancellationToken cancellationToken = default,
        Func<FileCopyProgress, ValueTask>? progress = null)
    {
        Content.Position = 0;
        try
        {
            var storedObject = await packWriter.AddObjectAsync(
                Content, checksumAlgorithm, compressionAlgorithm, cancellationToken,
                progress is null ? null : bytes => progress(new(bytes, Content.Length, 1, "capture")));
            return new StableFileCaptureResult(storedObject, SourceMetadata, contentHash);
        }
        catch
        {
            packWriter.Invalidate("capture from staging failed");
            throw;
        }
    }

    public ValueTask DisposeAsync() => Content.DisposeAsync();
}

public interface IStableFileCapturer
{
    Task<StableFileCaptureResult> CaptureAsync(
        string path,
        PackWriter packWriter,
        ChecksumAlgorithm checksumAlgorithm,
        CompressionAlgorithm compressionAlgorithm,
        CancellationToken cancellationToken = default,
        Func<FileCopyProgress, ValueTask>? progress = null);
}

public sealed class StableFileCapturer : IStableFileCapturer
{
    private readonly IFileMetadataReader metadataReader;
    private readonly bool verifyStagedCopies;
    private readonly bool recordContentHash;
    private readonly int maxAttempts;
    private readonly BackupTuningOptions tuning;
    private readonly object metadataGate = new();
    private readonly BoundedStagingBufferPool? stagingBuffers;

    internal long AllocatedStagingBytes => stagingBuffers?.AllocatedBytes ?? 0;
    internal long LeasedStagingBytes => stagingBuffers?.LeasedBytes ?? 0;

    public StableFileCapturer(
        IFileMetadataReader metadataReader,
        bool verifyStagedCopies = true,
        int maxAttempts = 5,
        bool recordContentHash = true,
        BackupTuningOptions? tuning = null)
    {
        this.metadataReader = metadataReader;
        this.verifyStagedCopies = verifyStagedCopies;
        this.recordContentHash = recordContentHash;
        this.tuning = tuning ?? new();
        ArgumentOutOfRangeException.ThrowIfNegative(this.tuning.SmallFileStagingKib);
        if (this.tuning.SmallFileStagingKib > 0)
            stagingBuffers = new BoundedStagingBufferPool(
                checked(this.tuning.SmallFileStagingKib * 1024),
                checked((long)this.tuning.StagingMemoryMib * 1024 * 1024));
        this.maxAttempts = maxAttempts > 0 ? maxAttempts
            : throw new ArgumentOutOfRangeException(nameof(maxAttempts));
    }

    public async Task<StableFileCaptureResult> CaptureAsync(
        string path,
        PackWriter packWriter,
        ChecksumAlgorithm checksumAlgorithm,
        CompressionAlgorithm compressionAlgorithm,
        CancellationToken cancellationToken = default,
        Func<FileCopyProgress, ValueTask>? progress = null)
    {
        await using var staged = await StageAsync(path, packWriter, cancellationToken, progress);
        return await staged.CaptureAsync(
            packWriter, checksumAlgorithm, compressionAlgorithm, cancellationToken, progress);
    }

    public async Task<StagedFileCapture> StageAsync(
        string path,
        PackWriter packWriter,
        CancellationToken cancellationToken = default,
        Func<FileCopyProgress, ValueTask>? progress = null,
        bool requireFullHash = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(packWriter);
        var absolutePath = Path.GetFullPath(path);
        try
        {
            return await StageAsync(absolutePath, packWriter.CreateCaptureStagingStream,
                cancellationToken, progress, requireFullHash);
        }
        catch (OperationCanceledException)
        {
            packWriter.Invalidate($"capture of '{absolutePath}' was cancelled");
            throw;
        }
        catch (StagingStorageException)
        {
            packWriter.Invalidate($"capture staging for '{absolutePath}' failed");
            throw;
        }
        catch (UnstableFileException)
        {
            packWriter.Invalidate($"capture of '{absolutePath}' was unstable");
            throw;
        }
    }

    // Producers own only their private copy. A pipeline consumer owns pack mutation
    // and invalidation; this overload never touches a PackWriter.
    public async Task<StagedFileCapture> StageAsync(
        string path,
        Func<FileStream> createDiskStaging,
        CancellationToken cancellationToken = default,
        Func<FileCopyProgress, ValueTask>? progress = null,
        bool requireFullHash = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        ArgumentNullException.ThrowIfNull(createDiskStaging);
        var absolutePath = Path.GetFullPath(path);
        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                return await StageOnceAsync(
                    absolutePath, createDiskStaging, attempt, progress, cancellationToken, requireFullHash);
            }
            catch (StagingStorageException)
            {
                throw;
            }
            catch (Exception exception) when (exception is UnstableFileException
                or IOException or UnauthorizedAccessException
                or System.ComponentModel.Win32Exception)
            {
                var unstable = exception as UnstableFileException
                    ?? new UnstableFileException(absolutePath, "file access failed", exception);
                if (attempt == maxAttempts)
                {
                    throw unstable;
                }
                await Task.Delay(TimeSpan.FromMilliseconds(tuning.CaptureRetryDelayMs * attempt), cancellationToken);
            }
        }
        throw new InvalidOperationException("The capture retry loop ended unexpectedly.");
    }

    private async Task<StagedFileCapture> StageOnceAsync(
        string path,
        Func<FileStream> createDiskStaging,
        int attempt,
        Func<FileCopyProgress, ValueTask>? progress,
        CancellationToken cancellationToken,
        bool requireFullHash)
    {
        var beforePath = ReadPathMetadata(path);
        await using var source = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            bufferSize: tuning.CopyBufferKib * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var beforeHandle = ReadHandleMetadata(source.SafeFileHandle);
        if (!StringComparer.Ordinal.Equals(beforePath.Identity, beforeHandle.Identity))
            throw new UnstableFileException(path, "was replaced while opening");
        if (!verifyStagedCopies)
            EnsureEquivalent(path, beforePath, beforeHandle, "changed while opening");

        HashedFile? beforeHash = null;
        if (verifyStagedCopies)
        {
            beforeHash = await HashAsync(source, cancellationToken);
            source.Position = 0;
        }

        Stream staging;
        try
        {
            staging = stagingBuffers is not null && beforeHandle.Length <= (long)tuning.SmallFileStagingKib * 1024
                ? new SpillableCaptureStream(await stagingBuffers.RentAsync(cancellationToken), createDiskStaging)
                : createDiskStaging();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new StagingStorageException("Could not create a temporary copy.", exception);
        }
        try
        {
            var copyHash = await CopyAsync(source, staging, beforeHandle.Length,
                attempt, progress, cancellationToken, requireFullHash);
            var afterHandle = ReadHandleMetadata(source.SafeFileHandle);
            var afterPath = ReadPathMetadata(path);
            if (!StringComparer.Ordinal.Equals(afterHandle.Identity, afterPath.Identity)
                || !StringComparer.Ordinal.Equals(beforeHandle.Identity, afterPath.Identity))
                throw new UnstableFileException(path, "was renamed, deleted, or replaced");

            FileCaptureMetadata capturedMetadata;
            if (!verifyStagedCopies)
            {
                EnsureEquivalent(path, beforeHandle, afterHandle, "changed while copying");
                EnsureEquivalent(path, afterHandle, afterPath, "changed while copying");
                if (staging.Length != afterPath.Length)
                    throw new UnstableFileException(path, "copy length changed");
                capturedMetadata = afterPath;
            }
            else if (copyHash.Length == beforeHash!.Value.Length
                && copyHash.Hash.AsSpan().SequenceEqual(beforeHash.Value.Hash))
            {
                capturedMetadata = beforeHandle;
            }
            else
            {
                source.Position = 0;
                var postBefore = ReadHandleMetadata(source.SafeFileHandle);
                var postHash = await HashAsync(source, cancellationToken);
                var postAfter = ReadHandleMetadata(source.SafeFileHandle);
                if (!StringComparer.Ordinal.Equals(postBefore.Identity, postAfter.Identity)
                    || !StringComparer.Ordinal.Equals(postAfter.Identity,
                        ReadPathMetadata(path).Identity))
                    throw new UnstableFileException(path, "was replaced while rechecking");
                if (copyHash.Length != postHash.Length
                    || !copyHash.Hash.AsSpan().SequenceEqual(postHash.Hash))
                    throw new UnstableFileException(path, "copy differs from both source reads");
                // Use metadata from before the matching read. A later game write
                // must make the next scan revisit this file, not appear captured.
                capturedMetadata = postBefore;
            }

            // Matching source hashes can survive growth/truncation after the
            // metadata read. Keep the earlier timestamps for change detection,
            // but the catalog length must describe the verified private copy.
            if (capturedMetadata.Length != copyHash.Length)
                capturedMetadata = capturedMetadata with { Length = copyHash.Length };
            cancellationToken.ThrowIfCancellationRequested();
            staging.Position = 0;
            return new StagedFileCapture(
                staging, capturedMetadata,
                recordContentHash ? ContentFingerprint.FromSha256(copyHash.Hash) : null,
                copyHash.Hash.Length == 32 ? copyHash.Hash : null);
        }
        catch
        {
            await staging.DisposeAsync();
            throw;
        }
    }

    private async Task<HashedFile> CopyAsync(
        Stream source,
        Stream staging,
        long expectedLength,
        int attempt,
        Func<FileCopyProgress, ValueTask>? progress,
        CancellationToken cancellationToken,
        bool requireFullHash)
    {
        using var hasher = verifyStagedCopies || recordContentHash || requireFullHash
            ? IncrementalHash.CreateHash(HashAlgorithmName.SHA256) : null;
        var buffer = ArrayPool<byte>.Shared.Rent(tuning.CopyBufferKib * 1024);
        var clock = Stopwatch.StartNew();
        long length = 0;
        try
        {
            if (progress is not null)
                await progress(new FileCopyProgress(0, expectedLength, attempt));
            int read;
            while ((read = await source.ReadAsync(buffer, cancellationToken)) != 0)
            {
                hasher?.AppendData(buffer, 0, read);
                try
                {
                    await staging.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    throw new StagingStorageException("Could not write a temporary copy.", exception);
                }
                length = checked(length + read);
                if (progress is not null && length < expectedLength
                    && (length == read || clock.ElapsedMilliseconds >= tuning.ProgressIntervalMs))
                {
                    await progress(new FileCopyProgress(length, expectedLength, attempt));
                    clock.Restart();
                }
            }
            if (progress is not null)
                await progress(new FileCopyProgress(length, expectedLength, attempt));
            return new HashedFile(hasher?.GetHashAndReset() ?? [], length);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private async Task<HashedFile> HashAsync(
        Stream source,
        CancellationToken cancellationToken)
    {
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = ArrayPool<byte>.Shared.Rent(tuning.CopyBufferKib * 1024);
        long length = 0;
        try
        {
            int read;
            while ((read = await source.ReadAsync(buffer, cancellationToken)) != 0)
            {
                hasher.AppendData(buffer, 0, read);
                length = checked(length + read);
            }
            return new HashedFile(hasher.GetHashAndReset(), length);
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private readonly record struct HashedFile(byte[] Hash, long Length);

    private FileCaptureMetadata ReadPathMetadata(string path)
    {
        lock (metadataGate) return metadataReader.ReadPath(path);
    }

    private FileCaptureMetadata ReadHandleMetadata(SafeFileHandle handle)
    {
        lock (metadataGate) return metadataReader.ReadHandle(handle);
    }

    private sealed class StagingStorageException(string message, Exception innerException)
        : IOException(message, innerException);

    private static void EnsureEquivalent(
        string path,
        FileCaptureMetadata expected,
        FileCaptureMetadata actual,
        string reason)
    {
        if (!StringComparer.Ordinal.Equals(expected.Identity, actual.Identity)
            || expected.Length != actual.Length
            || expected.ModifiedUtc != actual.ModifiedUtc
            || expected.ChangedUtc != actual.ChangedUtc
            || expected.Attributes != actual.Attributes
            || (expected.Usn.HasValue && actual.Usn.HasValue && expected.Usn != actual.Usn))
        {
            throw new UnstableFileException(path, reason);
        }
    }
}
