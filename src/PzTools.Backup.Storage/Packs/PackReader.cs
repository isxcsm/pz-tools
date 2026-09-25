using System.Buffers;
using System.IO.Compression;
using System.Security.Cryptography;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Packs;

public sealed class PackReader : IAsyncDisposable
{
    private readonly IReadOnlyDictionary<Guid, PackObjectDescriptor> objectMap;
    private readonly FileStream stream;
    private readonly SemaphoreSlim streamGate = new(1, 1);
    private readonly long indexOffset;
    private bool disposed;

    private PackReader(
        string path,
        Guid packId,
        long runIndex,
        IReadOnlyList<PackObjectDescriptor> objects,
        FileStream stream,
        long indexOffset)
    {
        Path = path;
        PackId = packId;
        RunIndex = runIndex;
        Objects = objects;
        objectMap = objects.ToDictionary(item => item.ObjectId);
        this.stream = stream;
        this.indexOffset = indexOffset;
    }

    public string Path { get; }

    public Guid PackId { get; }

    public long RunIndex { get; }

    public IReadOnlyList<PackObjectDescriptor> Objects { get; }

    public static Task<PackReader> OpenForLocatedReadsAsync(
        string path, Guid expectedPackId, CancellationToken cancellationToken = default) =>
        OpenLocatedAsync(path, expectedPackId, FileShare.ReadWrite | FileShare.Delete, cancellationToken);

    // Only for bounded operation-scoped reuse. Windows denies writers and path
    // replacement for the entire lifetime of this verified handle. Ordinary UI
    // readers retain their existing sharing behavior and are not put in this cache.
    public static Task<PackReader> OpenPinnedForLocatedReadsAsync(
        string path, Guid expectedPackId, CancellationToken cancellationToken = default) =>
        OpenLocatedAsync(path, expectedPackId, FileShare.Read, cancellationToken);

