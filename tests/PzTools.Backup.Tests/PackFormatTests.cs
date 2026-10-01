using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;

namespace PzTools.Backup.Tests;

public sealed class PackFormatTests
{
    [Fact]
    public async Task EmptyPack_RoundTrips()
    {
        using var temp = new TempDirectory();
        await using var writer = await PackWriter.CreateAsync(temp.Path, runIndex: 1);

        var committed = await writer.SealAndPromoteAsync();
        await using var reader = await PackReader.OpenAsync(
            committed.FullPath,
            verifyPayloads: true);

        Assert.Equal(committed.PackId, reader.PackId);
        Assert.Equal(1, reader.RunIndex);
        Assert.Empty(reader.Objects);
        Assert.StartsWith("packs/", committed.RelativePath, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(ChecksumAlgorithm.None, CompressionAlgorithm.None)]
    [InlineData(ChecksumAlgorithm.XxHash64, CompressionAlgorithm.None)]
    [InlineData(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None)]
    [InlineData(ChecksumAlgorithm.None, CompressionAlgorithm.Brotli)]
    [InlineData(ChecksumAlgorithm.XxHash64, CompressionAlgorithm.Brotli)]
    [InlineData(ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli)]
    public async Task Object_RoundTripsWithEveryAlgorithmCombination(
        ChecksumAlgorithm checksum,
        CompressionAlgorithm compression)
    {
        using var temp = new TempDirectory();
        var content = Enumerable.Range(0, 300_000)
            .Select(index => (byte)(index % 251))
            .ToArray();
        await using var writer = await PackWriter.CreateAsync(temp.Path, runIndex: 10);
        await using var source = new MemoryStream(content, writable: false);
        var written = await writer.AddObjectAsync(source, checksum, compression);

        var committed = await writer.SealAndPromoteAsync();
        await using var reader = await PackReader.OpenAsync(
            committed.FullPath,
            verifyPayloads: true);
        await using var restored = new MemoryStream();
        await reader.CopyObjectToAsync(written.ObjectId, restored);

        Assert.Equal(content, restored.ToArray());
        Assert.Equal(checksum, Assert.Single(reader.Objects).ChecksumAlgorithm);
        Assert.Equal(compression, Assert.Single(reader.Objects).CompressionAlgorithm);
    }

    [Fact]
    public async Task CompressionLevel_ChangesTheStoredSizeOnly()
    {
        // Text-like content, as save files are: a higher level must store less and read back the same.
        var words = "zombie chunk square object tile room building vehicle player item ".Split(' ');
        var random = new Random(7);
        var content = System.Text.Encoding.ASCII.GetBytes(string.Join(' ',
            Enumerable.Range(0, 40_000).Select(_ => words[random.Next(words.Length)] + random.Next(100))));
        async Task<(long Stored, byte[] Restored)> StoreAtAsync(int level)
        {
            using var temp = new TempDirectory();
            await using var writer = await PackWriter.CreateAsync(temp.Path, runIndex: 1, compressionLevel: level);
            await using var source = new MemoryStream(content, writable: false);
            var written = await writer.AddObjectAsync(source, ChecksumAlgorithm.XxHash64, CompressionAlgorithm.Brotli);
            var committed = await writer.SealAndPromoteAsync();
            await using var reader = await PackReader.OpenAsync(committed.FullPath, verifyPayloads: true);
            await using var output = new MemoryStream();
            await reader.CopyObjectToAsync(written.ObjectId, output);
            return (written.StoredLength, output.ToArray());
        }

        var (fastest, fromFastest) = await StoreAtAsync(1);
        var (standard, fromStandard) = await StoreAtAsync(3);
        Assert.Equal(content, fromFastest);
        Assert.Equal(content, fromStandard);
        Assert.True(standard < fastest, $"level 3 stored {standard} bytes, level 1 {fastest}");
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() =>
            PackWriter.CreateAsync(Path.GetTempPath(), runIndex: 1, compressionLevel: 12));
    }

    [Fact]
    public async Task Reader_DetectsTruncatedPack()
    {
        using var temp = new TempDirectory();
        var committed = await CreatePackAsync(temp.Path, [1, 2, 3, 4]);
        await using (var file = new FileStream(
            committed.FullPath,
            FileMode.Open,
            FileAccess.Write,
            FileShare.None))
        {
            file.SetLength(file.Length - 5);
        }

        await Assert.ThrowsAsync<PackFormatException>(
            () => PackReader.OpenAsync(committed.FullPath, verifyPayloads: true));
    }

    [Fact]
    public async Task Reader_DetectsPayloadChecksumMismatch()
    {
        using var temp = new TempDirectory();
        var committed = await CreatePackAsync(temp.Path, [1, 2, 3, 4]);
        PackObjectDescriptor descriptor;
        await using (var reader = await PackReader.OpenAsync(committed.FullPath))
        {
            descriptor = Assert.Single(reader.Objects);
        }
        await using (var file = new FileStream(
            committed.FullPath,
            FileMode.Open,
            FileAccess.ReadWrite,
            FileShare.None))
        {
            file.Position = descriptor.PayloadOffset;
            var original = file.ReadByte();
            file.Position = descriptor.PayloadOffset;
            file.WriteByte((byte)(original ^ 0xff));
            file.Flush(flushToDisk: true);
        }

        await Assert.ThrowsAsync<PackFormatException>(
            () => PackReader.OpenAsync(committed.FullPath, verifyPayloads: true));
    }

