using Microsoft.Win32.SafeHandles;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;

namespace PzTools.Backup.Tests;

public sealed class StableFileCapturerTests
{
    [Theory]
    [InlineData(true, true)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(false, false)]
    public async Task Capture_ComparisonHashIsIndependentOfCopyVerificationAndPackChecksum(
        bool recordContentHash, bool verifyStagedCopies)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        byte[] content = [1, 2, 3, 4];
        await File.WriteAllBytesAsync(path, content);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader(),
            verifyStagedCopies: verifyStagedCopies, recordContentHash: recordContentHash);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);
        var result = await capturer.CaptureAsync(path, writer,
            ChecksumAlgorithm.Sha256, CompressionAlgorithm.None);
        var expected = System.Security.Cryptography.SHA256.HashData(content);
        Assert.Equal(expected, result.Object.Checksum);
        Assert.Equal(recordContentHash ? expected : null, result.ContentHash);
        Assert.Equal(recordContentHash ? "Sha256" : null, result.ContentHashAlgorithm);
        Assert.Equal(content, await ReadCapturedAsync(writer, result));
    }

    [Fact]
    public async Task Capture_WithWindowsMetadata_PreservesBytesAndSourceMetadata()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source.bin");
        var content = Enumerable.Range(0, 10_000).Select(value => (byte)(value % 251)).ToArray();
        await File.WriteAllBytesAsync(sourcePath, content);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader());
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);

        var result = await capturer.CaptureAsync(
            sourcePath,
            writer,
            ChecksumAlgorithm.XxHash64,
            CompressionAlgorithm.Brotli);
        var committed = await writer.SealAndPromoteAsync();
        await using var reader = await PackReader.OpenAsync(
            committed.FullPath,
            verifyPayloads: true);
        await using var restored = new MemoryStream();
        await reader.CopyObjectToAsync(result.Object.ObjectId, restored);

        Assert.Equal(content, restored.ToArray());
        Assert.Equal(content.Length, result.SourceMetadata.Length);
        Assert.False(string.IsNullOrWhiteSpace(result.SourceMetadata.Identity));
        Assert.NotEqual(default, result.SourceMetadata.ModifiedUtc);
    }

    [Fact]
    public async Task Capture_KeepsCompleteCopyWhenSourceChangesAfterCopy()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source.bin");
        byte[] original = [1, 2, 3, 4];
        await File.WriteAllBytesAsync(sourcePath, original);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader());
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);
        var changed = false;

        var result = await capturer.CaptureAsync(
            sourcePath, writer, ChecksumAlgorithm.Sha256, CompressionAlgorithm.None,
            progress: async copy =>
            {
                if (copy.CopiedBytes != original.Length || changed) return;
                changed = true;
                await WriteSharedAsync(sourcePath, [5, 6, 7, 8]);
            });

        Assert.True(changed);
        Assert.Equal(original, await ReadCapturedAsync(writer, result));
    }

    [Fact]
    public async Task Capture_AcceptsCopyMatchingSecondSourceHash()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source.bin");
        await File.WriteAllBytesAsync(sourcePath, [1, 2, 3, 4]);
        byte[] updated = [5, 6, 7, 8];
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader());
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);
        var changed = false;

        var result = await capturer.CaptureAsync(
            sourcePath, writer, ChecksumAlgorithm.Sha256, CompressionAlgorithm.None,
            progress: async copy =>
            {
                if (copy.CopiedBytes != 0 || changed) return;
                changed = true;
                await WriteSharedAsync(sourcePath, updated);
            });

        Assert.True(changed);
        Assert.Equal(updated, await ReadCapturedAsync(writer, result));
    }

    [Fact]
    public async Task Capture_AcceptsMatchingCopyDespiteMetadataChangingDuringFirstHash()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source.bin");
        byte[] content = [1, 2, 3, 4];
        await File.WriteAllBytesAsync(sourcePath, content);
        var before = Metadata("same-file", content.Length, second: 1);
        var after = before with { ChangedUtc = before.ChangedUtc.AddTicks(1) };
        var metadata = new FakeMetadataReader([before, after], [before, after]);
        var capturer = new StableFileCapturer(metadata, maxAttempts: 1);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);

        var result = await capturer.CaptureAsync(
            sourcePath, writer, ChecksumAlgorithm.Sha256, CompressionAlgorithm.None);

        Assert.Equal(content, await ReadCapturedAsync(writer, result));
        Assert.Equal(before, result.SourceMetadata);
    }

    [Fact]
    public async Task Capture_RetriesMixedCopyBeforeWritingPack()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source.bin");
        var original = Enumerable.Repeat((byte)1, 512 * 1024).ToArray();
        var updated = Enumerable.Repeat((byte)2, original.Length).ToArray();
        await File.WriteAllBytesAsync(sourcePath, original);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader());
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);
        var changed = false;
        var attempts = new HashSet<int>();

        var result = await capturer.CaptureAsync(
            sourcePath, writer, ChecksumAlgorithm.Sha256, CompressionAlgorithm.None,
            progress: async copy =>
            {
                attempts.Add(copy.Attempt);
                if (copy.Attempt != 1 || copy.CopiedBytes != 128 * 1024 || changed) return;
                changed = true;
                await WriteSharedAsync(sourcePath, updated);
            });

        Assert.True(changed);
        Assert.Equal([1, 2], attempts.Order().ToArray());
        Assert.Equal(updated, await ReadCapturedAsync(writer, result));
    }

    [Fact]
    public async Task Capture_ExhaustedRetriesInvalidatesPackWithoutCommittedObject()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source.bin");
        const int chunk = 128 * 1024;
        await File.WriteAllBytesAsync(sourcePath,
            Enumerable.Repeat((byte)1, 4 * chunk).ToArray());
        var capturer = new StableFileCapturer(
            new WindowsFileMetadataReader(), maxAttempts: 2);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);
        var changedAttempts = new List<int>();

        await Assert.ThrowsAsync<UnstableFileException>(() => capturer.CaptureAsync(
            sourcePath, writer, ChecksumAlgorithm.Sha256, CompressionAlgorithm.None,
            progress: async copy =>
            {
                if (copy.CopiedBytes != chunk || changedAttempts.Contains(copy.Attempt)) return;
                changedAttempts.Add(copy.Attempt);
                await WriteSharedAsync(sourcePath,
                    Enumerable.Repeat((byte)(copy.Attempt + 1), 4 * chunk).ToArray());
            }));

        Assert.Equal([1, 2], changedAttempts);
        Assert.Equal(0, writer.ObjectCount);
        await Assert.ThrowsAsync<InvalidOperationException>(() => writer.SealAndPromoteAsync());
    }

    [Theory]
    [InlineData("overwrite")]
    [InlineData("append")]
    [InlineData("truncate")]
    [InlineData("replacement")]
    public async Task Capture_DetectsMetadataRacesAndInvalidatesPack(string race)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source.bin");
        await File.WriteAllBytesAsync(sourcePath, [1, 2, 3, 4]);
        var baseline = Metadata("identity-a", 4, second: 1);
        var changed = race switch
        {
            "overwrite" => baseline with { ChangedUtc = baseline.ChangedUtc.AddTicks(1) },
            "append" => baseline with { Length = 5 },
            "truncate" => baseline with { Length = 3 },
            "replacement" => baseline with { Identity = "identity-b" },
            _ => throw new InvalidOperationException(),
        };
        var metadata = race == "replacement"
            ? new FakeMetadataReader([baseline, changed], [baseline, baseline])
            : new FakeMetadataReader([baseline, baseline], [baseline, changed]);
        var capturer = new StableFileCapturer(metadata, verifyStagedCopies: false, maxAttempts: 1);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);

        await Assert.ThrowsAsync<UnstableFileException>(() => capturer.CaptureAsync(
            sourcePath,
            writer,
            ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => writer.SealAndPromoteAsync());
        Assert.Empty(Directory.EnumerateFiles(temp.GetPath("repository", "packs")));
    }

    [Theory]
    [InlineData(typeof(FileNotFoundException))]
    [InlineData(typeof(UnauthorizedAccessException))]
    public async Task Capture_TreatsDisappearanceAndAccessFailureAsRunFailure(Type exceptionType)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source.bin");
        await File.WriteAllBytesAsync(sourcePath, [1, 2, 3, 4]);
        var baseline = Metadata("identity-a", 4, second: 1);
        var metadata = new FakeMetadataReader(
            [
                baseline,
                (Func<Exception>)(() =>
                    (Exception)Activator.CreateInstance(exceptionType, "test")!),
            ],
            [baseline, baseline]);
        var capturer = new StableFileCapturer(metadata, verifyStagedCopies: false, maxAttempts: 1);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);

        var exception = await Assert.ThrowsAsync<UnstableFileException>(() =>
            capturer.CaptureAsync(
                sourcePath,
                writer,
                ChecksumAlgorithm.Sha256,
                CompressionAlgorithm.None));

        Assert.Equal("file access failed", exception.Reason);
        await Assert.ThrowsAsync<InvalidOperationException>(() => writer.SealAndPromoteAsync());
    }

    private static FileCaptureMetadata Metadata(string identity, long length, int second)
    {
        var time = new DateTimeOffset(2026, 1, 1, 0, 0, second, TimeSpan.Zero);
        return new FileCaptureMetadata(
            identity,
            length,
            time,
            time,
            FileAttributes.Normal,
            Usn: null);
    }

    private static async Task WriteSharedAsync(string path, byte[] content)
    {
        await using var writer = new FileStream(path, FileMode.Open, FileAccess.Write,
            FileShare.ReadWrite | FileShare.Delete, 128 * 1024, FileOptions.Asynchronous);
        await writer.WriteAsync(content);
        await writer.FlushAsync();
    }

    private static async Task<byte[]> ReadCapturedAsync(
        PackWriter writer, StableFileCaptureResult captured)
    {
        var committed = await writer.SealAndPromoteAsync();
        await using var reader = await PackReader.OpenAsync(committed.FullPath, verifyPayloads: true);
        await using var restored = new MemoryStream();
        await reader.CopyObjectToAsync(captured.Object.ObjectId, restored);
        return restored.ToArray();
    }

    private sealed class FakeMetadataReader(
        IEnumerable<object> pathResults,
        IEnumerable<object> handleResults) : IFileMetadataReader
    {
        private readonly Queue<object> pathResults = new(pathResults);
        private readonly Queue<object> handleResults = new(handleResults);

        public FileCaptureMetadata ReadPath(string path) => Read(pathResults);

        public FileCaptureMetadata ReadHandle(SafeFileHandle handle) => Read(handleResults);

        private static FileCaptureMetadata Read(Queue<object> results)
        {
            var value = results.Dequeue();
            if (value is Func<Exception> exceptionFactory)
            {
                throw exceptionFactory();
            }

            return (FileCaptureMetadata)value;
        }
    }
}
