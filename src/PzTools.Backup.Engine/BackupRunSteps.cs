using System.Diagnostics;
using System.Text.Json;
using PzTools.Process.Contracts;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Engine;

/// <summary>
/// The steps the first and the incremental backup share, kept in one place so they cannot drift apart
/// (they had: one of them lost the real failure when the repository failed too).
/// </summary>
internal static class BackupRunSteps
{
    public static string ToAbsolutePath(string root, string relativePath) =>
        Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));

    public static async Task<CommittedPack?> SealPackAsync(
        PackWriter? packWriter, IBackupFailureInjector failureInjector, CancellationToken cancellationToken)
    {
        if (packWriter is null || packWriter.ObjectCount == 0) return null;
        failureInjector.ThrowIfRequested(BackupFailurePoint.BeforePackFlush);
        var committed = await packWriter.SealAndPromoteAsync(cancellationToken);
        failureInjector.ThrowIfRequested(BackupFailurePoint.AfterPackPromotion);
        return committed;
    }

    /// <summary>Records how a run that threw ended. The caller rethrows.</summary>
    public static async Task RecordEndAsync(
        Exception exception,
        RepositoryDatabase repository,
        TelemetryRunSession telemetry,
        RepositoryWriterLease lease,
        long runIndex,
        RepositorySource source,
        PackWriter? packWriter,
        string failurePhase,
        string? currentFile,
        CancellationToken cancellationToken)
    {
        switch (exception)
        {
            case SimulatedProcessCrashException:
                if (packWriter is not null) await packWriter.AbandonForCrashSimulationAsync();
                return;
            case BackupPreparationDeferredException deferred when failurePhase == "source.prepare":
                await repository.CompleteRunAsync(lease, runIndex, RunStatus.Cancelled, "source-deferred", CancellationToken.None);
                await telemetry.EmitAsync(new TelemetryEvent(TelemetryEventScope.Run, "run.cancelled",
                    BackupFailureTelemetry.CreateDeferred(source, deferred)), CancellationToken.None);
                await telemetry.CompleteAsync(RunStatus.Cancelled, "source-deferred", CancellationToken.None);
                return;
            // Preparation decided against this backup (the world is no longer being played): a skip, not
            // a cancellation by anyone, and recorded as such so the log does not call it cancelled.
            case OperationCanceledException when failurePhase == "source.prepare" && !cancellationToken.IsCancellationRequested:
                packWriter?.Invalidate("backup run was skipped");
                await CompleteFailedAsync(repository, telemetry, lease, runIndex, RunStatus.Cancelled, "source-skipped",
                    BackupFailureTelemetry.Create(source, RunStatus.Cancelled, "source-skipped", exception, failurePhase, currentFile));
                return;
            case OperationCanceledException:
                packWriter?.Invalidate("backup run was cancelled");
                await CompleteFailedAsync(repository, telemetry, lease, runIndex, RunStatus.Cancelled, "cancelled",
                    BackupFailureTelemetry.Create(source, RunStatus.Cancelled, "cancelled", exception, failurePhase, currentFile));
                return;
            default:
                packWriter?.Invalidate("backup run failed");
                var code = exception.GetType().Name;
                await CompleteFailedAsync(repository, telemetry, lease, runIndex, RunStatus.Failed, code,
                    BackupFailureTelemetry.Create(source, RunStatus.Failed, code, exception, failurePhase, currentFile));
                return;
        }
    }

    public static async Task DisposeAsync(DeduplicatingFileCapturer? deduplicatingCapturer, PackWriter? packWriter)
    {
        try
        {
            if (deduplicatingCapturer is not null) await deduplicatingCapturer.EndRunAsync();
        }
        finally
        {
            if (packWriter is not null) await packWriter.DisposeAsync();
        }
    }

    private static async Task CompleteFailedAsync(
        RepositoryDatabase repository,
        TelemetryRunSession telemetry,
        RepositoryWriterLease lease,
        long runIndex,
        RunStatus status,
        string failureCode,
        string failurePayload)
    {
        // Often the repository fails here for the reason the run failed (busy, disk full). The failure
        // record is still written, so the log keeps the real cause.
        Exception? repositoryFailure = null;
        try
        {
            await repository.CompleteRunAsync(lease, runIndex, status, failureCode);
        }
        catch (Exception exception)
        {
            repositoryFailure = exception;
        }
        await telemetry.EmitAsync(new TelemetryEvent(
            TelemetryEventScope.Run,
            status == RunStatus.Cancelled ? "run.cancelled" : "run.failed",
            failurePayload));
        await telemetry.CompleteAsync(status, failureCode);
        if (repositoryFailure is not null)
            throw new InvalidOperationException($"Could not record terminal state for run {runIndex}.", repositoryFailure);
    }
}

/// <summary>Capture progress of one run: files done, and throttled snapshots while a file is copied.</summary>
internal sealed class BackupCaptureProgress(
    TelemetryRunSession telemetry, long totalItems, long totalBytes, int intervalMs, CancellationToken cancellationToken)
{
    private long completedFiles;
    private long completedBytes;
    private long lastSnapshot;

    public void FileDone(long bytes)
    {
        completedFiles++;
        completedBytes += bytes;
    }

    public async ValueTask ReportAsync(FileCopyProgress copy)
    {
        var now = Stopwatch.GetTimestamp();
        if (Stopwatch.GetElapsedTime(lastSnapshot, now) < TimeSpan.FromMilliseconds(intervalMs)
            && !(copy.Attempt > 1 && copy.CopiedBytes == 0))
            return;
        lastSnapshot = now;
        await telemetry.EmitAsync(
            new TelemetryEvent(
                TelemetryEventScope.Phase,
                "progress.snapshot",
                JsonSerializer.Serialize(new
                {
                    phase = copy.Attempt > 1 ? "copy.retry" : copy.Phase,
                    completedItems = completedFiles,
                    totalItems,
                    completedBytes = completedBytes + copy.CopiedBytes,
                    totalBytes,
                    attempt = copy.Attempt,
                })), cancellationToken);
    }
}
