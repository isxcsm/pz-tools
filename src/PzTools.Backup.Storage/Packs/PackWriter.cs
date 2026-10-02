using System.Buffers;
using System.IO.Compression;
using System.Security.Cryptography;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Packs;

public sealed class PackWriter : IAsyncDisposable
{
    public const int CurrentFormatVersion = 1;

    private readonly string repositoryPath;
    private readonly string temporaryPath;
    private readonly string finalPath;
    private readonly FileStream stream;
    private readonly FileStream indexEntries;
    private int objectCount;
    private PackObjectDescriptor? lastObject;
    private bool sealedOrDisposed;
    private bool promoted;
    private bool preserveTemporary;
    private string? invalidReason;
    private readonly int compressionLevel;

    private PackWriter(
        string repositoryPath,
        long runIndex,
        Guid packId,
        string temporaryPath,
        string finalPath,
        FileStream stream,
        FileStream indexEntries,
        int compressionLevel)
    {
        this.repositoryPath = repositoryPath;
        this.compressionLevel = compressionLevel;
        RunIndex = runIndex;
        PackId = packId;
        this.temporaryPath = temporaryPath;
        this.finalPath = finalPath;
        this.stream = stream;
        this.indexEntries = indexEntries;
    }

    public Guid PackId { get; }

    public long RunIndex { get; }

    public int ObjectCount => objectCount;

    public FileStream CreateCaptureStagingStream()
    {
        ObjectDisposedException.ThrowIf(sealedOrDisposed, this);
        return new FileStream(
            Path.Combine(repositoryPath, "staging", $"capture-{Guid.NewGuid():N}.tmp"),
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.None,
            bufferSize: 128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan | FileOptions.DeleteOnClose);
    }

