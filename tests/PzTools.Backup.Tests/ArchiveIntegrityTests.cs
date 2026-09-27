using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using PzTools.Zomboid.Archive;

namespace PzTools.Backup.Tests;

public sealed class ArchiveIntegrityTests
{
    private const string Prefix = "Sandbox/Integrity/";

    [Fact]
    public async Task Import_RejectsChangedStoredPayloadWithoutPublishingSave()
    {
        using var temp = new TempDirectory();
        var archive = temp.GetPath("save.zip");
        var content = "unique chunk payload for corruption regression"u8.ToArray();
        await CreateArchiveAsync(archive, CompressionLevel.NoCompression, content);
        var bytes = await File.ReadAllBytesAsync(archive);
        var offset = bytes.AsSpan().IndexOf(content);
        Assert.True(offset >= 0);
        bytes[offset] ^= 1; // Keep both the declared length and the original CRC intact.
        await File.WriteAllBytesAsync(archive, bytes);

        await AssertRejectedWithoutPublishingAsync(archive, temp.GetPath("Saves"));
    }

    [Theory]
    [InlineData(CompressionLevel.NoCompression, 0, "map.bin")]
    [InlineData(CompressionLevel.Optimal, 0, "map.bin")]
    [InlineData(CompressionLevel.NoCompression, 100000, "map.bin")]
    [InlineData(CompressionLevel.Optimal, 100000, "map.bin")]
    [InlineData(CompressionLevel.NoCompression, 1, "pztools-manifest.json")]
    [InlineData(CompressionLevel.Optimal, 1, "pztools-manifest.json")]
    public async Task Import_RejectsIncorrectCrcIncludingEmptyFilesAndManifest(
        CompressionLevel compression, int length, string entryName)
    {
        using var temp = new TempDirectory();
        var archive = temp.GetPath("save.zip");
        await CreateArchiveAsync(archive, compression, new byte[length]);
        var bytes = await File.ReadAllBytesAsync(archive);
        CorruptCentralDirectoryCrc(bytes, Prefix + entryName);
        await File.WriteAllBytesAsync(archive, bytes);

        await AssertRejectedWithoutPublishingAsync(archive, temp.GetPath("Saves"));
    }

    private static async Task AssertRejectedWithoutPublishingAsync(string archive, string saves)
    {
        // An existing save must also remain untouched when the import fails.
        var existing = Path.Combine(saves, "Sandbox", "Existing");
        Directory.CreateDirectory(existing);
        var original = Path.Combine(existing, "players.db");
        await File.WriteAllTextAsync(original, "original");
        var error = await Assert.ThrowsAsync<InvalidDataException>(() =>
            new ZomboidArchiveService().ImportAsync(archive, saves));
        Assert.Contains("CRC-32", error.Message);
        Assert.Equal("original", await File.ReadAllTextAsync(original));
        Assert.Equal([existing], Directory.GetDirectories(Path.Combine(saves, "Sandbox")));
        Assert.Empty(Directory.GetDirectories(saves, ".pztools-import-*"));
    }

    private static async Task CreateArchiveAsync(string path, CompressionLevel compression, byte[] content)
    {
        await using var stream = File.Create(path);
        using var archive = new ZipArchive(stream, ZipArchiveMode.Create);
        await using (var player = archive.CreateEntry(Prefix + "players.db", compression).Open())
            await player.WriteAsync("player"u8.ToArray());
        await using (var chunk = archive.CreateEntry(Prefix + "map.bin", compression).Open())
            await chunk.WriteAsync(content);
        await using var manifest = archive.CreateEntry(Prefix + ZomboidArchiveService.ManifestEntryName, compression).Open();
        await JsonSerializer.SerializeAsync(manifest, new ZomboidArchiveManifest(
            ZomboidArchiveService.FormatMarker, 2, "Sandbox/Integrity", "Sandbox", "Integrity",
            null, 0, 0, DateTimeOffset.UtcNow));
    }

    private static void CorruptCentralDirectoryCrc(byte[] bytes, string entryName)
    {
        var end = bytes.AsSpan().LastIndexOf(new byte[] { 0x50, 0x4b, 0x05, 0x06 });
        Assert.True(end >= 0);
        var offset = checked((int)BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(end + 16)));
        while (BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset)) == 0x02014b50)
        {
            var nameLength = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset + 28));
            var extraLength = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset + 30));
            var commentLength = BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset + 32));
            if (Encoding.UTF8.GetString(bytes, offset + 46, nameLength) == entryName)
            {
                bytes[offset + 16] ^= 1;
                return;
            }
            offset += 46 + nameLength + extraLength + commentLength;
        }
        throw new InvalidOperationException("Fixture entry was not found in the ZIP central directory.");
    }
}
