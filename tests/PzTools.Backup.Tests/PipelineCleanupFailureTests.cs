using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;

namespace PzTools.Backup.Tests;

public sealed class PipelineCleanupFailureTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    [Fact]
    public async Task ActivationFailure_DisposesTheCompletedCaptureAndEveryPendingStream()
    {
        using var temp = new TempDirectory();
        await using var fixture = await StagingFixture.CreateAsync(temp);
        var expected = new InvalidOperationException("activation failed");
        await using var iterator = fixture.Prepare(_ => throw expected).GetAsyncEnumerator();

        var actual = await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await iterator.MoveNextAsync().AsTask().WaitAsync(Timeout));

        Assert.Same(expected, actual);
        fixture.AssertEveryStreamDisposed();
        Assert.Empty(Directory.GetFiles(temp.Path, "capture-*.tmp"));
    }

    [Fact]
    public async Task PendingDisposeFailure_DrainsEveryLaterStreamBeforeRethrowing()
    {
        using var temp = new TempDirectory();
        await using var fixture = await StagingFixture.CreateAsync(temp);
        await using var iterator = fixture.Prepare(_ => { }).GetAsyncEnumerator();
        Assert.True(await iterator.MoveNextAsync().AsTask().WaitAsync(Timeout));
        var active = iterator.Current.Staged!.Content;
        var pending = fixture.Streams.Where(stream => !ReferenceEquals(stream, active))
            .OrderBy(stream => stream.Length).ToArray();
        Assert.Equal(2, pending.Length);
        var expected = new IOException("pending staging disposal failed");
        // File lengths increase with enumeration order, so this is the first pending
        // capture to be drained and at least one other stream remains after it.
        pending[0].DisposeFailure = expected;

        var actual = await Assert.ThrowsAsync<IOException>(async () =>
            await iterator.DisposeAsync().AsTask().WaitAsync(Timeout));

        Assert.Same(expected, actual);
        fixture.AssertEveryStreamDisposed();
        Assert.Empty(Directory.GetFiles(temp.Path, "capture-*.tmp"));
    }

    private sealed class StagingFixture(TempDirectory temp, string[] paths) : IAsyncDisposable
    {
        private readonly TaskCompletionSource allStaged = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly ConcurrentBag<TrackingFileStream> streams = [];
        private int remaining = paths.Length;
        private readonly BackupTuningOptions tuning = new(SmallFileStagingKib: 0,
            CaptureReadConcurrency: 3, CaptureQueueCapacity: 4, ProgressIntervalMs: 2000);

        internal TrackingFileStream[] Streams => streams.ToArray();

        internal static async Task<StagingFixture> CreateAsync(TempDirectory temp)
        {
            var paths = new string[3];
            for (var index = 0; index < paths.Length; index++)
            {
                paths[index] = temp.GetPath($"source-{index}.bin");
                await File.WriteAllBytesAsync(paths[index], new byte[4096 + index]);
            }
            return new StagingFixture(temp, paths);
        }

        internal IAsyncEnumerable<PreparedFileCapture<string>> Prepare(Action<string> activate)
        {
            var capturer = new StableFileCapturer(new WindowsFileMetadataReader(),
                verifyStagedCopies: false, maxAttempts: 1, recordContentHash: false, tuning: tuning);
            return FileCapturePipeline.PrepareAsync(Enumerate(), capturer, path => path,
                CreateStream, tuning, false, activate, _ => ValueTask.CompletedTask, CancellationToken.None);
        }

        private FileStream CreateStream()
        {
            var stream = new TrackingFileStream(temp.GetPath($"capture-{Guid.NewGuid():N}.tmp"), () =>
            {
                if (Interlocked.Decrement(ref remaining) == 0) allStaged.TrySetResult();
            });
            streams.Add(stream);
            return stream;
        }

        private async IAsyncEnumerable<string> Enumerate(
            [EnumeratorCancellation] CancellationToken token = default)
        {
            foreach (var path in paths)
            {
                token.ThrowIfCancellationRequested();
                yield return path;
            }
            // Capacity exceeds the source count: the consumer reaches this await
            // while filling its queue, before activation or early disposal can run.
            // Resetting each private copy to position zero is staging's final action.
            await allStaged.Task.WaitAsync(Timeout, token);
        }

        internal void AssertEveryStreamDisposed()
        {
            Assert.Equal(paths.Length, streams.Count);
            Assert.All(streams, stream =>
            {
                Assert.True(stream.Disposed.Task.IsCompletedSuccessfully);
                Assert.False(stream.CanRead);
            });
        }

        public async ValueTask DisposeAsync()
        {
            // Keep failed regressions from leaving handles behind or masking the
            // assertion with TempDirectory's own deletion failure.
            foreach (var stream in streams)
            {
                try { await stream.DisposeAsync(); }
                catch (IOException) { }
            }
        }
    }

    private sealed class TrackingFileStream(string path, Action staged)
        : FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None,
            4096, FileOptions.Asynchronous | FileOptions.DeleteOnClose)
    {
        private int reportedStaged;
        private int failureReported;
        internal IOException? DisposeFailure { get; set; }
        internal TaskCompletionSource Disposed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public override long Position
        {
            get => base.Position;
            set
            {
                base.Position = value;
                if (value == 0 && Length > 0 && Interlocked.Exchange(ref reportedStaged, 1) == 0)
                    staged();
            }
        }

        public override async ValueTask DisposeAsync()
        {
            await base.DisposeAsync();
            Disposed.TrySetResult();
            if (DisposeFailure is { } failure && Interlocked.Exchange(ref failureReported, 1) == 0)
                throw failure;
        }
    }
}
