using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Engine;

public sealed record OneShotBackupResult(
    string SourceId,
    long RunIndex,
    long? Revision,
    int ChangedEntries,
    string Mode,
    SourceCheckpoint? Checkpoint,
    IReadOnlyList<BackupWarning> Warnings);

public sealed record BackupWarning(string Code, string Message);

public sealed class OneShotBackupService(IUsnJournalSource journal, BackupSourcePreparation? prepareSource = null,
    Func<RepositoryDatabase, RepositoryWriterLease, long, long, CancellationToken, Task>? collectMetadata = null)
{
    public OneShotBackupService()
        : this(new UsnJournalReader())
    {
    }

    public async Task<OneShotBackupResult> RunAsync(
        BackupOptions options,
        string sourceKey,
        CancellationToken cancellationToken = default)
        => await RunAsync(options, sourceKey, executionOptions: null, cancellationToken);

    public async Task<OneShotBackupResult> RunAsync(
        BackupOptions options,
        string sourceKey,
        BackupExecutionOptions? executionOptions,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceKey);
        BackupConfiguration.Validate(options);
        executionOptions?.Validate();
        executionOptions = (executionOptions ?? new BackupExecutionOptions()) with
        {
            NameLanguage = options.NameLanguage,
        };
        var configuredSource = options.Sources.SingleOrDefault(
            item => item.Id.Equals(sourceKey, StringComparison.OrdinalIgnoreCase))
            ?? throw new KeyNotFoundException($"Configured source '{sourceKey}' does not exist.");
        if (PzTools.Process.Hosting.SaveFileEditTransaction.IsPending(configuredSource.Path))
            throw new IOException("save-edit-pending");

        await using var lease = RepositoryWriterLease.Acquire(options.RepositoryPath);
        var repository = await RepositoryDatabase.CreateOrOpenAsync(
            options.RepositoryPath,
            cancellationToken);
        var warnings = new List<BackupWarning>();
        var telemetry = await OpenTelemetryAsync(options, cancellationToken);
        var recovery = await new RepositoryRecoveryService().RecoverAsync(
            repository,
            telemetry,
            lease,
            cancellationToken);
        AddWarning(warnings, "telemetry_unavailable", recovery.TelemetryFailure);
        if (recovery.QuarantinedTemporaryFiles > 0)
        {
            warnings.Add(new BackupWarning(
                "temporary_files_quarantined",
                $"Quarantined {recovery.QuarantinedTemporaryFiles} incomplete temporary file(s)."));
        }

        foreach (var issue in recovery.Issues.Where(item => item.Kind == RecoveryIssueKind.OrphanPack))
        {
            warnings.Add(new BackupWarning(
                "orphan_pack",
                $"Unreferenced pack '{issue.RelativePath}' requires garbage collection."));
        }
        if (recovery.HasMissingCommittedData)
        {
            throw new InvalidDataException(
                "The repository references one or more missing committed packs.");
        }
        var source = await repository.AddOrGetSourceAsync(
            lease,
            configuredSource.Id,
            configuredSource.Path,
            cancellationToken);
        var state = await repository.GetSourceStateAsync(source.SourceId, cancellationToken);
        var metadata = new WindowsFileMetadataReader();
        var tuning = options.EffectiveTuning;
        var stableCapturer = new StableFileCapturer(metadata, options.Storage.VerifyStagedCopies,
            maxAttempts: tuning.CaptureAttempts,
            recordContentHash: options.FullScanHashComparison, tuning: tuning);
        var deduplicatingCapturer = new DeduplicatingFileCapturer(stableCapturer);

        OneShotBackupResult result;
        if (state.CurrentRevision == 0)
        {
            var initial = await new InitialBackupRunner(
                new StreamingFullScanner(metadata, tuning.ScanBatchSize),
                stableCapturer,
                new WindowsCheckpointBoundaryProvider(journal),
                deduplicatingCapturer: deduplicatingCapturer,
                prepareSource: prepareSource, tuning: tuning)
                .RunAsync(
                    repository,
                    telemetry,
                    lease,
                    source,
                    options.Storage,
                    options.Telemetry,
                    executionOptions,
                    cancellationToken);
            result = new OneShotBackupResult(
                configuredSource.Id,
                initial.RunIndex,
                initial.Revision,
                checked((int)initial.EntryCount),
                "InitialFullScan",
                initial.Checkpoint,
                warnings);
        }
        else
        {
            var incremental = await new IncrementalBackupRunner(
                new StreamingFullScanner(metadata, tuning.ScanBatchSize),
                stableCapturer,
                metadata,
                journal,
                new UsnDeltaPlanner(),
                deduplicatingCapturer: deduplicatingCapturer,
                fullScanHashComparison: options.FullScanHashComparison,
                prepareSource: prepareSource, tuning: tuning)
                .RunAsync(
                    repository,
                    telemetry,
                    lease,
                    source,
                    options.Storage,
                    options.Telemetry,
                    executionOptions,
                    options.AlwaysIncludePaths ?? [],
                    cancellationToken);
            result = new OneShotBackupResult(
                configuredSource.Id,
                incremental.RunIndex,
                incremental.Revision,
                incremental.ChangedEntries,
                incremental.ScanMode.ToString(),
                incremental.Checkpoint,
                warnings);
        }

        if (result.Revision is { } revision && collectMetadata is not null)
        {
            try { await collectMetadata(repository, lease, source.SourceId, revision, cancellationToken); }
            catch (Exception exception) when (exception is IOException or InvalidDataException
                or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
            { AddWarning(warnings, "character_metadata_unavailable", exception); }
        }
        AddWarning(warnings, "telemetry_unavailable", telemetry.Failure);
        if (telemetry.IsAvailable)
        {
            try
            {
                await telemetry.TrimAsync(
                    options.Telemetry.RetainRuns,
                    options.Telemetry.MaxDatabaseMib,
                    cancellationToken);
            }
            catch (Exception exception) when (
                exception is IOException
                or UnauthorizedAccessException
                or InvalidDataException
                or Microsoft.Data.Sqlite.SqliteException)
            {
                AddWarning(warnings, "telemetry_trim_failed", exception);
            }
        }

        return result;
    }

    private static async Task<TelemetryStore> OpenTelemetryAsync(
        BackupOptions options,
        CancellationToken cancellationToken)
    {
        if (!options.Telemetry.Enabled || options.Telemetry.Mode == TelemetryMode.Off)
        {
            return TelemetryStore.CreateDisabled(options.RepositoryPath);
        }

        try
        {
            return await TelemetryStore.CreateOrOpenAsync(options.RepositoryPath, cancellationToken);
        }
        catch (Exception exception) when (
            exception is IOException
            or UnauthorizedAccessException
            or InvalidDataException
            or Microsoft.Data.Sqlite.SqliteException)
        {
            return TelemetryStore.CreateDisabled(options.RepositoryPath, exception);
        }
    }

    private static void AddWarning(
        List<BackupWarning> warnings,
        string code,
        Exception? exception)
    {
        if (exception is null
            || warnings.Any(item => item.Code == code && item.Message == exception.Message))
        {
            return;
        }

        warnings.Add(new BackupWarning(code, exception.Message));
    }
}
