using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Engine;

namespace PzTools.Backup.Tests;

public sealed class FullScanContentComparerTests
{
    [Fact]
    public async Task Comparison_OverlapsOnlyTwoReaders_AndSerializesMonotonicProgress()
    {
        using var temp = new TempDirectory();
        var entries = await CreateEntriesAsync(temp);
        var metadata = new TrackingMetadataReader();
        var reports = new List<long>();
        var callbackActive = 0;
        var matches = await new FullScanContentComparer(metadata).CompareAsync(temp.Path, entries,
            CancellationToken.None, async bytes =>
            {
                Assert.Equal(1, Interlocked.Increment(ref callbackActive));
                try
                {
                    await metadata.BothOpened.Task.WaitAsync(TimeSpan.FromSeconds(5));
                    await Task.Yield();
                    reports.Add(bytes);
                }
                finally { Interlocked.Decrement(ref callbackActive); }
            });
        Assert.Equal(new[] { true, true }, matches);
        Assert.Equal(2, metadata.MaximumOpenHandles);
        Assert.Equal(1, metadata.MaximumMetadataCalls);
        Assert.All(metadata.Handles, handle => Assert.True(handle.IsClosed));
        Assert.Equal(reports.Order(), reports);
        Assert.Equal(entries.Sum(entry => entry.Entry.Length), reports[^1]);
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => new FullScanContentComparer(metadata)
            .CompareAsync(temp.Path, Enumerable.Repeat(entries[0], FullScanContentComparer.BatchSize + 1).ToArray(),
                CancellationToken.None, _ => ValueTask.CompletedTask));
    }

    [Fact]
    public async Task Comparison_LargerBatchKeepsTwoReadersAndPreservesMissingOrMismatchedBaselines()
    {
        using var temp = new TempDirectory();
        var entries = await CreateEntriesAsync(temp);
        var batch = Enumerable.Range(0, FullScanContentComparer.BatchSize).Select(index => entries[index % 2]).ToArray();
        batch[4] = (batch[4].Entry, null);
        batch[9] = (batch[9].Entry, new byte[ContentFingerprint.Length]);
        var metadata = new TrackingMetadataReader();
        var matches = await new FullScanContentComparer(metadata).CompareAsync(temp.Path, batch,
            CancellationToken.None, async _ => await metadata.BothOpened.Task.WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(Enumerable.Range(0, batch.Length).Select(index => index is not (4 or 9)), matches);
        Assert.Equal(2, metadata.MaximumOpenHandles);
        Assert.All(metadata.Handles, handle => Assert.True(handle.IsClosed));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Comparison_DrainsBothReadersBeforeFailureOrCancellation(bool cancel)
    {
        using var temp = new TempDirectory();
        var entries = await CreateEntriesAsync(temp);
        var metadata = new TrackingMetadataReader();
        using var stop = new CancellationTokenSource();
        var expected = new IOException("comparison fixture failed");
        var work = new FullScanContentComparer(metadata).CompareAsync(temp.Path, entries, stop.Token, async bytes =>
        {
            await metadata.BothOpened.Task.WaitAsync(TimeSpan.FromSeconds(5));
            if (cancel) stop.Cancel();
            else if (bytes > 0) throw expected;
        });
        if (cancel) await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work);
        else Assert.Same(expected, await Assert.ThrowsAsync<IOException>(() => work));
        Assert.Equal(2, metadata.MaximumOpenHandles);
        Assert.All(metadata.Handles, handle => Assert.True(handle.IsClosed));
        foreach (var entry in entries)
        {
            using var exclusive = new FileStream(Path.Combine(temp.Path, entry.Entry.RelativePath),
                FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        }
    }

    [Fact]
    public async Task Comparison_PreservesResultOrderAndDetectsChangedMetadata()
    {
        using var temp = new TempDirectory();
        var entries = await CreateEntriesAsync(temp);
        // The full contents still match, but the scan metadata no longer describes this file.
        entries[0] = (entries[0].Entry with { ModifiedUtc = DateTimeOffset.UnixEpoch }, entries[0].PreviousHash);
        var matches = await new FullScanContentComparer(new WindowsFileMetadataReader()).CompareAsync(
            temp.Path, entries, CancellationToken.None, _ => ValueTask.CompletedTask);
        Assert.Equal(new[] { false, true }, matches);
    }

    private static async Task<(FullScanEntry Entry, byte[]? PreviousHash)[]> CreateEntriesAsync(TempDirectory temp)
    {
        var metadata = new WindowsFileMetadataReader();
        var entries = new (FullScanEntry Entry, byte[]? PreviousHash)[2];
        for (var index = 0; index < entries.Length; index++)
        {
            var content = new byte[384 * 1024 + index];
            new Random(73 + index).NextBytes(content);
            var relative = $"file-{index}.bin";
            var path = temp.GetPath(relative);
            await File.WriteAllBytesAsync(path, content);
            var value = metadata.ReadPath(path);
            entries[index] = (new FullScanEntry(relative.ToUpperInvariant(), relative, CatalogEntryKind.File,
                value.Length, value.ModifiedUtc, value.ChangedUtc, value.Attributes,
                FileIdentityCodec.Encode(value.Identity), []), ContentFingerprint.FromSha256(SHA256.HashData(content)));
        }
        return entries;
    }

    private sealed class TrackingMetadataReader : IFileMetadataReader
    {
        private readonly WindowsFileMetadataReader inner = new();
        private int activeMetadataCalls;
        // Track content streams passed to ReadHandle. ReadPath also opens a short-lived,
        // serialized metadata handle internally, outside the two-content-reader bound.
        public HashSet<SafeFileHandle> Handles { get; } = [];
        public TaskCompletionSource BothOpened { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int MaximumOpenHandles { get; private set; }
        public int MaximumMetadataCalls { get; private set; }

        public FileCaptureMetadata ReadPath(string path) => Read(() => inner.ReadPath(path));
        public FileCaptureMetadata ReadHandle(SafeFileHandle handle) => Read(() =>
        {
            Handles.Add(handle);
            var open = Handles.Count(item => !item.IsClosed);
            MaximumOpenHandles = Math.Max(MaximumOpenHandles, open);
            if (open == 2) BothOpened.TrySetResult();
            return inner.ReadHandle(handle);
        });
        private FileCaptureMetadata Read(Func<FileCaptureMetadata> read)
        {
            var active = Interlocked.Increment(ref activeMetadataCalls);
            try
            {
                MaximumMetadataCalls = Math.Max(MaximumMetadataCalls, active);
                Assert.Equal(1, active);
                return read();
            }
            finally { Interlocked.Decrement(ref activeMetadataCalls); }
        }
    }
}
