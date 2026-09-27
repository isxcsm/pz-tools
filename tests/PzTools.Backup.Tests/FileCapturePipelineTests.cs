using System.Runtime.CompilerServices;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;

namespace PzTools.Backup.Tests;

public sealed class FileCapturePipelineTests
{
    [Theory]
    [InlineData(0)]
    [InlineData(1024)]
    public async Task Capture_BoundsPendingFiles_AndRestoresEveryObject_WithOneMemorySlot(int stagingKib)
    {
        using var temp = new TempDirectory();
        var paths = await CreateFilesAsync(temp, 48);
        var tuning = new BackupTuningOptions(SmallFileStagingKib: stagingKib,
            StagingMemoryMib: 1, CaptureReadConcurrency: 2, CaptureQueueCapacity: 16);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader(), tuning: tuning);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repo"), 1);
        var enumerated = 0;
        var consumed = 0;
        var expected = new Dictionary<Guid, byte[]>();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        await foreach (var prepared in FileCapturePipeline.PrepareAsync(
            Enumerate(paths, () => enumerated++), capturer, path => path,
            writer.CreateCaptureStagingStream, tuning, false, _ => { }, _ => ValueTask.CompletedTask, timeout.Token))
        {
            Assert.InRange(enumerated - consumed, 1, tuning.CaptureQueueCapacity);
            var staged = Assert.IsType<StagedFileCapture>(prepared.Staged);
            var stored = await staged.CaptureAsync(writer, ChecksumAlgorithm.XxHash64, CompressionAlgorithm.Brotli, timeout.Token);
            expected.Add(stored.Object.ObjectId, await File.ReadAllBytesAsync(prepared.Path, timeout.Token));
            consumed++;
        }
        Assert.Equal(paths.Length, consumed);
        var committed = await writer.SealAndPromoteAsync(timeout.Token);
        await using var reader = await PackReader.OpenAsync(committed.FullPath, verifyPayloads: true);
        foreach (var pair in expected)
        {
            await using var output = new MemoryStream();
            await reader.CopyObjectToAsync(pair.Key, output, timeout.Token);
            Assert.Equal(pair.Value, output.ToArray());
        }
        Assert.Empty(Directory.GetFiles(temp.GetPath("repo/staging")));
    }

    [Fact]
    public async Task Capture_ReadsOverlap_ButNeverExceedReaderLimit_AndEarlyDisposalCleansUp()
    {
        using var temp = new TempDirectory();
        var paths = await CreateFilesAsync(temp, 12);
        var tuning = new BackupTuningOptions(SmallFileStagingKib: 0,
            CaptureReadConcurrency: 2, CaptureQueueCapacity: 4);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader(), tuning: tuning);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repo"), 1);
        using var twoReaders = new CountdownEvent(2);
        using var release = new ManualResetEventSlim();
        var entered = 0;
        var enumerated = 0;
        FileStream CreateDisk()
        {
            var number = Interlocked.Increment(ref entered);
            if (number <= 2)
            {
                twoReaders.Signal();
                if (!release.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("Readers were not released.");
            }
            return writer.CreateCaptureStagingStream();
        }
        await using var iterator = FileCapturePipeline.PrepareAsync(
            Enumerate(paths, () => enumerated++), capturer, path => path,
            CreateDisk, tuning, false, _ => { }, _ => ValueTask.CompletedTask, CancellationToken.None).GetAsyncEnumerator();
        var first = iterator.MoveNextAsync().AsTask();
        try
        {
            Assert.True(await Task.Run(() => twoReaders.Wait(TimeSpan.FromSeconds(10))));
            Assert.Equal(2, Volatile.Read(ref entered));
            Assert.Equal(tuning.CaptureQueueCapacity, enumerated);
        }
        finally { release.Set(); }
        Assert.True(await first.WaitAsync(TimeSpan.FromSeconds(10)));
        var heldContent = iterator.Current.Staged!.Content;
        await iterator.DisposeAsync();
        Assert.False(heldContent.CanRead);
        Assert.Empty(Directory.GetFiles(temp.GetPath("repo/staging"), "capture-*.tmp"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Capture_ConsumerFailureOrCancellation_DrainsAllStagedCopies(bool cancel)
    {
        using var temp = new TempDirectory();
        var paths = await CreateFilesAsync(temp, 16);
        var tuning = new BackupTuningOptions(SmallFileStagingKib: 0);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader(), tuning: tuning);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repo"), 1);
        using var stop = new CancellationTokenSource();
        async Task Consume()
        {
            await foreach (var prepared in FileCapturePipeline.PrepareAsync(
                Enumerate(paths), capturer, path => path, writer.CreateCaptureStagingStream,
                tuning, false, _ => { }, _ => ValueTask.CompletedTask, stop.Token))
            {
                if (cancel)
                {
                    stop.Cancel();
                    stop.Token.ThrowIfCancellationRequested();
                }
                throw new InvalidOperationException("consumer failed");
            }
        }
        if (cancel) await Assert.ThrowsAnyAsync<OperationCanceledException>(Consume);
        else await Assert.ThrowsAsync<InvalidOperationException>(Consume);
        Assert.Empty(Directory.GetFiles(temp.GetPath("repo/staging"), "capture-*.tmp"));
    }

    [Fact]
    public async Task Capture_ReaderFailureReportsItsPath_AndClosesOtherCopies()
    {
        using var temp = new TempDirectory();
        var paths = await CreateFilesAsync(temp, 16);
        paths[5] = temp.GetPath("missing.bin");
        var tuning = new BackupTuningOptions(SmallFileStagingKib: 0);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader(), maxAttempts: 1, tuning: tuning);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repo"), 1);
        string? active = null;
        await Assert.ThrowsAsync<UnstableFileException>(async () =>
        {
            await foreach (var prepared in FileCapturePipeline.PrepareAsync(
                Enumerate(paths), capturer, path => path, writer.CreateCaptureStagingStream,
                tuning, false, path => active = path, _ => ValueTask.CompletedTask, CancellationToken.None))
                Assert.NotNull(prepared.Staged);
        });
        Assert.Equal(paths[5], active);
        Assert.Empty(Directory.GetFiles(temp.GetPath("repo/staging"), "capture-*.tmp"));
    }

    private static async Task<string[]> CreateFilesAsync(TempDirectory temp, int count)
    {
        var paths = new string[count];
        for (var index = 0; index < count; index++)
        {
            paths[index] = temp.GetPath($"source-{index}.bin");
            await File.WriteAllBytesAsync(paths[index], Enumerable.Repeat((byte)index, 4096).ToArray());
        }
        return paths;
    }

    private static async IAsyncEnumerable<string> Enumerate(string[] paths, Action? next = null,
        [EnumeratorCancellation] CancellationToken token = default)
    {
        foreach (var path in paths)
        {
            token.ThrowIfCancellationRequested();
            next?.Invoke();
            yield return path;
        }
        await Task.CompletedTask;
    }
}
