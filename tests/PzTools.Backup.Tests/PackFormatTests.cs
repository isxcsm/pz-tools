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