    [Fact]
    public async Task LocatedOpen_SkipsOtherRecords_ButEachReadAndFullValidationStillCheckThem()
    {
        using var temp = new TempDirectory();
        await using var writer = await PackWriter.CreateAsync(temp.Path, runIndex: 1);
        var first = await writer.AddObjectAsync(new MemoryStream([1, 2, 3]), ChecksumAlgorithm.Sha256, CompressionAlgorithm.None);
        var second = await writer.AddObjectAsync(new MemoryStream([4, 5, 6]), ChecksumAlgorithm.Sha256, CompressionAlgorithm.None);
        var committed = await writer.SealAndPromoteAsync();
        await using (var file = new FileStream(committed.FullPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            file.Position = second.RecordOffset; // The second record's magic.
            file.WriteByte(0);
        }

        await Assert.ThrowsAsync<PackFormatException>(() => PackReader.ValidateAsync(committed.FullPath, verifyPayloads: false));
        await Assert.ThrowsAsync<PackFormatException>(() => PackReader.OpenForLocatedReadsAsync(committed.FullPath, Guid.NewGuid()));
        await using var reader = await PackReader.OpenForLocatedReadsAsync(committed.FullPath, committed.PackId);
        await using var restored = new MemoryStream();
        await reader.CopyObjectAtAsync(first.ObjectId, first.RecordOffset, restored);
        Assert.Equal([1, 2, 3], restored.ToArray());
        await Assert.ThrowsAsync<PackFormatException>(
            () => reader.CopyObjectAtAsync(second.ObjectId, second.RecordOffset, Stream.Null));
        await Assert.ThrowsAsync<PackFormatException>(
            () => reader.CopyObjectAtAsync(first.ObjectId, second.RecordOffset, Stream.Null));
    }

    [Fact]
    public async Task LocatedOpen_RejectsAnIndexWhoseRecordsAreOutOfOrder()
    {
        using var temp = new TempDirectory();
        await using var writer = await PackWriter.CreateAsync(temp.Path, runIndex: 1);
        await writer.AddObjectAsync(new MemoryStream([1, 2, 3]), ChecksumAlgorithm.Sha256, CompressionAlgorithm.None);
        await writer.AddObjectAsync(new MemoryStream([4, 5, 6]), ChecksumAlgorithm.Sha256, CompressionAlgorithm.None);
        var committed = await writer.SealAndPromoteAsync();
        await using (var file = new FileStream(committed.FullPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            // Swap the two index entries and rewrite the index checksum, so only the order is wrong.
            const int trailerSize = 16, indexHeaderSize = 12, entrySize = 24;
            var bytes = new byte[file.Length];
            file.ReadExactly(bytes);
            var indexOffset = BitConverter.ToInt64(bytes, bytes.Length - trailerSize + 8);
            var entries = (int)indexOffset + indexHeaderSize;
            var firstEntry = bytes.AsSpan(entries, entrySize).ToArray();
            bytes.AsSpan(entries + entrySize, entrySize).CopyTo(bytes.AsSpan(entries));
            firstEntry.CopyTo(bytes.AsSpan(entries + entrySize));
            var indexLength = indexHeaderSize + 2 * entrySize;
            System.Security.Cryptography.SHA256.HashData(bytes.AsSpan((int)indexOffset, indexLength))
                .CopyTo(bytes.AsSpan((int)indexOffset + indexLength));
            file.Position = 0;
            file.Write(bytes);
        }

        await Assert.ThrowsAsync<PackFormatException>(() => PackReader.OpenForLocatedReadsAsync(committed.FullPath, committed.PackId));
    }

    [Fact]
    public async Task CancelledSeal_LeavesNoTemporaryOrCommittedPack()
    {
        using var temp = new TempDirectory();
        await using var writer = await PackWriter.CreateAsync(temp.Path, runIndex: 1);
        await writer.AddObjectAsync(
            new MemoryStream([1, 2, 3]),
            ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => writer.SealAndPromoteAsync(cancellation.Token));

        Assert.Empty(Directory.EnumerateFiles(temp.GetPath("staging")));
        Assert.Empty(Directory.EnumerateFiles(temp.GetPath("packs")));
    }

    private static async Task<CommittedPack> CreatePackAsync(
        string repositoryPath,
        byte[] content)
    {
        await using var writer = await PackWriter.CreateAsync(repositoryPath, runIndex: 1);
        await writer.AddObjectAsync(
            new MemoryStream(content),
            ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None);
        return await writer.SealAndPromoteAsync();
    }
}