    private static async Task<PackReader> OpenLocatedAsync(
        string path, Guid expectedPackId, FileShare sharing, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        cancellationToken.ThrowIfCancellationRequested();
        var absolutePath = System.IO.Path.GetFullPath(path);
        FileStream? stream = null;
        try
        {
            stream = OpenFile(absolutePath, sharing);
            var validation = await ValidateStreamAsync(stream, verifyPayloads: false, cancellationToken);
            if (validation.PackId != expectedPackId)
                throw new PackFormatException("Pack identity does not match repository metadata.");
            var offset = await ReadTrailerAsync(stream, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            var reader = new PackReader(absolutePath, validation.PackId, validation.RunIndex, [], stream, offset);
            stream = null; // Transfer the exact validated handle, without a reopen race.
            return reader;
        }
        catch (PackFormatException) { throw; }
        catch (Exception exception) when (exception is IOException or InvalidDataException or OverflowException)
        {
            throw new PackFormatException($"Invalid pack '{absolutePath}'.", exception);
        }
        finally
        {
            if (stream is not null) await stream.DisposeAsync();
        }
    }

    public static async Task<PackValidationResult> ValidateAsync(
        string path, bool verifyPayloads = true, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var absolutePath = System.IO.Path.GetFullPath(path);
        try
        {
            await using var stream = OpenFile(absolutePath);
            return await ValidateStreamAsync(stream, verifyPayloads, cancellationToken);
        }
        catch (PackFormatException) { throw; }
        catch (Exception exception) when (exception is IOException or InvalidDataException or OverflowException)
        {
            throw new PackFormatException($"Invalid pack '{absolutePath}'.", exception);
        }
    }

    private static async Task<PackValidationResult> ValidateStreamAsync(
        FileStream stream, bool verifyPayloads, CancellationToken cancellationToken)
    {
        var (packId, runIndex) = await ReadHeaderAsync(stream, cancellationToken);
        var indexOffset = await ReadTrailerAsync(stream, cancellationToken);
        stream.Position = indexOffset;
        var indexHeader = new byte[PackFormat.IndexHeaderSize];
        await ReadExactlyAsync(stream, indexHeader, cancellationToken);
        if (!indexHeader.AsSpan(0, 8).SequenceEqual(PackFormat.IndexMagic))
        {
            throw new PackFormatException("Pack index magic is invalid.");
        }

        var count = PackFormat.ReadInt32(indexHeader.AsSpan(8, 4));
        if (count < 0)
        {
            throw new PackFormatException("Pack index has a negative object count.");
        }

        var expectedEnd = checked(
            indexOffset
            + PackFormat.IndexHeaderSize
            + checked((long)count * PackFormat.IndexEntrySize)
            + PackFormat.IndexChecksumSize
            + PackFormat.TrailerSize);
        if (expectedEnd != stream.Length)
        {
            throw new PackFormatException("Pack index length does not match the file length.");
        }

        using var indexHasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        indexHasher.AppendData(indexHeader);
        var expectedRecordOffset = (long)PackFormat.HeaderSize;
        var entryBytes = new byte[PackFormat.IndexEntrySize];
        for (var index = 0; index < count; index++)
        {
            await ReadExactlyAsync(stream, entryBytes, cancellationToken);
            indexHasher.AppendData(entryBytes);
            var nextIndexPosition = stream.Position;
            var objectId = new Guid(entryBytes.AsSpan(0, 16));
            var recordOffset = PackFormat.ReadInt64(entryBytes.AsSpan(16, 8));
            if (recordOffset != expectedRecordOffset)
            {
                throw new PackFormatException("Pack object records are not contiguous and ordered.");
            }

            var descriptor = await ReadObjectHeaderAsync(
                stream,
                objectId,
                recordOffset,
                indexOffset,
                cancellationToken);
            if (verifyPayloads)
            {
                await CopyDescriptorToAsync(
                    stream,
                    descriptor,
                    Stream.Null,
                    cancellationToken);
            }

            expectedRecordOffset = checked(
                descriptor.PayloadOffset + descriptor.StoredLength);
            stream.Position = nextIndexPosition;
        }

        if (expectedRecordOffset != indexOffset)
        {
            throw new PackFormatException("Pack data area length does not match its index.");
        }

        var storedChecksum = new byte[PackFormat.IndexChecksumSize];
        await ReadExactlyAsync(stream, storedChecksum, cancellationToken);
        if (!CryptographicOperations.FixedTimeEquals(
                indexHasher.GetHashAndReset(),
                storedChecksum))
        {
            throw new PackFormatException("Pack index checksum does not match.");
        }

        return new PackValidationResult(packId, runIndex, count);
    }

    public static async Task<PackReader> OpenAsync(
        string path,
        bool verifyPayloads = false,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        var absolutePath = System.IO.Path.GetFullPath(path);
        FileStream? stream = null;
        try
        {
            stream = OpenFile(absolutePath);
            if (stream.Length < PackFormat.HeaderSize + PackFormat.IndexHeaderSize
                + PackFormat.IndexChecksumSize + PackFormat.TrailerSize)
            {
                throw new PackFormatException("Pack is too short.");
            }

            var header = new byte[PackFormat.HeaderSize];
            await ReadExactlyAsync(stream, header, cancellationToken);
            if (!header.AsSpan(0, 8).SequenceEqual(PackFormat.HeaderMagic))
            {
                throw new PackFormatException("Pack header magic is invalid.");
            }

            var version = PackFormat.ReadInt32(header.AsSpan(8, 4));
            if (version != PackFormat.Version)
            {
                throw new PackFormatException($"Unsupported pack version {version}.");
            }

            var packId = new Guid(header.AsSpan(12, 16));
            var runIndex = PackFormat.ReadInt64(header.AsSpan(28, 8));
            var indexOffset = await ReadTrailerAsync(stream, cancellationToken);
            var index = await ReadIndexAsync(stream, indexOffset, cancellationToken);
            var objects = new List<PackObjectDescriptor>(index.Count);
            foreach (var item in index)
            {
                var descriptor = await ReadObjectHeaderAsync(
                    stream,
                    item.ObjectId,
                    item.RecordOffset,
                    indexOffset,
                    cancellationToken);
                objects.Add(descriptor);
            }

            var reader = new PackReader(
                absolutePath,
                packId,
                runIndex,
                objects,
                stream,
                indexOffset);
            stream = null;
            try
            {
                if (verifyPayloads)
                {
                    foreach (var descriptor in objects)
                    {
                        await reader.CopyObjectToAsync(
                            descriptor.ObjectId,
                            Stream.Null,
                            cancellationToken);
                    }
                }

                return reader;
            }
            catch
            {
                await reader.DisposeAsync();
                throw;
            }
        }
        catch (PackFormatException)
        {
            if (stream is not null)
            {
                await stream.DisposeAsync();
            }

            throw;
        }
        catch (Exception exception) when (
            exception is EndOfStreamException
            or IOException
            or InvalidDataException
            or OverflowException)
        {
            if (stream is not null)
            {
                await stream.DisposeAsync();
            }

            throw new PackFormatException($"Invalid pack '{absolutePath}'.", exception);
        }
    }

    public async Task CopyObjectToAsync(
        Guid objectId,
        Stream destination,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!objectMap.TryGetValue(objectId, out var descriptor))
        {
            throw new KeyNotFoundException($"Object {objectId} is not present in pack {PackId}.");
        }

        await streamGate.WaitAsync(cancellationToken);
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

            long length = 0;
            byte[] actualChecksum;
            using (var hasher = ContentHasher.Create(descriptor.ChecksumAlgorithm))
            {
                try
                {
                    var buffer = ArrayPool<byte>.Shared.Rent(128 * 1024);
                    try
                    {
                        int read;
                        while ((read = await content.ReadAsync(buffer, cancellationToken)) != 0)
                        {
                            hasher.Append(buffer.AsSpan(0, read));
                            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                            length = checked(length + read);
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

                actualChecksum = hasher.Finish();
            }

            if (length != descriptor.OriginalLength)
            {
                throw new PackFormatException(
                    $"Object {objectId} length is {length}, expected {descriptor.OriginalLength}.");
            }

            if (!CryptographicOperations.FixedTimeEquals(actualChecksum, descriptor.Checksum))
            {
                throw new PackFormatException($"Object {objectId} checksum does not match.");
            }
        }
        finally
        {
            streamGate.Release();
        }
    }

    public async Task<PackObjectDescriptor> RepackObjectAsync(
        Guid objectId,
        PackWriter destination,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!objectMap.TryGetValue(objectId, out var sourceDescriptor))
        {
            throw new KeyNotFoundException($"Object {objectId} is not present in pack {PackId}.");
        }

        await streamGate.WaitAsync(cancellationToken);
        try
        {
            stream.Position = sourceDescriptor.PayloadOffset;
            using var bounded = new BoundedReadStream(stream, sourceDescriptor.StoredLength);
            Stream content = bounded;
            BrotliStream? decompressor = null;
            if (sourceDescriptor.CompressionAlgorithm == CompressionAlgorithm.Brotli)
            {
                decompressor = new BrotliStream(bounded, CompressionMode.Decompress, leaveOpen: true);
                content = decompressor;
            }

            try
            {
                var repacked = await destination.AddObjectAsync(
                    content,
                    objectId,
                    sourceDescriptor.ChecksumAlgorithm,
                    sourceDescriptor.CompressionAlgorithm,
                    cancellationToken);
                if (repacked.OriginalLength != sourceDescriptor.OriginalLength
                    || !CryptographicOperations.FixedTimeEquals(
                        repacked.Checksum,
                        sourceDescriptor.Checksum))
                {
                    destination.DiscardLastObject(repacked);
                    throw new PackFormatException(
                        $"Object {objectId} changed while it was repacked.");
                }

                return repacked;
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
            streamGate.Release();
        }
    }

    public async Task<PackObjectDescriptor> RepackObjectAtAsync(
        Guid objectId,
        long recordOffset,
        PackWriter destination,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ObjectDisposedException.ThrowIf(disposed, this);
        await streamGate.WaitAsync(cancellationToken);
        try
        {
            var sourceDescriptor = await ReadObjectHeaderAsync(
                stream,
                objectId,
                recordOffset,
                indexOffset,
                cancellationToken);
            stream.Position = sourceDescriptor.PayloadOffset;
            using var bounded = new BoundedReadStream(stream, sourceDescriptor.StoredLength);
            Stream content = bounded;
            BrotliStream? decompressor = null;
            if (sourceDescriptor.CompressionAlgorithm == CompressionAlgorithm.Brotli)
            {
                decompressor = new BrotliStream(bounded, CompressionMode.Decompress, leaveOpen: true);
                content = decompressor;
            }

            try
            {
                var repacked = await destination.AddObjectAsync(
                    content,
                    objectId,
                    sourceDescriptor.ChecksumAlgorithm,
                    sourceDescriptor.CompressionAlgorithm,
                    cancellationToken);
                if (repacked.OriginalLength != sourceDescriptor.OriginalLength
                    || !CryptographicOperations.FixedTimeEquals(
                        repacked.Checksum,
                        sourceDescriptor.Checksum))
                {
                    destination.DiscardLastObject(repacked);
                    throw new PackFormatException(
                        $"Object {objectId} changed while it was repacked.");
                }

                return repacked;
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
            streamGate.Release();
        }
    }

    public async Task CopyObjectAtAsync(
        Guid objectId,
        long recordOffset,
        Stream destination,
        CancellationToken cancellationToken = default,
        Func<long, CancellationToken, Task>? progress = null)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ObjectDisposedException.ThrowIf(disposed, this);
        await streamGate.WaitAsync(cancellationToken);
        try
        {
            var descriptor = await ReadObjectHeaderAsync(
                stream,
                objectId,
                recordOffset,
                indexOffset,
                cancellationToken);
            await CopyDescriptorToAsync(stream, descriptor, destination, cancellationToken, progress);
        }
        finally
        {
            streamGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        await streamGate.WaitAsync();
        try
        {
            await stream.DisposeAsync();
        }
        finally
        {
            streamGate.Release();
            streamGate.Dispose();
        }
    }

    private static FileStream OpenFile(string path, FileShare sharing = FileShare.ReadWrite | FileShare.Delete)
    {
        return new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            sharing,
            bufferSize: 1,
            FileOptions.Asynchronous | FileOptions.RandomAccess);
    }

    private static async Task<(Guid PackId, long RunIndex)> ReadHeaderAsync(
        FileStream stream,
        CancellationToken cancellationToken)
    {
        if (stream.Length < PackFormat.HeaderSize + PackFormat.IndexHeaderSize
            + PackFormat.IndexChecksumSize + PackFormat.TrailerSize)
        {
            throw new PackFormatException("Pack is too short.");
        }

        stream.Position = 0;
        var header = new byte[PackFormat.HeaderSize];
        await ReadExactlyAsync(stream, header, cancellationToken);
        if (!header.AsSpan(0, 8).SequenceEqual(PackFormat.HeaderMagic))
        {
            throw new PackFormatException("Pack header magic is invalid.");
        }

        var version = PackFormat.ReadInt32(header.AsSpan(8, 4));
        if (version != PackFormat.Version)
        {
            throw new PackFormatException($"Unsupported pack version {version}.");
        }

        return (new Guid(header.AsSpan(12, 16)), PackFormat.ReadInt64(header.AsSpan(28, 8)));
    }

    private static async Task CopyDescriptorToAsync(
        FileStream stream,
        PackObjectDescriptor descriptor,
        Stream destination,
        CancellationToken cancellationToken,
        Func<long, CancellationToken, Task>? progress = null)
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

        long length = 0;
        byte[] actualChecksum;
        using (var hasher = ContentHasher.Create(descriptor.ChecksumAlgorithm))
        {
            try
            {
                var buffer = ArrayPool<byte>.Shared.Rent(128 * 1024);
                try
                {
                    int read;
                    while ((read = await content.ReadAsync(buffer, cancellationToken)) != 0)
                    {
                        hasher.Append(buffer.AsSpan(0, read));
                        await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                        length = checked(length + read);
                        if (progress is not null) await progress(length, cancellationToken);
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

            actualChecksum = hasher.Finish();
        }

        if (length != descriptor.OriginalLength)
        {
            throw new PackFormatException(
                $"Object {descriptor.ObjectId} length is {length}, expected {descriptor.OriginalLength}.");
        }

        if (!CryptographicOperations.FixedTimeEquals(actualChecksum, descriptor.Checksum))
        {
            throw new PackFormatException(
                $"Object {descriptor.ObjectId} checksum does not match.");
        }
    }

    private static async Task<long> ReadTrailerAsync(
        FileStream stream,
        CancellationToken cancellationToken)
    {
        stream.Position = stream.Length - PackFormat.TrailerSize;
        var trailer = new byte[PackFormat.TrailerSize];
        await ReadExactlyAsync(stream, trailer, cancellationToken);
        if (!trailer.AsSpan(0, 8).SequenceEqual(PackFormat.TrailerMagic))
        {
            throw new PackFormatException("Pack trailer magic is invalid.");
        }

        var indexOffset = PackFormat.ReadInt64(trailer.AsSpan(8, 8));
        if (indexOffset < PackFormat.HeaderSize
            || indexOffset > stream.Length - PackFormat.TrailerSize - PackFormat.IndexChecksumSize)
        {
            throw new PackFormatException("Pack index offset is outside the file.");
        }

        return indexOffset;
    }

    private static async Task<IReadOnlyList<PackIndexEntry>> ReadIndexAsync(
        FileStream stream,
        long indexOffset,
        CancellationToken cancellationToken)
    {
        stream.Position = indexOffset;
        var indexHeader = new byte[PackFormat.IndexHeaderSize];
        await ReadExactlyAsync(stream, indexHeader, cancellationToken);
        if (!indexHeader.AsSpan(0, 8).SequenceEqual(PackFormat.IndexMagic))
        {
            throw new PackFormatException("Pack index magic is invalid.");
        }

        var count = PackFormat.ReadInt32(indexHeader.AsSpan(8, 4));
        if (count < 0)
        {
            throw new PackFormatException("Pack index has a negative object count.");
        }

        var entriesLength = checked(count * PackFormat.IndexEntrySize);
        var expectedEnd = checked(
            indexOffset
            + PackFormat.IndexHeaderSize
            + entriesLength
            + PackFormat.IndexChecksumSize
            + PackFormat.TrailerSize);
        if (expectedEnd != stream.Length)
        {
            throw new PackFormatException("Pack index length does not match the file length.");
        }

        var entriesBytes = new byte[entriesLength];
        await ReadExactlyAsync(stream, entriesBytes, cancellationToken);
        var storedChecksum = new byte[PackFormat.IndexChecksumSize];
        await ReadExactlyAsync(stream, storedChecksum, cancellationToken);

        var indexBytes = new byte[PackFormat.IndexHeaderSize + entriesLength];
        indexHeader.CopyTo(indexBytes, 0);
        entriesBytes.CopyTo(indexBytes, PackFormat.IndexHeaderSize);
        if (!CryptographicOperations.FixedTimeEquals(
            SHA256.HashData(indexBytes),
            storedChecksum))
        {
            throw new PackFormatException("Pack index checksum does not match.");
        }

        var entries = new List<PackIndexEntry>(count);
        var objectIds = new HashSet<Guid>();
        for (var index = 0; index < count; index++)
        {
            var offset = index * PackFormat.IndexEntrySize;
            var objectId = new Guid(entriesBytes.AsSpan(offset, 16));
            var recordOffset = PackFormat.ReadInt64(entriesBytes.AsSpan(offset + 16, 8));
            if (!objectIds.Add(objectId))
            {
                throw new PackFormatException($"Duplicate object id {objectId} in pack index.");
            }

            entries.Add(new PackIndexEntry(objectId, recordOffset));
        }

        return entries;
    }

    private static async Task<PackObjectDescriptor> ReadObjectHeaderAsync(
        FileStream stream,
        Guid expectedObjectId,
        long recordOffset,
        long indexOffset,
        CancellationToken cancellationToken)
    {
        if (recordOffset < PackFormat.HeaderSize
            || recordOffset > indexOffset - PackFormat.ObjectHeaderSize)
        {
            throw new PackFormatException("Object record offset is outside the data area.");
        }

        stream.Position = recordOffset;
        var header = new byte[PackFormat.ObjectHeaderSize];
        await ReadExactlyAsync(stream, header, cancellationToken);
        if (!header.AsSpan(0, 4).SequenceEqual(PackFormat.ObjectMagic))
        {
            throw new PackFormatException("Object record magic is invalid.");
        }

        var objectId = new Guid(header.AsSpan(4, 16));
        if (objectId != expectedObjectId)
        {
            throw new PackFormatException("Object record identity differs from its index entry.");
        }

        var checksumAlgorithm = PackFormat.DecodeChecksum(header[20]);
        var compressionAlgorithm = PackFormat.DecodeCompression(header[21]);
        var flags = header[22] | (header[23] << 8);
        var originalLength = PackFormat.ReadInt64(header.AsSpan(24, 8));
        var storedLength = PackFormat.ReadInt64(header.AsSpan(32, 8));
        var checksumLength = header[40];
        if (originalLength < 0 || storedLength < 0 || checksumLength > 32)
        {
            throw new PackFormatException("Object lengths are invalid.");
        }

        var expectedChecksumLength = checksumAlgorithm switch
        {
            ChecksumAlgorithm.None => 0,
            ChecksumAlgorithm.XxHash64 => 8,
            ChecksumAlgorithm.Sha256 => 32,
            _ => throw new PackFormatException("Unsupported checksum algorithm."),
        };
        if (checksumLength != expectedChecksumLength)
        {
            throw new PackFormatException("Object checksum length is invalid.");
        }

        var payloadOffset = checked(recordOffset + PackFormat.ObjectHeaderSize);
        if (storedLength > indexOffset - payloadOffset)
        {
            throw new PackFormatException("Object payload extends into the pack index.");
        }

        return new PackObjectDescriptor(
            objectId,
            recordOffset,
            payloadOffset,
            originalLength,
            storedLength,
            checksumAlgorithm,
            header.AsSpan(48, checksumLength).ToArray(),
            compressionAlgorithm,
            flags);
    }

    private static async Task ReadExactlyAsync(
        Stream stream,
        Memory<byte> buffer,
        CancellationToken cancellationToken)
    {
        await stream.ReadExactlyAsync(buffer, cancellationToken);
    }

    private sealed record PackIndexEntry(Guid ObjectId, long RecordOffset);
}
