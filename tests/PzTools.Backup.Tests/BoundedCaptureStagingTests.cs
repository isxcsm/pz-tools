using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;

namespace PzTools.Backup.Tests;

public sealed class BoundedCaptureStagingTests
{
    [Fact]
    public async Task Pool_CountsRetainedCapacityWaitsAndReturnsCancelledSlots()
    {
        var pool = new BoundedStagingBufferPool(bufferSize: 37, maximumBytes: 100);
        using var first = await pool.RentAsync(default);
        using var second = await pool.RentAsync(default);
        Assert.Equal(74, pool.AllocatedBytes);
        Assert.Equal(74, pool.LeasedBytes);

        using var cancellation = new CancellationTokenSource();
        var cancelledWaiter = pool.RentAsync(cancellation.Token).AsTask();
        Assert.False(cancelledWaiter.IsCompleted);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelledWaiter);
        Assert.Equal(74, pool.AllocatedBytes);
        Assert.Equal(74, pool.LeasedBytes);

        var waiter = pool.RentAsync(default).AsTask();
        Assert.False(waiter.IsCompleted);
        first.Dispose();
        using var reused = await waiter.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Same(first.Buffer, reused.Buffer);
        first.Dispose();
        Assert.Equal(74, pool.AllocatedBytes);
        Assert.Equal(74, pool.LeasedBytes);
        reused.Dispose();
        second.Dispose();
        Assert.Equal(0, pool.LeasedBytes);
        Assert.Equal(74, pool.AllocatedBytes);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(8193)]
    [InlineData(256 * 1024)]
    public async Task Stage_SmallFilesKeepPrivateVerifiedCopyWithoutTemporaryFile(int length)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        var content = CreateContent(length);
        await File.WriteAllBytesAsync(path, content);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader());
        await using var staged = await capturer.StageAsync(path,
            () => throw new InvalidOperationException("A small file must not create disk staging."));

        var memory = Assert.IsType<SpillableCaptureStream>(staged.Content);
        Assert.False(memory.IsSpilled);
        Assert.Equal(SHA256.HashData(content), staged.FullSha256.ToArray());
        Assert.Equal(content, await ReadAllAsync(staged.Content));
        Assert.Equal(256 * 1024, capturer.LeasedStagingBytes);
        await staged.DisposeAsync();
        await staged.DisposeAsync();
        Assert.Equal(0, capturer.LeasedStagingBytes);
    }

    [Theory]
    [InlineData(256, 256 * 1024 + 1)]
    [InlineData(0, 128)]
    public async Task Stage_LargeOrDiskOnlyFilesUseTemporaryFileAndDeleteOnDispose(int thresholdKib, int length)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        var diskPath = temp.GetPath("capture.tmp");
        var content = CreateContent(length);
        await File.WriteAllBytesAsync(path, content);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader(),
            tuning: new BackupTuningOptions(SmallFileStagingKib: thresholdKib));
        await using var staged = await capturer.StageAsync(path, () => CreateDisk(diskPath));

        Assert.IsType<FileStream>(staged.Content);
        Assert.Equal(content, await ReadAllAsync(staged.Content));
        Assert.Equal(SHA256.HashData(content), staged.FullSha256.ToArray());
        Assert.Equal(0, capturer.AllocatedStagingBytes);
        Assert.True(File.Exists(diskPath));
        await staged.DisposeAsync();
        Assert.False(File.Exists(diskPath));
    }

    [Fact]
    public async Task Stage_GrowingFileSpillsAndReleasesMemoryBeforeDisposal()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        var diskPath = temp.GetPath("capture.tmp");
        await File.WriteAllBytesAsync(path, CreateContent(128 * 1024));
        var updated = CreateContent(384 * 1024);
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader());
        var changed = false;
        var diskCreations = 0;
        await using var staged = await capturer.StageAsync(path,
            () => { diskCreations++; return CreateDisk(diskPath); },
            progress: async copy =>
            {
                if (copy.CopiedBytes != 0 || changed) return;
                changed = true;
                await WriteSharedAsync(path, updated);
            });

        Assert.True(changed);
        Assert.True(Assert.IsType<SpillableCaptureStream>(staged.Content).IsSpilled);
        Assert.Equal(1, diskCreations);
        Assert.Equal(updated.Length, staged.SourceMetadata.Length);
        Assert.Equal(SHA256.HashData(updated), staged.FullSha256.ToArray());
        Assert.Equal(updated, await ReadAllAsync(staged.Content));
        Assert.Equal(0, capturer.LeasedStagingBytes);
        await staged.DisposeAsync();
        Assert.False(File.Exists(diskPath));
    }

    [Fact]
    public async Task Stage_FailedSpillIsNotRetriedAndReturnsLease()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        await File.WriteAllBytesAsync(path, CreateContent(128));
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader());
        var attempts = 0;
        var diskCreations = 0;
        await Assert.ThrowsAnyAsync<IOException>(() => capturer.StageAsync(path,
            () => { diskCreations++; throw new IOException("disk full"); },
            progress: async copy =>
            {
                if (copy.CopiedBytes != 0) return;
                attempts++;
                await WriteSharedAsync(path, CreateContent(256 * 1024 + 1));
            }));

        Assert.Equal(1, attempts);
        Assert.Equal(1, diskCreations);
        Assert.Equal(0, capturer.LeasedStagingBytes);
    }

    [Fact]
    public async Task Stage_QueuedCopyHoldsBudgetUntilDisposedAndWaitingCaptureCanCancel()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        await File.WriteAllBytesAsync(path, CreateContent(16));
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader(),
            tuning: new BackupTuningOptions(SmallFileStagingKib: 1024, StagingMemoryMib: 1));
        Func<FileStream> disk = () => throw new InvalidOperationException("Unexpected spill.");
        await using var first = await capturer.StageAsync(path, disk);
        Assert.Equal(1024 * 1024, capturer.LeasedStagingBytes);
        using var cancellation = new CancellationTokenSource();
        var waiting = capturer.StageAsync(path, disk, cancellation.Token);
        Assert.False(waiting.IsCompleted);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiting);
        Assert.Equal(1024 * 1024, capturer.AllocatedStagingBytes);

        var next = capturer.StageAsync(path, disk);
        Assert.False(next.IsCompleted);
        await first.DisposeAsync();
        await using var reused = await next.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1024 * 1024, capturer.AllocatedStagingBytes);
        await reused.DisposeAsync();
        Assert.Equal(0, capturer.LeasedStagingBytes);
    }

    [Fact]
    public async Task Stage_CancellationAfterCopyReturnsMemoryAndLegacyOverloadInvalidatesPack()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        await File.WriteAllBytesAsync(path, CreateContent(16));
        var capturer = new StableFileCapturer(new WindowsFileMetadataReader());
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);
        using var cancellation = new CancellationTokenSource();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => capturer.StageAsync(path, writer,
            cancellation.Token, copy =>
            {
                if (copy.CopiedBytes == 16) cancellation.Cancel();
                return ValueTask.CompletedTask;
            }));
        Assert.Equal(0, capturer.LeasedStagingBytes);
        await Assert.ThrowsAsync<InvalidOperationException>(() => writer.SealAndPromoteAsync());
    }

    [Fact]
    public async Task Stage_IndependentFailureDoesNotInvalidatePackAndReturnsMemory()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        await File.WriteAllBytesAsync(path, CreateContent(16));
        var capturer = new StableFileCapturer(new ReplacedMetadataReader(), maxAttempts: 1);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);
        await Assert.ThrowsAsync<UnstableFileException>(() => capturer.StageAsync(path,
            writer.CreateCaptureStagingStream));
        Assert.Equal(0, capturer.LeasedStagingBytes);
        var committed = await writer.SealAndPromoteAsync();
        Assert.True(File.Exists(committed.FullPath));
    }

    [Fact]
    public async Task Stage_ConcurrentCallsSerializeInjectedMetadataReader()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("source.bin");
        await File.WriteAllBytesAsync(path, CreateContent(4096));
        var metadata = new ConcurrencyCheckingMetadataReader();
        var capturer = new StableFileCapturer(metadata);
        var captures = Enumerable.Range(0, 8).Select(_ => Task.Run(async () =>
        {
            await using var staged = await capturer.StageAsync(path,
                () => throw new InvalidOperationException("Unexpected spill."));
            Assert.Equal(4096, staged.Content.Length);
        })).ToArray();
        await Task.WhenAll(captures).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(1, metadata.MaximumConcurrentCalls);
        Assert.Equal(0, capturer.LeasedStagingBytes);
    }

    [Fact]
    public async Task Spill_FailedDiskWriteDisposesTemporaryFileAndEventuallyReturnsLease()
    {
        using var temp = new TempDirectory();
        var diskPath = temp.GetPath("read-only.tmp");
        await File.WriteAllBytesAsync(diskPath, [1]);
        var pool = new BoundedStagingBufferPool(16, 16);
        await using var stream = new SpillableCaptureStream(await pool.RentAsync(default),
            () => new FileStream(diskPath, FileMode.Open, FileAccess.Read, FileShare.None,
                bufferSize: 1, FileOptions.DeleteOnClose));
        await stream.WriteAsync(new byte[8]);
        await Assert.ThrowsAsync<NotSupportedException>(async () => await stream.WriteAsync(new byte[9]));
        Assert.False(File.Exists(diskPath));
        await stream.DisposeAsync();
        Assert.Equal(0, pool.LeasedBytes);
    }

    private static byte[] CreateContent(int length) =>
        Enumerable.Range(0, length).Select(index => (byte)(index % 251)).ToArray();

    private static FileStream CreateDisk(string path) => new(path, FileMode.CreateNew,
        FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.Asynchronous | FileOptions.DeleteOnClose);

    private static async Task<byte[]> ReadAllAsync(Stream source)
    {
        source.Position = 0;
        using var destination = new MemoryStream();
        await source.CopyToAsync(destination);
        return destination.ToArray();
    }

    private static async Task WriteSharedAsync(string path, byte[] content)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Write,
            FileShare.ReadWrite | FileShare.Delete, 128 * 1024, FileOptions.Asynchronous);
        await stream.WriteAsync(content);
        stream.SetLength(content.Length);
        await stream.FlushAsync();
    }

    private sealed class ReplacedMetadataReader : IFileMetadataReader
    {
        private readonly WindowsFileMetadataReader inner = new();
        private int pathReads;
        public FileCaptureMetadata ReadPath(string path)
        {
            var value = inner.ReadPath(path);
            return ++pathReads == 1 ? value : value with { Identity = "replacement" };
        }
        public FileCaptureMetadata ReadHandle(SafeFileHandle handle) => inner.ReadHandle(handle);
    }

    private sealed class ConcurrencyCheckingMetadataReader : IFileMetadataReader
    {
        private readonly WindowsFileMetadataReader inner = new();
        private int activeCalls;
        internal int MaximumConcurrentCalls { get; private set; }
        public FileCaptureMetadata ReadPath(string path) => Read(() => inner.ReadPath(path));
        public FileCaptureMetadata ReadHandle(SafeFileHandle handle) => Read(() => inner.ReadHandle(handle));
        private FileCaptureMetadata Read(Func<FileCaptureMetadata> read)
        {
            var active = Interlocked.Increment(ref activeCalls);
            MaximumConcurrentCalls = Math.Max(MaximumConcurrentCalls, active);
            try
            {
                Thread.Sleep(2);
                return read();
            }
            finally { Interlocked.Decrement(ref activeCalls); }
        }
    }
}
