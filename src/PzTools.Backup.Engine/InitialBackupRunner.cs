using PzTools.Process.Contracts;
using System.Diagnostics;
using System.Text.Json;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Engine;

public sealed record InitialBackupResult(
    long RunIndex,
    long? Revision,
    long EntryCount,
    SourceCheckpoint? Checkpoint,
    string? CheckpointFallbackReason);

public sealed class InitialBackupRunner(
    StreamingFullScanner scanner,
    IStableFileCapturer fileCapturer,
    ICheckpointBoundaryProvider boundaryProvider,
    IBackupFailureInjector? failureInjector = null,
    DeduplicatingFileCapturer? deduplicatingCapturer = null,
    BackupSourcePreparation? prepareSource = null,
    BackupTuningOptions? tuning = null)
{
    private readonly BackupTuningOptions tuning = tuning ?? new();
    public async Task<InitialBackupResult> RunAsync(
        RepositoryDatabase repository,
        TelemetryStore telemetryStore,
        RepositoryWriterLease lease,
        RepositorySource source,
        StorageOptions storageOptions,
        TelemetryOptions telemetryOptions,
        CancellationToken cancellationToken = default)
        => await RunAsync(repository, telemetryStore, lease, source, storageOptions,
            telemetryOptions, executionOptions: null, cancellationToken);

    public async Task<InitialBackupResult> RunAsync(
        RepositoryDatabase repository,
        TelemetryStore telemetryStore,
        RepositoryWriterLease lease,
        RepositorySource source,
        StorageOptions storageOptions,
        TelemetryOptions telemetryOptions,
        BackupExecutionOptions? executionOptions,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(telemetryStore);
        ArgumentNullException.ThrowIfNull(lease);
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(storageOptions);
        ArgumentNullException.ThrowIfNull(telemetryOptions);
        executionOptions?.Validate();
        var checksum = StorageStrategyResolver.Resolve(storageOptions.Checksum);
        var compression = StorageStrategyResolver.Resolve(storageOptions.Compression);
        var run = executionOptions?.RunIndex is long suppliedRunIndex
            ? await repository.StartRunAsync(lease, source.SourceId, suppliedRunIndex, cancellationToken)
            : await repository.StartRunAsync(lease, source.SourceId, cancellationToken);
        await using var telemetry = await telemetryStore.BeginRunAsync(
            run.RunIndex,
            source.SourceId,
            run.StartedUtc,
            telemetryOptions,
            cancellationToken);
        await telemetry.EmitAsync(
            new TelemetryEvent(TelemetryEventScope.Run, "run.started"),
            cancellationToken);
        await using var heartbeat = TelemetryHeartbeat.Start(telemetry, TimeSpan.FromMilliseconds(tuning.HeartbeatIntervalMs));

        PackWriter? packWriter = null;
        var failurePhase = "source.prepare";
        string? currentFile = null;
        try
        {
            // Run under the repository lease, before capturing the journal boundary or scanning files.
            await BackupPreparation.RunAsync(prepareSource, source.RootPath, telemetry, cancellationToken);
            failurePhase = "boundary";
            var boundary = boundaryProvider.Capture(source.RootPath);
            if (boundary.FallbackReason is not null)
            {
                await telemetry.EmitAsync(
                    new TelemetryEvent(
                        TelemetryEventScope.Phase,
                        "journal.unavailable",
                        JsonSerializer.Serialize(new { reason = boundary.FallbackReason })),
                    cancellationToken);
            }

            failurePhase = "scan";
            await telemetry.EmitAsync(
                new TelemetryEvent(TelemetryEventScope.Phase, "scan.started"),
                cancellationToken);
            var planningProgress = new BackupPlanningProgress(telemetry, tuning.ProgressIntervalMs, cancellationToken);
            await using var scan = await scanner.ScanAsync(
                repository,
                source.SourceId,
                source.RootPath,
                cancellationToken, count => planningProgress.ReportAsync("scan", count));
            await telemetry.EmitAsync(
                new TelemetryEvent(
                    TelemetryEventScope.Phase,
                    "scan.completed",
                    JsonSerializer.Serialize(new { entries = scan.EntryCount })),
                cancellationToken);

            var workload = await scan.ReadFileWorkloadAsync(cancellationToken);
            await telemetry.EmitAsync(
                new TelemetryEvent(
                    TelemetryEventScope.Phase,
                    "workload.discovered",
                    JsonSerializer.Serialize(new
                    {
                        totalItems = workload.Files,
                        totalBytes = workload.Bytes,
                    })),
                cancellationToken);

            if (scan.EntryCount == 0)
            {
                await repository.AdvanceCheckpointWithoutRevisionAsync(
                    lease,
                    run.RunIndex,
                    source.SourceId,
                    boundary.Checkpoint,
                    cancellationToken);
                await telemetry.EmitAsync(
                    new TelemetryEvent(TelemetryEventScope.Run, "run.no_changes"),
                    CancellationToken.None);
                await telemetry.CompleteAsync(
                    RunStatus.Succeeded,
                    cancellationToken: CancellationToken.None);
                return new InitialBackupResult(
                    run.RunIndex,
                    Revision: null,
                    scan.EntryCount,
                    boundary.Checkpoint,
                    boundary.FallbackReason);
            }

            failurePhase = "capture";
            await telemetry.EmitAsync(
                new TelemetryEvent(TelemetryEventScope.Phase, "capture.started"),
                cancellationToken);
            long completedFiles = 0;
            long completedFileBytes = 0;
            long lastCopyProgress = 0;
            await foreach (var entry in scan.EnumerateEntriesAsync(cancellationToken))
            {
                if (entry.Kind == CatalogEntryKind.Directory)
                {
                    continue;
                }

                currentFile = entry.RelativePath;
                packWriter ??= await PackWriter.CreateAsync(
                    repository.RepositoryPath,
                    run.RunIndex,
                    cancellationToken);
                await telemetry.EmitAsync(
                    new TelemetryEvent(
                        TelemetryEventScope.Raw,
                        "file.capture.started",
                        JsonSerializer.Serialize(new { path = entry.RelativePath })),
                    cancellationToken);
                Func<FileCopyProgress, ValueTask> copyProgress = async copy =>
                {
                    var now = Stopwatch.GetTimestamp();
                    if (Stopwatch.GetElapsedTime(lastCopyProgress, now)
                            < TimeSpan.FromMilliseconds(tuning.ProgressIntervalMs)
                        && !(copy.Attempt > 1 && copy.CopiedBytes == 0))
                        return;
                    lastCopyProgress = now;
                    await telemetry.EmitAsync(
                        new TelemetryEvent(
                            TelemetryEventScope.Phase,
                            "progress.snapshot",
                            JsonSerializer.Serialize(new
                            {
                                phase = copy.Attempt > 1 ? "copy.retry" : copy.Phase,
                                completedItems = completedFiles,
                                totalItems = workload.Files,
                                completedBytes = completedFileBytes + copy.CopiedBytes,
                                totalBytes = workload.Bytes,
                                attempt = copy.Attempt,
                            })), cancellationToken);
                };
                var stored = storageOptions.ContentDeduplication
                    ? await (deduplicatingCapturer
                        ?? throw new InvalidOperationException(
                            "A deduplicating capturer is required when deduplication is enabled."))
                        .CaptureAsync(
                            repository,
                            ToAbsolutePath(source.RootPath, entry.RelativePath),
                            packWriter,
                            checksum,
                            compression,
                            contentDeduplication: true,
                            cancellationToken: cancellationToken,
                            progress: copyProgress)
                    : new StoredFileCapture(
                        await fileCapturer.CaptureAsync(
                            ToAbsolutePath(source.RootPath, entry.RelativePath),
                            packWriter,
                            checksum,
                            compression,
                            cancellationToken,
                            copyProgress),
                        packWriter.PackId,
                        Reused: false);
                var captured = stored.Capture;
                await scan.StageCapturedFileAsync(
                    entry.RelativePath,
                    stored.PackId,
                    captured,
                    cancellationToken);
                await telemetry.EmitAsync(
                    new TelemetryEvent(
                        TelemetryEventScope.Raw,
                        "file.capture.completed",
                        JsonSerializer.Serialize(new
                        {
                            path = entry.RelativePath,
                            bytes = captured.SourceMetadata.Length,
                        })),
                    cancellationToken);
                completedFiles++;
                completedFileBytes += captured.SourceMetadata.Length;
                currentFile = null;
            }
            await telemetry.EmitAsync(
                new TelemetryEvent(TelemetryEventScope.Phase, "capture.completed"),
                cancellationToken);

            failurePhase = "pack";
            CommittedPack? committedPack = null;
            if (packWriter is not null && packWriter.ObjectCount > 0)
            {
                FailureInjector.ThrowIfRequested(BackupFailurePoint.BeforePackFlush);
                committedPack = await packWriter.SealAndPromoteAsync(cancellationToken);
                FailureInjector.ThrowIfRequested(BackupFailurePoint.AfterPackPromotion);
            }

            failurePhase = "commit";
            FailureInjector.ThrowIfRequested(BackupFailurePoint.BeforeRepositoryCommit);
            var committedRevision = await repository.CommitInitialRevisionFromStagingAsync(
                lease,
                scan.Connection,
                run.RunIndex,
                source.SourceId,
                boundary.Checkpoint,
                committedPack is null
                    ? null
                    : new PackRegistration(
                        committedPack.PackId,
                        committedPack.RelativePath,
                        PackWriter.CurrentFormatVersion,
                        committedPack.ByteLength),
                cancellationToken,
                () => FailureInjector.ThrowIfRequested(BackupFailurePoint.DuringRepositoryCommit),
                executionOptions?.Revision,
                executionOptions?.NameLanguage ?? PzTools.Process.Contracts.SupportedLanguage.Korean);
            FailureInjector.ThrowIfRequested(BackupFailurePoint.AfterRepositoryCommit);
            await telemetry.EmitAsync(
                new TelemetryEvent(
                    TelemetryEventScope.Run,
                    "run.committed",
                    JsonSerializer.Serialize(new { revision = committedRevision.Revision })),
                CancellationToken.None);
            await telemetry.CompleteAsync(
                RunStatus.Succeeded,
                cancellationToken: CancellationToken.None);
            return new InitialBackupResult(
                run.RunIndex,
                committedRevision.Revision,
                scan.EntryCount,
                boundary.Checkpoint,
                boundary.FallbackReason);
        }
        catch (SimulatedProcessCrashException)
        {
            if (packWriter is not null)
            {
                await packWriter.AbandonForCrashSimulationAsync();
            }

            throw;
        }
        catch (OperationCanceledException exception)
        {
            packWriter?.Invalidate("backup run was cancelled");
            await TryCompleteFailedRunAsync(
                repository,
                telemetry,
                lease,
                run.RunIndex,
                RunStatus.Cancelled,
                "cancelled",
                BackupFailureTelemetry.Create(source, RunStatus.Cancelled,
                    "cancelled", exception, failurePhase, currentFile));
            throw;
        }
        catch (Exception exception)
        {
            packWriter?.Invalidate("backup run failed");
            await TryCompleteFailedRunAsync(
                repository,
                telemetry,
                lease,
                run.RunIndex,
                RunStatus.Failed,
                exception.GetType().Name,
                BackupFailureTelemetry.Create(source, RunStatus.Failed,
                    exception.GetType().Name, exception, failurePhase, currentFile));
            throw;
        }
        finally
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
    }

    private static string ToAbsolutePath(string root, string relativePath) =>
        Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));

    private IBackupFailureInjector FailureInjector =>
        failureInjector ?? NoBackupFailureInjector.Instance;

    private static async Task TryCompleteFailedRunAsync(
        RepositoryDatabase repository,
        TelemetryRunSession telemetry,
        RepositoryWriterLease lease,
        long runIndex,
        RunStatus status,
        string failureCode,
        string failurePayload)
    {
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
        {
            throw new InvalidOperationException(
                $"Could not record terminal state for run {runIndex}.",
                repositoryFailure);
        }
    }
}
