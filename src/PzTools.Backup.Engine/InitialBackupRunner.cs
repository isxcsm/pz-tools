using PzTools.Process.Contracts;
using System.Diagnostics;
using System.Runtime.CompilerServices;
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
            var progress = new BackupCaptureProgress(telemetry, workload.Files, workload.Bytes,
                tuning.ProgressIntervalMs, cancellationToken);
            async IAsyncEnumerable<FullScanEntry> CaptureEntries(
                [EnumeratorCancellation] CancellationToken token)
            {
                await foreach (var entry in scan.EnumerateEntriesAsync(token))
                {
                    if (entry.Kind == CatalogEntryKind.Directory) continue;
                    packWriter ??= await PackWriter.CreateAsync(repository.RepositoryPath, run.RunIndex, token, storageOptions.CompressionLevel);
                    yield return entry;
                }
            }
            await foreach (var prepared in FileCapturePipeline.PrepareAsync(
                CaptureEntries(cancellationToken), fileCapturer as StableFileCapturer,
                entry => BackupRunSteps.ToAbsolutePath(source.RootPath, entry.RelativePath),
                () => packWriter!.CreateCaptureStagingStream(), tuning, storageOptions.ContentDeduplication,
                entry => currentFile = entry.RelativePath, progress.ReportAsync, cancellationToken))
            {
                var entry = prepared.Entry;
                currentFile = entry.RelativePath;
                await telemetry.EmitAsync(new TelemetryEvent(TelemetryEventScope.Raw, "file.capture.started",
                    JsonSerializer.Serialize(new { path = entry.RelativePath })), cancellationToken);
                var stored = await prepared.CaptureAsync(repository, fileCapturer, deduplicatingCapturer,
                    packWriter!, checksum, compression, storageOptions.ContentDeduplication,
                    cancellationToken, progress.ReportAsync);
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
                progress.FileDone(captured.SourceMetadata.Length);
                currentFile = null;
            }
            await telemetry.EmitAsync(
                new TelemetryEvent(TelemetryEventScope.Phase, "capture.completed"),
                cancellationToken);

            failurePhase = "pack";
            var committedPack = await BackupRunSteps.SealPackAsync(packWriter, FailureInjector, cancellationToken);

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
                executionOptions?.NameLanguage ?? PzTools.Process.Contracts.SupportedLanguage.Korean,
                executionOptions?.GameVersion);
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
        catch (Exception exception)
        {
            await BackupRunSteps.RecordEndAsync(exception, repository, telemetry, lease, run.RunIndex, source,
                packWriter, failurePhase, currentFile, cancellationToken);
            throw;
        }
        finally
        {
            await BackupRunSteps.DisposeAsync(deduplicatingCapturer, packWriter);
        }
    }

    private IBackupFailureInjector FailureInjector =>
        failureInjector ?? NoBackupFailureInjector.Instance;
}