    public static async Task<PackWriter> CreateAsync(
        string repositoryPath,
        long runIndex,
        CancellationToken cancellationToken = default,
        int compressionLevel = StorageOptions.DefaultCompressionLevel)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);
        ArgumentOutOfRangeException.ThrowIfLessThan(compressionLevel, StorageOptions.MinimumCompressionLevel);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(compressionLevel, StorageOptions.MaximumCompressionLevel);
        var absoluteRepositoryPath = Path.GetFullPath(repositoryPath);
        var stagingPath = Path.Combine(absoluteRepositoryPath, "staging");
        var packsPath = Path.Combine(absoluteRepositoryPath, "packs");
        Directory.CreateDirectory(stagingPath);
        Directory.CreateDirectory(packsPath);

        var packId = Guid.NewGuid();
        var temporaryPath = Path.Combine(stagingPath, $"run-{runIndex}-{packId:N}.tmp");
        var finalPath = Path.Combine(packsPath, $"{packId:N}.pzpack");
        var indexPath = Path.Combine(stagingPath, $"run-{runIndex}-{packId:N}.idx.tmp");
        var stream = new FileStream(
            temporaryPath,
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.None,
            bufferSize: 128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var indexEntries = new FileStream(
            indexPath,
            FileMode.CreateNew,
            FileAccess.ReadWrite,
            FileShare.None,
            bufferSize: 64 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan | FileOptions.DeleteOnClose);
        var writer = new PackWriter(
            absoluteRepositoryPath,
            runIndex,
            packId,
            temporaryPath,
            finalPath,
            stream,
            indexEntries,
            compressionLevel);
        try
        {
            await writer.WriteHeaderAsync(cancellationToken);
            return writer;
        }
        catch
        {
            await writer.DisposeAsync();
            throw;
        }
    }

    public async Task<PackObjectDescriptor> AddObjectAsync(
        Stream source,
        ChecksumAlgorithm checksumAlgorithm,
        CompressionAlgorithm compressionAlgorithm,
        CancellationToken cancellationToken = default,
        Func<long, ValueTask>? progress = null) =>
        await AddObjectAsync(
            source,
            Guid.NewGuid(),
            checksumAlgorithm,
            compressionAlgorithm,
            cancellationToken, progress);

    internal async Task<PackObjectDescriptor> AddObjectAsync(
        Stream source,
        Guid objectId,
        ChecksumAlgorithm checksumAlgorithm,
        CompressionAlgorithm compressionAlgorithm,
        CancellationToken cancellationToken = default,
        Func<long, ValueTask>? progress = null)
    {
        ArgumentNullException.ThrowIfNull(source);
        ObjectDisposedException.ThrowIf(sealedOrDisposed, this);
        if (objectId == Guid.Empty)
        {
            throw new ArgumentException("Object id must be non-empty.", nameof(objectId));
        }

        _ = PackFormat.Encode(checksumAlgorithm);
        _ = PackFormat.Encode(compressionAlgorithm);

        var recordOffset = stream.Position;
        await stream.WriteAsync(new byte[PackFormat.ObjectHeaderSize], cancellationToken);
        var payloadOffset = stream.Position;

        long originalLength = 0;
        if (progress is not null) await progress(0);
        byte[] checksum;
        using (var hasher = ContentHasher.Create(checksumAlgorithm))
        {
            Stream payloadDestination = stream;
            BrotliStream? compressor = null;
            if (compressionAlgorithm == CompressionAlgorithm.Brotli)
            {
                compressor = new BrotliStream(stream, new BrotliCompressionOptions { Quality = compressionLevel }, leaveOpen: true);
                payloadDestination = compressor;
            }

            try
            {
                var buffer = ArrayPool<byte>.Shared.Rent(128 * 1024);
                try
                {
                    int read;
                    while ((read = await source.ReadAsync(buffer, cancellationToken)) != 0)
                    {
                        hasher.Append(buffer.AsSpan(0, read));
                        await payloadDestination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                        originalLength = checked(originalLength + read);
                        if (progress is not null) await progress(originalLength);
                    }
                }
                finally
                {
                    ArrayPool<byte>.Shared.Return(buffer);
                }
            }
            finally
            {
                if (compressor is not null)
                {
                    await compressor.DisposeAsync();
                }
            }

            checksum = hasher.Finish();
        }

        var endOffset = stream.Position;
        var storedLength = endOffset - payloadOffset;
        var descriptor = new PackObjectDescriptor(
            objectId,
            recordOffset,
            payloadOffset,
            originalLength,
            storedLength,
            checksumAlgorithm,
            checksum,
            compressionAlgorithm,
            Flags: 0);
        await WriteObjectHeaderAsync(descriptor, cancellationToken);
        stream.Position = endOffset;
        var indexEntry = new byte[PackFormat.IndexEntrySize];
        descriptor.ObjectId.TryWriteBytes(indexEntry.AsSpan(0, 16));
        PackFormat.WriteInt64(indexEntry.AsSpan(16, 8), descriptor.RecordOffset);
        await indexEntries.WriteAsync(indexEntry, cancellationToken);
        objectCount = checked(objectCount + 1);
        lastObject = descriptor;
        return descriptor;
    }

    public async Task<CommittedPack> SealAndPromoteAsync(
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(sealedOrDisposed, this);
        if (invalidReason is not null)
        {
            throw new InvalidOperationException($"Pack was invalidated: {invalidReason}");
        }

        sealedOrDisposed = true;
        try
        {
            await WriteIndexAndTrailerAsync(cancellationToken);
            await stream.FlushAsync(cancellationToken);
            stream.Flush(flushToDisk: true);
            await stream.DisposeAsync();
            await indexEntries.DisposeAsync();

            var validated = await PackReader.ValidateAsync(
                temporaryPath,
                verifyPayloads: true,
                cancellationToken);
            if (validated.PackId != PackId || validated.RunIndex != RunIndex)
            {
                throw new PackFormatException("Validated pack identity does not match its writer.");
            }

            File.Move(temporaryPath, finalPath, overwrite: false);
            promoted = true;
            return new CommittedPack(
                PackId,
                RunIndex,
                finalPath,
                Path.GetRelativePath(repositoryPath, finalPath).Replace('\\', '/'),
                new FileInfo(finalPath).Length,
                objectCount);
        }
        catch (Exception primaryFailure)
        {
            await stream.DisposeAsync();
            await indexEntries.DisposeAsync();
            try
            {
                DeleteTemporaryFile();
            }
            catch (Exception cleanupFailure) when (
                cleanupFailure is IOException or UnauthorizedAccessException)
            {
                throw new AggregateException(
                    "Pack sealing failed and its temporary file could not be removed.",
                    primaryFailure,
                    cleanupFailure);
            }

            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (!sealedOrDisposed)
        {
            sealedOrDisposed = true;
            await stream.DisposeAsync();
            await indexEntries.DisposeAsync();
        }

        if (!promoted && !preserveTemporary)
        {
            DeleteTemporaryFile();
        }
    }

    public async Task AbandonForCrashSimulationAsync()
    {
        preserveTemporary = true;
        if (!sealedOrDisposed)
        {
            sealedOrDisposed = true;
            await stream.DisposeAsync();
            await indexEntries.DisposeAsync();
        }
    }

    public void DiscardLastObject(PackObjectDescriptor descriptor)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        ObjectDisposedException.ThrowIf(sealedOrDisposed, this);
        if (objectCount == 0 || lastObject != descriptor)
        {
            throw new InvalidOperationException("Only the most recently written object can be discarded.");
        }

        stream.SetLength(descriptor.RecordOffset);
        stream.Position = descriptor.RecordOffset;
        objectCount--;
        indexEntries.SetLength(checked((long)objectCount * PackFormat.IndexEntrySize));
        indexEntries.Position = indexEntries.Length;
        lastObject = null;
    }

    public async Task CopyObjectToAsync(
        PackObjectDescriptor descriptor,
        Stream destination,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(descriptor);
        ArgumentNullException.ThrowIfNull(destination);
        ObjectDisposedException.ThrowIf(sealedOrDisposed, this);
        if (descriptor.RecordOffset < PackFormat.HeaderSize
            || descriptor.PayloadOffset != descriptor.RecordOffset + PackFormat.ObjectHeaderSize
            || descriptor.PayloadOffset + descriptor.StoredLength > stream.Length)
        {
            throw new ArgumentException("Object descriptor is outside the active pack.", nameof(descriptor));
        }

        var end = stream.Position;
        await stream.FlushAsync(cancellationToken);
        try
        {
            stream.Position = descriptor.PayloadOffset;
            using var bounded = new BoundedReadStream(stream, descriptor.StoredLength);
            Stream content = bounded;
            BrotliStream? decompressor = null;
            if (descriptor.CompressionAlgorithm == CompressionAlgorithm.Brotli)
            {
                decompressor = new BrotliStream(bounded, CompressionMode.Decompress, leaveOpen: true);
                content = decompressor;
            }

            try
            {
                var buffer = ArrayPool<byte>.Shared.Rent(128 * 1024);
                try
                {
                    int read;
                    while ((read = await content.ReadAsync(buffer, cancellationToken)) != 0)
                    {
                        await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                    }
                }
                finally
                {
                    ArrayPool<byte>.Shared.Return(buffer);
                }
            }
            finally
            {
                if (decompressor is not null)
                {
                    await decompressor.DisposeAsync();
                }
            }
        }
        finally
        {
            stream.Position = end;
        }
    }

    public void Invalidate(string reason)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reason);
        if (!sealedOrDisposed)
        {
            invalidReason ??= reason;
        }
    }

    private async Task WriteHeaderAsync(CancellationToken cancellationToken)
    {
        var header = new byte[PackFormat.HeaderSize];
        PackFormat.HeaderMagic.CopyTo(header);
        PackFormat.WriteInt32(header.AsSpan(8, 4), PackFormat.Version);
        PackId.TryWriteBytes(header.AsSpan(12, 16));
        PackFormat.WriteInt64(header.AsSpan(28, 8), RunIndex);
        await stream.WriteAsync(header, cancellationToken);
    }

    private async Task WriteObjectHeaderAsync(
        PackObjectDescriptor descriptor,
        CancellationToken cancellationToken)
    {
        if (descriptor.Checksum.Length > 32)
        {
            throw new InvalidOperationException("Object checksum exceeds the pack header capacity.");
        }

        var header = new byte[PackFormat.ObjectHeaderSize];
        PackFormat.ObjectMagic.CopyTo(header);
        descriptor.ObjectId.TryWriteBytes(header.AsSpan(4, 16));
        header[20] = PackFormat.Encode(descriptor.ChecksumAlgorithm);
        header[21] = PackFormat.Encode(descriptor.CompressionAlgorithm);
        PackFormat.WriteInt32(header.AsSpan(20, 4),
            header[20] | (header[21] << 8) | (descriptor.Flags << 16));
        PackFormat.WriteInt64(header.AsSpan(24, 8), descriptor.OriginalLength);
        PackFormat.WriteInt64(header.AsSpan(32, 8), descriptor.StoredLength);
        header[40] = checked((byte)descriptor.Checksum.Length);
        descriptor.Checksum.CopyTo(header, 48);

        var end = stream.Position;
        stream.Position = descriptor.RecordOffset;
        await stream.WriteAsync(header, cancellationToken);
        stream.Position = end;
    }

    private async Task WriteIndexAndTrailerAsync(CancellationToken cancellationToken)
    {
        var indexOffset = stream.Position;
        var header = new byte[PackFormat.IndexHeaderSize];
        PackFormat.IndexMagic.CopyTo(header);
        PackFormat.WriteInt32(header.AsSpan(8, 4), objectCount);
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hasher.AppendData(header);
        await stream.WriteAsync(header, cancellationToken);

        await indexEntries.FlushAsync(cancellationToken);
        indexEntries.Position = 0;
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
        try
        {
            int read;
            while ((read = await indexEntries.ReadAsync(buffer, cancellationToken)) != 0)
            {
                hasher.AppendData(buffer.AsSpan(0, read));
                await stream.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        await stream.WriteAsync(hasher.GetHashAndReset(), cancellationToken);

        var trailer = new byte[PackFormat.TrailerSize];
        PackFormat.TrailerMagic.CopyTo(trailer);
        PackFormat.WriteInt64(trailer.AsSpan(8, 8), indexOffset);
        await stream.WriteAsync(trailer, cancellationToken);
    }

    private void DeleteTemporaryFile()
    {
        if (File.Exists(temporaryPath))
        {
            File.Delete(temporaryPath);
        }
    }
}
