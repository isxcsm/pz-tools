using PzTools.Process.Contracts;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.ComponentModel;
using System.Globalization;
using System.Text;
using System.Text.Json;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Engine;

public enum BackupScanMode
{
    Journal,
    FullScan,
}

public sealed record IncrementalBackupResult(
    long RunIndex,
    long? Revision,
    int ChangedEntries,
    BackupScanMode ScanMode,
    SourceCheckpoint? Checkpoint,
    string? FullScanReason);

public sealed class IncrementalBackupRunner(
    StreamingFullScanner scanner,
    IStableFileCapturer fileCapturer,
    IFileMetadataReader metadataReader,
    IUsnJournalSource journal,
    UsnDeltaPlanner planner,
    IBackupFailureInjector? failureInjector = null,
    DeduplicatingFileCapturer? deduplicatingCapturer = null,
    bool fullScanHashComparison = true,
    BackupSourcePreparation? prepareSource = null,
    BackupTuningOptions? tuning = null)
{
    private readonly BackupTuningOptions tuning = tuning ?? new();
    public async Task<IncrementalBackupResult> RunAsync(
        RepositoryDatabase repository,
        TelemetryStore telemetryStore,
        RepositoryWriterLease lease,
        RepositorySource source,
        StorageOptions storageOptions,
        TelemetryOptions telemetryOptions,
        CancellationToken cancellationToken = default)
        => await RunAsync(repository, telemetryStore, lease, source, storageOptions,
            telemetryOptions, executionOptions: null, cancellationToken);

    public async Task<IncrementalBackupResult> RunAsync(
        RepositoryDatabase repository,
        TelemetryStore telemetryStore,
        RepositoryWriterLease lease,
        RepositorySource source,
        StorageOptions storageOptions,
        TelemetryOptions telemetryOptions,
        BackupExecutionOptions? executionOptions,
        CancellationToken cancellationToken = default)
        => await RunAsync(
            repository, telemetryStore, lease, source, storageOptions, telemetryOptions,
            executionOptions, [], cancellationToken);

    public async Task<IncrementalBackupResult> RunAsync(
        RepositoryDatabase repository,
        TelemetryStore telemetryStore,
        RepositoryWriterLease lease,
        RepositorySource source,
        StorageOptions storageOptions,
        TelemetryOptions telemetryOptions,
        BackupExecutionOptions? executionOptions,
        IReadOnlyList<string> alwaysIncludePaths,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(telemetryStore);
        ArgumentNullException.ThrowIfNull(lease);
        ArgumentNullException.ThrowIfNull(source);
        executionOptions?.Validate();
        var state = await repository.GetSourceStateAsync(source.SourceId, cancellationToken);
        if (state.CurrentRevision == 0)
        {
            throw new InvalidOperationException("An incremental run requires an initial revision.");
        }

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
            await BackupPreparation.RunAsync(prepareSource, source.RootPath, telemetry, cancellationToken);
            failurePhase = "planning";
            await telemetry.EmitAsync(new TelemetryEvent(TelemetryEventScope.Phase,
                "planning.started"), cancellationToken);
            var boundary = TryQueryBoundary(source.RootPath);
            var planningProgress = new BackupPlanningProgress(telemetry, tuning.ProgressIntervalMs, cancellationToken);
            var mode = BackupScanMode.FullScan;
            string? fullScanReason = boundary.FailureReason;
            List<PendingEntry> pending;
            if (boundary.State is not null && state.Checkpoint is not null)
            {
                var stored = ParseCheckpoint(state.Checkpoint);
                var decision = UsnCheckpointEvaluator.Evaluate(stored, boundary.State);
                if (decision.CanReadIncrementally)
                {
                    mode = BackupScanMode.Journal;
                    fullScanReason = null;
                    var journalPlan = await PlanJournalChangesAsync(
                        repository,
                        source,
                        stored,
                        boundary.State.NextUsn,
                        cancellationToken, planningProgress);
                    pending = journalPlan.Entries;
                    if (journalPlan.FullScanReason is not null)
                    {
                        mode = BackupScanMode.FullScan;
                        fullScanReason = journalPlan.FullScanReason;
                    }
                }
                else
                {
                    fullScanReason = decision.Reason;
                    pending = await PlanFullScanChangesAsync(
                        repository,
                        source,
                        cancellationToken, planningProgress);
                }
            }
            else
            {
                fullScanReason ??= state.Checkpoint is null
                    ? "The source has no valid USN checkpoint."
                    : "The USN journal is unavailable.";
                pending = await PlanFullScanChangesAsync(
                    repository,
                    source,
                    cancellationToken, planningProgress);
            }

            await AddAlwaysIncludedEntriesAsync(
                repository, source, pending, alwaysIncludePaths, cancellationToken);

            var checkpoint = boundary.State is null
                ? state.Checkpoint
                : ToSourceCheckpoint(boundary.State);
            await telemetry.EmitAsync(
                new TelemetryEvent(
                    TelemetryEventScope.Phase,
                    "changes.planned",
                    JsonSerializer.Serialize(new
                    {
                        mode = mode.ToString(),
                        count = pending.Count,
                        fallback = fullScanReason,
                    })),
                cancellationToken);

            if (pending.Count == 0)
            {
                await repository.AdvanceCheckpointWithoutRevisionAsync(
                    lease,
                    run.RunIndex,
                    source.SourceId,
                    checkpoint,
                    cancellationToken);
                await telemetry.EmitAsync(
                    new TelemetryEvent(TelemetryEventScope.Run, "run.no_changes"),
                    CancellationToken.None);
                await telemetry.CompleteAsync(RunStatus.Succeeded, cancellationToken: CancellationToken.None);
                return new IncrementalBackupResult(
                    run.RunIndex,
                    Revision: null,
                    ChangedEntries: 0,
                    mode,
                    checkpoint,
                    fullScanReason);
            }

            var entries = new List<EntryVersionRegistration>(pending.Count);
            var objects = new List<StoredObjectRegistration>();
            var workloadItems = pending.LongCount(item =>
                !item.Tombstone && item.Kind == CatalogEntryKind.File);
            var workloadBytes = pending.Where(item =>
                    !item.Tombstone && item.Kind == CatalogEntryKind.File)
                .Sum(item => item.ByteLength);
            await telemetry.EmitAsync(
                new TelemetryEvent(
                    TelemetryEventScope.Phase,
                    "workload.discovered",
                    JsonSerializer.Serialize(new
                    {
                        totalItems = workloadItems,
                        totalBytes = workloadBytes,
                    })),
                cancellationToken);
            var checksum = StorageStrategyResolver.Resolve(storageOptions.Checksum);
            var compression = StorageStrategyResolver.Resolve(storageOptions.Compression);
            failurePhase = "capture";
            await telemetry.EmitAsync(
                new TelemetryEvent(TelemetryEventScope.Phase, "capture.started"),
                cancellationToken);
            long completedFiles = 0;
            long completedFileBytes = 0;
            long lastCopyProgress = 0;
            async IAsyncEnumerable<PendingEntry> CaptureEntries(
                [EnumeratorCancellation] CancellationToken token)
            {
                foreach (var item in pending)
                {
                    token.ThrowIfCancellationRequested();
                    if (item.Tombstone || item.Kind == CatalogEntryKind.Directory)
                    {
                        entries.Add(item.ToRegistration(ObjectId: null));
                        continue;
                    }
                    packWriter ??= await PackWriter.CreateAsync(repository.RepositoryPath, run.RunIndex, token);
                    yield return item;
                }
            }
            async ValueTask CopyProgress(FileCopyProgress copy)
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
                            totalItems = workloadItems,
                            completedBytes = completedFileBytes + copy.CopiedBytes,
                            totalBytes = workloadBytes,
                            attempt = copy.Attempt,
                        })), cancellationToken);
            }
            await foreach (var prepared in FileCapturePipeline.PrepareAsync(
                CaptureEntries(cancellationToken), fileCapturer as StableFileCapturer,
                item => ToAbsolutePath(source.RootPath, item.RelativePath),
                () => packWriter!.CreateCaptureStagingStream(), tuning, storageOptions.ContentDeduplication,
                item => currentFile = item.RelativePath, CopyProgress, cancellationToken))
            {
                var item = prepared.Entry;
                currentFile = item.RelativePath;
                await telemetry.EmitAsync(new TelemetryEvent(TelemetryEventScope.Raw, "file.capture.started",
                    JsonSerializer.Serialize(new { path = item.RelativePath })), cancellationToken);
                var stored = await prepared.CaptureAsync(repository, fileCapturer, deduplicatingCapturer,
                    packWriter!, checksum, compression, storageOptions.ContentDeduplication,
                    cancellationToken, CopyProgress);
                var captured = stored.Capture;
                if (!stored.Reused)
                {
                    objects.Add(new StoredObjectRegistration(
                        captured.Object.ObjectId,
                        stored.PackId,
                        captured.Object.RecordOffset,
                        captured.Object.StoredLength,
                        captured.Object.OriginalLength,
                        captured.Object.ChecksumAlgorithm.ToString(),
                        captured.Object.Checksum,
                        captured.Object.CompressionAlgorithm.ToString(),
                        captured.Object.Flags,
                        captured.ContentHash));
                }

                entries.Add(PendingEntry.FromCaptured(
                    item.RelativePath,
                    item.ParentFileId,
                    captured).ToRegistration(captured.Object.ObjectId));
                await telemetry.EmitAsync(
                    new TelemetryEvent(
                        TelemetryEventScope.Raw,
                        "file.capture.completed",
                        JsonSerializer.Serialize(new
                        {
                            path = item.RelativePath,
                            bytes = captured.SourceMetadata.Length,
                            reused = stored.Reused,
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
            var committed = await repository.CommitRevisionAsync(
                lease,
                new RevisionCommitRequest(
                    run.RunIndex,
                    source.SourceId,
                    checkpoint,
                    committedPack is null
                        ? []
                        : [new PackRegistration(
                            committedPack.PackId,
                            committedPack.RelativePath,
                            PackWriter.CurrentFormatVersion,
                            committedPack.ByteLength)],
                    objects,
                    entries,
                    RequestedRevision: executionOptions?.Revision,
                    NameLanguage: executionOptions?.NameLanguage
                        ?? PzTools.Process.Contracts.SupportedLanguage.Korean,
                    GameVersion: executionOptions?.GameVersion),
                cancellationToken,
                () => FailureInjector.ThrowIfRequested(BackupFailurePoint.DuringRepositoryCommit));
            FailureInjector.ThrowIfRequested(BackupFailurePoint.AfterRepositoryCommit);
            await telemetry.EmitAsync(
                new TelemetryEvent(
                    TelemetryEventScope.Run,
                    "run.committed",
                    JsonSerializer.Serialize(new { revision = committed.Revision })),
                CancellationToken.None);
            await telemetry.CompleteAsync(RunStatus.Succeeded, cancellationToken: CancellationToken.None);
            return new IncrementalBackupResult(
                run.RunIndex,
                committed.Revision,
                pending.Count,
                mode,
                checkpoint,
                fullScanReason);
        }
        catch (SimulatedProcessCrashException)
        {
            if (packWriter is not null)
            {
                await packWriter.AbandonForCrashSimulationAsync();
            }

            throw;
        }
        catch (BackupPreparationDeferredException exception) when (failurePhase == "source.prepare")
        {
            await repository.CompleteRunAsync(lease, run.RunIndex, RunStatus.Cancelled, "source-deferred", CancellationToken.None);
            await telemetry.EmitAsync(new TelemetryEvent(TelemetryEventScope.Run, "run.cancelled",
                BackupFailureTelemetry.CreateDeferred(source, exception)), CancellationToken.None);
            await telemetry.CompleteAsync(RunStatus.Cancelled, "source-deferred", CancellationToken.None);
            throw;
        }
        catch (OperationCanceledException exception) when (failurePhase == "source.prepare" && !cancellationToken.IsCancellationRequested)
        {
            // Preparation decided against this backup (the world is no longer being played): a skip, not
            // a cancellation by anyone, and recorded as such so the log does not call it cancelled.
            packWriter?.Invalidate("backup run was skipped");
            await CompleteFailedAsync(repository, telemetry, lease, run.RunIndex, RunStatus.Cancelled, "source-skipped",
                BackupFailureTelemetry.Create(source, RunStatus.Cancelled, "source-skipped", exception, failurePhase, currentFile));
            throw;
        }
        catch (OperationCanceledException exception)
        {
            packWriter?.Invalidate("backup run was cancelled");
            await CompleteFailedAsync(
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
            await CompleteFailedAsync(
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

    private async Task AddAlwaysIncludedEntriesAsync(
        RepositoryDatabase repository,
        RepositorySource source,
        List<PendingEntry> pending,
        IReadOnlyList<string> alwaysIncludePaths,
        CancellationToken cancellationToken)
    {
        if (alwaysIncludePaths.Count == 0) return;
        var byPath = pending.ToDictionary(
            item => item.RelativePath, StringComparer.OrdinalIgnoreCase);
        var previous = (await repository.ReadCurrentEntriesByPathsAsync(
                source.SourceId, alwaysIncludePaths, cancellationToken))
            .ToDictionary(item => item.RelativePath, StringComparer.OrdinalIgnoreCase);
        foreach (var relativePath in alwaysIncludePaths)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var current = ReadCurrentEntry(source.RootPath, relativePath);
            if (current is not null && current.Kind == CatalogEntryKind.File)
            {
                byPath[relativePath] = current;
            }
            else if (previous.TryGetValue(relativePath, out var old))
            {
                byPath[relativePath] = PendingEntry.TombstoneFrom(old);
            }
        }
        pending.Clear();
        pending.AddRange(byPath.Values.OrderBy(
            item => item.RelativePath, StringComparer.OrdinalIgnoreCase));
    }

    private async Task<List<PendingEntry>> PlanFullScanChangesAsync(
        RepositoryDatabase repository,
        RepositorySource source,
        CancellationToken cancellationToken,
        BackupPlanningProgress progress)
    {
        await using var scan = await scanner.ScanAsync(
            repository,
            source.SourceId,
            source.RootPath,
            cancellationToken, count => progress.ReportAsync("scan", count));
        var pending = new List<PendingEntry>();
        await foreach (var change in scan.EnumerateChangesAsync(cancellationToken))
        {
            pending.Add(new PendingEntry(
                change.Entry.RelativePath,
                change.Entry.Kind,
                Tombstone: change.Kind == FullScanChangeKind.Deleted,
                change.Entry.Length,
                change.Entry.ModifiedUtc,
                change.Entry.ChangedUtc,
                change.Entry.Attributes,
                change.Entry.FileId,
                change.Entry.ParentFileId));
        }

        if (fullScanHashComparison)
        {
            var workload = await scan.ReadFileWorkloadAsync(cancellationToken);
            var alreadyChanged = pending.Where(item => !item.Tombstone && item.Kind == CatalogEntryKind.File).ToArray();
            long comparedFiles = alreadyChanged.LongLength;
            long comparedBytes = alreadyChanged.Sum(item => item.ByteLength);
            await progress.ReportAsync("hash", comparedFiles, comparedBytes, workload.Bytes, workload.Files);
            var changedPaths = pending.Select(item => item.RelativePath)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            var comparer = new FullScanContentComparer(metadataReader, tuning);
            var batch = new List<(FullScanEntry Entry, byte[]? PreviousHash)>(tuning.FullScanHashBatchSize);
            await foreach (var (entry, previousHash) in scan.EnumerateContentComparisonsAsync(cancellationToken))
            {
                if (changedPaths.Contains(entry.RelativePath)) continue;
                batch.Add((entry, previousHash));
                if (batch.Count == tuning.FullScanHashBatchSize) await CompareBatchAsync();
            }
            if (batch.Count != 0) await CompareBatchAsync();

            async Task CompareBatchAsync()
            {
                // Only file reads overlap. The SQLite reader, planning list and progress totals
                // remain on this consumer. A small batch amortizes worker scheduling without
                // retaining the whole catalog; configured limits bound readers and batch size.
                var matches = await comparer.CompareAsync(source.RootPath, batch, cancellationToken,
                    bytes => progress.ReportAsync("hash", comparedFiles,
                        comparedBytes + bytes, workload.Bytes, workload.Files));
                for (var index = 0; index < batch.Count; index++)
                {
                    var entry = batch[index].Entry;
                    comparedFiles++;
                    comparedBytes += entry.Length;
                    if (matches[index]) continue;
                    pending.Add(new PendingEntry(entry.RelativePath, entry.Kind, false,
                        entry.Length, entry.ModifiedUtc, entry.ChangedUtc, entry.Attributes,
                        entry.FileId, entry.ParentFileId));
                }
                batch.Clear();
                await progress.ReportAsync("hash", comparedFiles, comparedBytes, workload.Bytes, workload.Files);
            }
        }

        return pending;
    }

    private IBackupFailureInjector FailureInjector =>
        failureInjector ?? NoBackupFailureInjector.Instance;

    private async Task<JournalChangePlan> PlanJournalChangesAsync(
        RepositoryDatabase repository,
        RepositorySource source,
        UsnCheckpoint checkpoint,
        long upperUsn,
        CancellationToken cancellationToken,
        BackupPlanningProgress progress)
    {
        if (!await repository.CurrentEntriesHaveCompleteIdentityAsync(
                source.SourceId,
                cancellationToken))
        {
            return new JournalChangePlan(
                await PlanFullScanChangesAsync(repository, source, cancellationToken, progress),
                "The current catalog lacks file identity required for USN planning.");
        }

        var rootReference = FileReferenceCodec.Decode(
            FileIdentityCodec.Encode(metadataReader.ReadPath(source.RootPath).Identity));
        var journalBatchSize = tuning.JournalBatchSize;
        var accumulator = planner.CreateAccumulator(rootReference);
        var hydratedReferences = new HashSet<UInt128>();
        var records = new List<UsnRecord>(journalBatchSize);
        foreach (var record in journal.ReadRange(
                     source.RootPath,
                     checkpoint,
                     upperUsn,
                     cancellationToken))
        {
            cancellationToken.ThrowIfCancellationRequested();
            records.Add(record);
            if (records.Count < journalBatchSize) continue;
            await AddJournalBatchAsync(records);
            records.Clear();
        }
        if (records.Count > 0) await AddJournalBatchAsync(records);
        var plan = accumulator.Build();
        var candidates = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in plan.AffectedPaths)
        {
            candidates[path] = path;
        }

        var previousSubtreeEntries = await repository.ReadCurrentEntriesUnderRootsAsync(
            source.SourceId,
            plan.SubtreeRoots,
            cancellationToken);
        foreach (var root in plan.SubtreeRoots)
        {
            foreach (var old in previousSubtreeEntries.Where(
                         item => IsAtOrBelow(item.RelativePath, root)))
            {
                candidates[old.RelativePath] = old.RelativePath;
            }

            foreach (var found in EnumerateExistingSubtree(source.RootPath, root))
            {
                candidates[found] = found;
            }
        }

        var previous = (await repository.ReadCurrentEntriesByPathsAsync(
                source.SourceId,
                candidates.Values.ToArray(),
                cancellationToken))
            .ToDictionary(item => item.RelativePath, StringComparer.OrdinalIgnoreCase);
        var pending = new List<PendingEntry>();
        foreach (var relativePath in candidates.Values.Order(StringComparer.OrdinalIgnoreCase))
        {
            cancellationToken.ThrowIfCancellationRequested();
            previous.TryGetValue(relativePath, out var old);
            var currentEntry = ReadCurrentEntry(source.RootPath, relativePath);
            if (currentEntry is null)
            {
                if (old is not null)
                {
                    pending.Add(PendingEntry.TombstoneFrom(old));
                }

                continue;
            }

            var contentChanged = currentEntry.Kind == CatalogEntryKind.File
                && currentEntry.FileId is not null
                && plan.ContentChangedFileReferences.Contains(FileReferenceCodec.Decode(currentEntry.FileId));
            if (contentChanged || old is null || !Equivalent(old, currentEntry))
            {
                pending.Add(currentEntry);
            }
        }

        return new JournalChangePlan(pending, FullScanReason: null);

        async Task AddJournalBatchAsync(IReadOnlyList<UsnRecord> batch)
        {
            var references = batch
                .SelectMany(item => new[]
                {
                    item.FileReferenceNumber,
                    item.ParentFileReferenceNumber,
                })
                .Where(hydratedReferences.Add)
                .ToArray();
            if (references.Length > 0)
            {
                var keys = references
                    .Select(item => item.ToString("x32", CultureInfo.InvariantCulture))
                    .ToArray();
                var currentTracked = await repository.ReadCurrentTrackedPathsAsync(
                    source.SourceId,
                    keys,
                    cancellationToken);
                accumulator.AddTrackedPaths(currentTracked.Select(item => new TrackedPath(
                    FileReferenceCodec.Decode(item.FileId),
                    FileReferenceCodec.Decode(item.ParentFileId),
                    item.RelativePath,
                    item.EntryKind == "Directory")));
            }

            accumulator.AddRecords(batch);
        }
    }

    private PendingEntry? ReadCurrentEntry(string sourceRoot, string relativePath)
    {
        var absolutePath = ToAbsolutePath(sourceRoot, relativePath);
        FileCaptureMetadata metadata;
        try
        {
            // Exists() suppresses access and I/O failures. Only a confirmed missing
            // directory entry may become a tombstone (including always-include paths).
            if ((File.GetAttributes(absolutePath) & FileAttributes.ReparsePoint) != 0)
                throw new IOException($"Cannot capture linked source entry '{relativePath}'.");
            metadata = metadataReader.ReadPath(absolutePath);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException
            || exception is Win32Exception { NativeErrorCode: 2 or 3 })
        {
            if (ConfirmMissingEntry(sourceRoot, relativePath)) return null;
            throw new IOException($"Cannot determine source entry state for '{relativePath}'.", exception);
        }
        if ((metadata.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException($"Cannot capture linked source entry '{relativePath}'.");
        }

        var parent = Path.GetDirectoryName(absolutePath)
            ?? throw new InvalidDataException($"Path '{relativePath}' has no parent.");
        var parentMetadata = metadataReader.ReadPath(parent);
        return new PendingEntry(
            BackupPath.NormalizeRelative(relativePath),
            (metadata.Attributes & FileAttributes.Directory) != 0
                ? CatalogEntryKind.Directory
                : CatalogEntryKind.File,
            Tombstone: false,
            metadata.Length,
            metadata.ModifiedUtc,
            metadata.ChangedUtc,
            metadata.Attributes,
            FileIdentityCodec.Encode(metadata.Identity),
            FileIdentityCodec.Encode(parentMetadata.Identity));
    }

    private static bool ConfirmMissingEntry(string sourceRoot, string relativePath)
    {
        // A missing drive/root or an inaccessible ancestor is not evidence of deletion.
        var directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(sourceRoot));
        for (var ancestor = new DirectoryInfo(directory); ancestor is not null; ancestor = ancestor.Parent)
            if ((File.GetAttributes(ancestor.FullName) & FileAttributes.ReparsePoint) != 0)
                throw new IOException($"Cannot verify a missing entry beneath a linked source: '{sourceRoot}'.");

        var parts = BackupPath.NormalizeRelative(relativePath).Split('/');
        for (var index = 0; index < parts.Length; index++)
        {
            var part = parts[index];
            if (part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                throw new InvalidDataException($"Invalid source entry '{relativePath}'.");
            var child = Path.Combine(directory, part);
            // Enumeration must finish successfully; errors propagate and abort the run.
            // An exact-name query avoids rescanning a large parent for each deleted file.
            var entries = Directory.GetFileSystemEntries(directory, part, new EnumerationOptions
            {
                IgnoreInaccessible = false,
                AttributesToSkip = 0,
                MatchType = System.IO.MatchType.Simple,
                MatchCasing = MatchCasing.CaseInsensitive,
            });
            if (!entries.Contains(child, StringComparer.OrdinalIgnoreCase)) return true;
            var attributes = File.GetAttributes(child);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException($"Cannot verify a missing entry beneath a link: '{child}'.");
            // A confirmed ordinary file cannot contain the remaining path. This
            // occurs when a formerly tracked directory is replaced by a file.
            if (index < parts.Length - 1 && (attributes & FileAttributes.Directory) == 0)
                return true;
            directory = child;
        }
        return false;
    }

    private IEnumerable<string> EnumerateExistingSubtree(
        string sourceRoot,
        string relativeRoot)
    {
        var absolute = ToAbsolutePath(sourceRoot, relativeRoot);
        var current = ReadCurrentEntry(sourceRoot, relativeRoot);
        if (current is null || current.Kind != CatalogEntryKind.Directory)
        {
            yield break;
        }

        yield return BackupPath.NormalizeRelative(relativeRoot);
        var pending = new Stack<string>();
        pending.Push(absolute);
        while (pending.TryPop(out var directory))
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(directory))
            {
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    continue;
                }

                yield return BackupPath.NormalizeRelative(Path.GetRelativePath(sourceRoot, path));
                if ((attributes & FileAttributes.Directory) != 0)
                {
                    pending.Push(path);
                }
            }
        }
    }

    private static bool Equivalent(RevisionEntry old, PendingEntry current) =>
        StringComparer.Ordinal.Equals(old.RelativePath, current.RelativePath)
        && old.EntryKind == current.Kind.ToString()
        && old.ByteLength == current.ByteLength
        && old.ModifiedUtc == current.ModifiedUtc
        && old.ChangedUtc == current.ChangedUtc
        && old.Attributes == current.Attributes
        && old.FileId is not null
        && old.FileId.AsSpan().SequenceEqual(current.FileId)
        && old.ParentFileId is not null
        && old.ParentFileId.AsSpan().SequenceEqual(current.ParentFileId);

    private static bool IsAtOrBelow(string path, string root) =>
        path.Equals(root, StringComparison.OrdinalIgnoreCase)
        || path.StartsWith(root + "/", StringComparison.OrdinalIgnoreCase);

    private (UsnJournalState? State, string? FailureReason) TryQueryBoundary(string sourcePath)
    {
        try
        {
            return (journal.Query(sourcePath), null);
        }
        catch (Win32Exception exception) when (exception.NativeErrorCode is 1 or 5 or 50 or 1179)
        {
            return (null, $"USN unavailable ({exception.NativeErrorCode}: {exception.Message})");
        }
        catch (PlatformNotSupportedException exception)
        {
            return (null, exception.Message);
        }
    }

    private static UsnCheckpoint ParseCheckpoint(SourceCheckpoint checkpoint) =>
        new(
            ulong.Parse(checkpoint.VolumeIdentity, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture),
            ulong.Parse(checkpoint.JournalId, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture),
            checkpoint.NextUsn);

    private static SourceCheckpoint ToSourceCheckpoint(UsnJournalState state) =>
        new(
            state.VolumeSerialNumber.ToString("X16", CultureInfo.InvariantCulture),
            state.JournalId.ToString("X16", CultureInfo.InvariantCulture),
            state.NextUsn);

    private static string ToAbsolutePath(string root, string relativePath) =>
        Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));

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
        // record is still written, as the initial backup does, so the log keeps the real cause.
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

    private sealed record PendingEntry(
        string RelativePath,
        CatalogEntryKind Kind,
        bool Tombstone,
        long ByteLength,
        DateTimeOffset ModifiedUtc,
        DateTimeOffset ChangedUtc,
        FileAttributes Attributes,
        byte[] FileId,
        byte[] ParentFileId)
    {
        public EntryVersionRegistration ToRegistration(Guid? ObjectId) =>
            new(
                RelativePath,
                Kind,
                Tombstone,
                ByteLength,
                ModifiedUtc,
                ChangedUtc,
                Attributes,
                Tombstone && FileId.Length == 0 ? null : FileId,
                Tombstone && ParentFileId.Length == 0 ? null : ParentFileId,
                ObjectId);

        public static PendingEntry TombstoneFrom(RevisionEntry entry) =>
            new(
                entry.RelativePath,
                Enum.Parse<CatalogEntryKind>(entry.EntryKind),
                Tombstone: true,
                entry.ByteLength,
                entry.ModifiedUtc,
                entry.ChangedUtc,
                entry.Attributes,
                entry.FileId ?? [],
                entry.ParentFileId ?? []);

        public static PendingEntry FromCaptured(
            string relativePath,
            byte[] parentFileId,
            StableFileCaptureResult captured) =>
            new(
                relativePath,
                CatalogEntryKind.File,
                Tombstone: false,
                captured.SourceMetadata.Length,
                captured.SourceMetadata.ModifiedUtc,
                captured.SourceMetadata.ChangedUtc,
                captured.SourceMetadata.Attributes,
                FileIdentityCodec.Encode(captured.SourceMetadata.Identity),
                parentFileId);
    }

    private sealed record JournalChangePlan(
        List<PendingEntry> Entries,
        string? FullScanReason);
}
