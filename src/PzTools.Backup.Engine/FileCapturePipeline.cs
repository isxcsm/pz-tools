using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

// Only source reads overlap. Enumeration, telemetry, deduplication, pack writes and
// catalog updates remain on the consuming runner (including its SQLite reader).
internal static class FileCapturePipeline
{
    internal static async IAsyncEnumerable<PreparedFileCapture<T>> PrepareAsync<T>(
        IAsyncEnumerable<T> entries,
        StableFileCapturer? capturer,
        Func<T, string> path,
        Func<FileStream> createDiskStaging,
        BackupTuningOptions tuning,
        bool requireFullHash,
        Action<T> activate,
        Func<FileCopyProgress, ValueTask> progress,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        tuning.Validate();
        if (capturer is null)
        {
            // Preserve injected capturers, including failure-injection fixtures.
            await foreach (var entry in entries.WithCancellation(cancellationToken))
                yield return new(entry, path(entry), null);
            yield break;
        }

        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var readers = new SemaphoreSlim(tuning.CaptureReadConcurrency);
        await using var enumerator = entries.GetAsyncEnumerator(stop.Token);
        var pending = new List<PendingCapture<T>>(tuning.CaptureQueueCapacity);
        var exhausted = false;
        Task nextProgress = Task.Delay(tuning.ProgressIntervalMs, stop.Token);
        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                while (!exhausted && pending.Count < tuning.CaptureQueueCapacity)
                {
                    if (!await enumerator.MoveNextAsync())
                    {
                        exhausted = true;
                        break;
                    }
                    var entry = enumerator.Current;
                    var work = new PendingCapture<T>(entry, path(entry));
                    pending.Add(work);
                    work.Task = Task.Run(async () =>
                    {
                        await readers.WaitAsync(stop.Token);
                        try
                        {
                            return await capturer.StageAsync(work.Path, createDiskStaging, stop.Token,
                                copy => { work.Report(copy); return ValueTask.CompletedTask; }, requireFullHash);
                        }
                        finally { readers.Release(); }
                    }, stop.Token);
                }
                if (pending.Count == 0) yield break;

                var ready = pending.FindIndex(work => work.Task.IsCompleted);
                if (ready < 0)
                {
                    await Task.WhenAny(pending.Select(work => (Task)work.Task).Append(nextProgress));
                    cancellationToken.ThrowIfCancellationRequested();
                    if (nextProgress.IsCompleted)
                    {
                        var reporting = pending.FirstOrDefault(work => !work.Task.IsCompleted && work.Progress is not null);
                        if (reporting?.Progress is { } copy)
                        {
                            activate(reporting.Entry);
                            await progress(copy);
                        }
                        nextProgress = Task.Delay(tuning.ProgressIntervalMs, stop.Token);
                    }
                    continue;
                }

                // Completion order prevents a slow first file from blocking ready buffers
                // that must be returned to the pool before other readers can proceed.
                var completed = pending[ready];
                activate(completed.Entry);
                pending.RemoveAt(ready);
                await using var staged = await completed.Task;
                yield return new(completed.Entry, completed.Path, staged);
            }
        }
        finally
        {
            // Consumer failure/cancellation/early disposal must close every temp file and
            // return every buffer before the runner closes or invalidates the pack.
            await stop.CancelAsync();
            Exception? cleanupFailure = null;
            foreach (var work in pending)
            {
                StagedFileCapture staged;
                try { staged = await work.Task; }
                catch { continue; } // The active failure is propagated by the consumer.
                try { await staged.DisposeAsync(); }
                catch (Exception exception) { cleanupFailure ??= exception; }
            }
            if (cleanupFailure is not null) ExceptionDispatchInfo.Capture(cleanupFailure).Throw();
        }
    }

    private sealed class PendingCapture<T>(T entry, string path)
    {
        private FileCopyProgress? progress;
        internal T Entry { get; } = entry;
        internal string Path { get; } = path;
        internal Task<StagedFileCapture> Task { get; set; } = null!;
        internal FileCopyProgress? Progress => Volatile.Read(ref progress);
        internal void Report(FileCopyProgress value) => Volatile.Write(ref progress, value);
    }
}

internal sealed record PreparedFileCapture<T>(T Entry, string Path, StagedFileCapture? Staged)
{
    internal async Task<StoredFileCapture> CaptureAsync(
        RepositoryDatabase repository,
        IStableFileCapturer capturer,
        DeduplicatingFileCapturer? deduplicatingCapturer,
        PackWriter writer,
        ChecksumAlgorithm checksum,
        CompressionAlgorithm compression,
        bool deduplicate,
        CancellationToken cancellationToken,
        Func<FileCopyProgress, ValueTask> progress)
    {
        if (deduplicate)
        {
            var dedup = deduplicatingCapturer
                ?? throw new InvalidOperationException("A deduplicating capturer is required when deduplication is enabled.");
            return Staged is null
                ? await dedup.CaptureAsync(repository, Path, writer, checksum, compression, true, cancellationToken, progress)
                : await dedup.CaptureStagedAsync(repository, Staged, writer, checksum, compression, true, cancellationToken, progress);
        }
        var capture = Staged is null
            ? await capturer.CaptureAsync(Path, writer, checksum, compression, cancellationToken, progress)
            : await Staged.CaptureAsync(writer, checksum, compression, cancellationToken, progress);
        return new(capture, writer.PackId, Reused: false);
    }
}
