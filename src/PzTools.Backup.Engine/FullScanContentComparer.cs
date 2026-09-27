using System.Buffers;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Engine;

// Bound small-file open/read latency without buffering the full catalog or weakening stability checks.
internal sealed class FullScanContentComparer
{
    private readonly IFileMetadataReader metadataReader;
    private readonly BackupTuningOptions tuning;
    private readonly int copyBufferBytes;
    private readonly object metadataGate = new();

    internal FullScanContentComparer(IFileMetadataReader metadataReader, BackupTuningOptions? tuning = null)
    {
        ArgumentNullException.ThrowIfNull(metadataReader);
        this.metadataReader = metadataReader;
        this.tuning = tuning ?? new();
        this.tuning.Validate();
        copyBufferBytes = checked(this.tuning.CopyBufferKib * 1024);
    }

    internal async Task<bool[]> CompareAsync(
        string sourceRoot, IReadOnlyList<(FullScanEntry Entry, byte[]? PreviousHash)> entries,
        CancellationToken cancellationToken, Func<long, ValueTask> progress)
    {
        if (entries.Count < 1 || entries.Count > tuning.FullScanHashBatchSize)
            throw new ArgumentOutOfRangeException(nameof(entries));
        cancellationToken.ThrowIfCancellationRequested();
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        using var progressGate = new SemaphoreSlim(1, 1);
        var bytes = new long[entries.Count];
        var matches = new bool[entries.Count];
        var tasks = new Task[Math.Min(tuning.FullScanHashReadConcurrency, entries.Count)];
        var next = -1;
        long completedBytes = 0;
        ExceptionDispatchInfo? failure = null;
        for (var worker = 0; worker < tasks.Length; worker++)
        {
            tasks[worker] = Task.Run(async () =>
            {
                try
                {
                    while (true)
                    {
                        stop.Token.ThrowIfCancellationRequested();
                        var slot = Interlocked.Increment(ref next);
                        if (slot >= entries.Count) return;
                        var candidate = entries[slot];
                        // Missing stored fingerprints require capture, never a baseline from a live read.
                        if (candidate.PreviousHash is null) continue;
                        matches[slot] = await ContentMatchesAsync(sourceRoot, candidate.Entry, candidate.PreviousHash,
                            stop.Token, async count =>
                            {
                                // Serialize reporting as well as aggregation: telemetry and its sampler
                                // must never observe reversed counters or concurrent callback invocations.
                                await progressGate.WaitAsync(stop.Token);
                                try
                                {
                                    var current = Math.Min(count, candidate.Entry.Length);
                                    completedBytes += current - bytes[slot];
                                    bytes[slot] = current;
                                    await progress(completedBytes);
                                }
                                finally { progressGate.Release(); }
                            });
                    }
                }
                catch (Exception exception)
                {
                    Interlocked.CompareExchange(ref failure, ExceptionDispatchInfo.Capture(exception), null);
                    stop.Cancel();
                    throw;
                }
            }, stop.Token);
        }
        try
        {
            await Task.WhenAll(tasks);
            return matches;
        }
        catch
        {
            // WhenAll drains all readers before the scan/lease is released. Prefer the original
            // failure over the cancellation it caused in the other reader.
            failure?.Throw();
            throw;
        }
    }

    private async Task<bool> ContentMatchesAsync(
        string sourceRoot, FullScanEntry entry, byte[] previousHash,
        CancellationToken cancellationToken, Func<long, ValueTask> progress)
    {
        var path = Path.Combine(sourceRoot, entry.RelativePath.Replace('/', Path.DirectorySeparatorChar));
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, copyBufferBytes,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        FileCaptureMetadata before;
        // The metadata-reader interface does not require thread safety, even though the Windows
        // implementation is stateless. Keep injected readers serialized too.
        lock (metadataGate) before = metadataReader.ReadHandle(stream.SafeFileHandle);
        // A file that changed after enumeration already requires capture. Do not read
        // its complete contents here when the comparison cannot possibly match.
        if (before.Length != entry.Length
            || before.ModifiedUtc != entry.ModifiedUtc
            || before.ChangedUtc != entry.ChangedUtc
            || !FileIdentityCodec.Encode(before.Identity).AsSpan().SequenceEqual(entry.FileId))
            return false;
        byte[] hash;
        using (var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
        {
            var buffer = ArrayPool<byte>.Shared.Rent(copyBufferBytes);
            try
            {
                long bytes = 0;
                int read;
                await progress(0);
                while ((read = await stream.ReadAsync(buffer.AsMemory(0, copyBufferBytes), cancellationToken)) > 0)
                {
                    hasher.AppendData(buffer, 0, read);
                    bytes += read;
                    await progress(bytes);
                }
                hash = hasher.GetHashAndReset();
            }
            finally { ArrayPool<byte>.Shared.Return(buffer); }
        }
        FileCaptureMetadata after, current;
        lock (metadataGate)
        {
            after = metadataReader.ReadHandle(stream.SafeFileHandle);
            // Windows briefly opens one additional metadata handle to verify that the path
            // still identifies this file. The configured reader bound applies to content streams.
            current = metadataReader.ReadPath(path);
        }
        return ContentFingerprint.MatchesSha256(previousHash, hash)
            && before == after && after == current
            && before.Length == entry.Length
            && before.ModifiedUtc == entry.ModifiedUtc
            && before.ChangedUtc == entry.ChangedUtc
            && FileIdentityCodec.Encode(before.Identity).AsSpan().SequenceEqual(entry.FileId);
    }
}
