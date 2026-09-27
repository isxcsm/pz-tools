using System.Text.Json;
using PzTools.Backup.Cli;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Zomboid.Backup;
using PzTools.SaveBridge;
using PzTools.Process.Contracts.GameRuntime;

return await BackupCli.RunAsync(args);

internal static class BackupCli
{
    public static async Task<int> RunAsync(string[] args)
    {
        using var cancellationSource = new CancellationTokenSource();
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellationSource.Cancel();
        };

        try
        {
            return args switch
            {
                ["scan", var source, var catalogPath] =>
                    await ScanAsync(source, catalogPath, cancellationSource.Token),
                ["diff", var source, var catalogPath] =>
                    await DiffAsync(source, catalogPath, cancellationSource.Token),
                ["config", "validate", .. var configArguments] =>
                    ValidateConfiguration(configArguments),
                ["config", "show", .. var configArguments] =>
                    ShowConfiguration(configArguments),
                ["backup", .. var backupArguments] =>
                    await BackupOnceAsync(backupArguments, cancellationSource.Token),
                ["restore", .. var restoreArguments] =>
                    await RestoreAsync(restoreArguments, cancellationSource.Token),
                ["verify", .. var verifyArguments] =>
                    await VerifyAsync(verifyArguments, cancellationSource.Token),
                ["maintenance", "prune", .. var pruneArguments] =>
                    await PruneAsync(pruneArguments, cancellationSource.Token),
                ["maintenance", "gc", .. var gcArguments] =>
                    await GarbageCollectAsync(gcArguments, cancellationSource.Token),
                ["help"] or ["--help"] or ["-h"] or [] => ShowHelp(),
                _ => ShowUsageError(),
            };
        }
        catch (OperationCanceledException)
        {
            WriteError("cancelled", "Operation cancelled.");
            return 2;
        }
        catch (BackupConfigurationException exception)
        {
            WriteError("invalid_arguments", exception.Message);
            return 64;
        }
        catch (RepositoryBusyException exception)
        {
            WriteError("repository_busy", exception.Message);
            return 75;
        }
        catch (Exception exception)
        {
            WriteError("backup_error", exception.Message);
            return 1;
        }
    }

    private static async Task<int> ScanAsync(
        string source,
        string catalogPath,
        CancellationToken cancellationToken)
    {
        var catalog = new FileSystemScanner().Scan(source, cancellationToken);
        await new JsonCatalogStore().SaveAsync(catalogPath, catalog, cancellationToken);

        var fileCount = catalog.Entries.Count(entry => entry.Kind == CatalogEntryKind.File);
        var directoryCount = catalog.Entries.Count - fileCount;
        var totalBytes = catalog.Entries.Sum(entry => entry.Size);

        Console.WriteLine($"Scanned: {catalog.SourceRoot}");
        Console.WriteLine($"Files: {fileCount:N0}, directories: {directoryCount:N0}, bytes: {totalBytes:N0}");
        Console.WriteLine($"Catalog: {Path.GetFullPath(catalogPath)}");
        return 0;
    }

    private static async Task<int> DiffAsync(
        string source,
        string catalogPath,
        CancellationToken cancellationToken)
    {
        var store = new JsonCatalogStore();
        var previous = await store.LoadAsync(catalogPath, cancellationToken);
        var current = new FileSystemScanner().Scan(source, cancellationToken);

        if (!StringComparer.OrdinalIgnoreCase.Equals(
            Path.TrimEndingDirectorySeparator(previous.SourceRoot),
            Path.TrimEndingDirectorySeparator(current.SourceRoot)))
        {
            throw new InvalidOperationException(
                $"Catalog source '{previous.SourceRoot}' does not match '{current.SourceRoot}'.");
        }

        var changes = CatalogDiffer.Diff(previous, current);
        foreach (var change in changes)
        {
            var detail = change.Kind == CatalogChangeKind.Renamed
                ? $"{change.Previous!.RelativePath} -> {change.Current!.RelativePath}"
                : change.RelativePath;
            Console.WriteLine($"{change.Kind,-8} {detail}");
        }

        Console.WriteLine($"Changes: {changes.Count:N0}");
        return 0;
    }

    private static int ShowHelp()
    {
        Console.WriteLine("PzTools generic backup diagnostics");
        Console.WriteLine();
        Console.WriteLine("  scan <source> <catalog.json>  Scan a directory and save a catalog.");
        Console.WriteLine("  diff <source> <catalog.json>  Compare a directory with a saved catalog.");
        Console.WriteLine("  config validate [options]       Validate effective TOML configuration.");
        Console.WriteLine("  config show [options]           Print effective TOML configuration.");
        Console.WriteLine("  backup --repository <path> --source-id <id> [--source <id>=<path>]");
        Console.WriteLine("         [--always-include <relative-path>] [--run-index <n>] [--control-db <path>] [--revision <n>]");
        Console.WriteLine("         [--full-scan-hash-comparison <true|false>]");
        Console.WriteLine("         [--save-game]  Save the matching running single-player world before capture.");
        Console.WriteLine("         [--require-active-game]  Skip automatic work if the selected world stops before capture.");
        Console.WriteLine("         [--save-game-before-backup <true|false>]  Override the game-save preference.");
        Console.WriteLine("         [--scheduled-utc <ISO 8601>]  Prepare ahead, then save/capture no earlier than this time.");
        Console.WriteLine("  restore --repository <path> --source-id <id> --revision <n> --target <path>");
        Console.WriteLine("  verify --repository <path>       Verify every committed pack.");
        Console.WriteLine("  maintenance prune --repository <path> --source-id <id> --keep <n>");
        Console.WriteLine("  maintenance gc --repository <path>");
        return 0;
    }

    private static async Task<int> BackupOnceAsync(
        string[] arguments,
        CancellationToken cancellationToken)
    {
        var started = DateTimeOffset.UtcNow;
        var runIndex = OnceBackupArguments.ReadFailureRunIndex(arguments) ?? 1L;
        RepositoryDatabase? ownedWorkflowRepository = null;
        var guardedRequest = false;
        try
        {
            var request = OnceBackupArguments.Parse(arguments);
            guardedRequest = request.RuntimeTicket is not null;
            // Configuration can fail before the engine creates its telemetry.
            // Preserve the caller's identity in that failure response too.
            runIndex = request.RunIndex ?? runIndex;
            var options = BackupConfiguration.Load(
                request.Configuration.RepositoryPath,
                request.Configuration.ConfigPath,
                request.Configuration.Overrides,
                Path.Combine(PzToolsPathLayout.CreateDefault().DataRoot, "settings.toml"));
            var requestedRunIndex = request.RunIndex;
            if (requestedRunIndex is null)
            {
                runIndex = await new RunIndexAllocator(
                    request.ControlDatabasePath).AllocateAsync(cancellationToken: cancellationToken);
                ownedWorkflowRepository = await RepositoryDatabase.CreateOrOpenAsync(
                    options.RepositoryPath, cancellationToken);
                await ownedWorkflowRepository.ReserveWorkflowAsync(
                    "backup", null, "backup-worker", null, runIndex, cancellationToken);
                requestedRunIndex = runIndex;
            }
            else
            {
                runIndex = requestedRunIndex.Value;
            }
            var gameSave = new BackupGameSave(Path.Combine(AppContext.BaseDirectory, "save-bridge"),
                options.EffectiveTuning.GameConnectionTimeoutSeconds, options.EffectiveTuning.GameCompletionTimeoutSeconds,
                options.EffectiveTuning.GameQueueTimeoutSeconds,
                options.GameSaveCountdown
                    ? LanguageCatalog.Get(options.NameLanguage).Tag : null, request.ScheduledUtc);
            var timing = new BackupTimingPreparation((path, token) => request.SaveGame && options.SaveGameBeforeBackup
                ? gameSave.PrepareAsync(path, token) : Task.FromResult(new GameSaveResult("disabled")));
            BackupSourcePreparation? prepareSource = request.RequireActiveGame || request.ScheduledUtc is not null
                || request.SaveGame && options.SaveGameBeforeBackup ? async (path, token) =>
            {
                var prepared = await timing.PrepareAsync(path, request.ScheduledUtc, request.RequireActiveGame, token);
                return new BackupPreparationResult(prepared.Outcome, prepared.Detail);
            } : null;
            if (request.RuntimeTicket is not null)
            {
                var guarded = new GuardedGamePreparation(new GameSaveClient(Path.Combine(AppContext.BaseDirectory, "save-bridge"),
                    options.EffectiveTuning.GameConnectionTimeoutSeconds, options.EffectiveTuning.GameCompletionTimeoutSeconds,
                    options.EffectiveTuning.GameQueueTimeoutSeconds,
                    options.GameSaveCountdown ? LanguageCatalog.Get(options.NameLanguage).Tag : null,
                    runtimeTicket: request.RuntimeTicket,
                    preparationAllowed: token => PzTools.Scheduling.RuntimePreparationPermit.IsCurrentAsync(
                        request.RuntimeAuthority!, request.RuntimeGeneration!.Value, options.Sources.Single(source => source.Id.Equals(request.SourceId, StringComparison.OrdinalIgnoreCase)).Path, token, request.RuntimeTicket)));
                prepareSource = async (path, token) =>
                {
                    try
                    {
                        var prepared = await guarded.PrepareAsync(path, options.SaveGameBeforeBackup, token);
                        return new BackupPreparationResult(prepared.Outcome, prepared.Detail);
                    }
                    catch (GameSaveException exception) when (exception.Code is "runtime-deferred" or "queue-timeout")
                    { throw new BackupPreparationDeferredException(exception.Message, exception.Diagnostics); }
                };
            }
            var result = await new OneShotBackupService(new UsnJournalReader(), prepareSource,
                RevisionCharacterMetadataCollector.PopulateAsync).RunAsync(
                options,
                request.SourceId,
                new BackupExecutionOptions(requestedRunIndex, request.Revision),
                cancellationToken);
            runIndex = result.RunIndex;
            var outcome = result.Revision is null
                ? ProcessOutcome.NoChange
                : ProcessOutcome.Succeeded;
            await CompleteOwnedWorkflowAsync(outcome, null);
            await BestEffortProcessTelemetry.TryRecordAsync(
                options.RepositoryPath,
                "backup-worker",
                runIndex,
                "backup.completed",
                JsonSerializer.Serialize(new { outcome, result.Revision }),
                request.Configuration.ConfigPath,
                new ProcessTelemetrySettings(
                    options.Telemetry.Enabled,
                    options.Telemetry.RetainRuns,
                    options.Telemetry.MaxDatabaseMib));
            Console.WriteLine(ProcessResultJson.Serialize(
                ProcessResultEnvelope<OneShotBackupResult>.Success(
                    "backup-worker", runIndex, outcome, started, result)));
            return ProcessExitCodes.FromOutcome(outcome);
        }
        catch (BackupPreparationDeferredException exception) when (guardedRequest)
        {
            await CompleteOwnedWorkflowAsync(ProcessOutcome.Skipped, "runtime-deferred");
            var deferred = ProcessResultEnvelope<object>.Success("backup-worker", runIndex, ProcessOutcome.Skipped,
                started, new { code = "runtime-deferred", reason = exception.Message })
                with { ScheduleDisposition = ScheduleDisposition.Preserve };
            Console.WriteLine(ProcessResultJson.Serialize(deferred));
            return ProcessExitCodes.Success;
        }
        catch (AutomaticBackupSkippedException exception)
        {
            await CompleteOwnedWorkflowAsync(ProcessOutcome.Skipped, "automatic-backup-inactive");
            Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Success(
                "backup-worker", runIndex, ProcessOutcome.Skipped, started,
                new { code = "automatic-backup-inactive", reason = exception.Message })));
            return ProcessExitCodes.FromOutcome(ProcessOutcome.Skipped);
        }
        catch (OperationCanceledException)
        {
            await CompleteOwnedWorkflowAsync(ProcessOutcome.Cancelled, "cancelled");
            return WriteBackupFailure(
                runIndex, ProcessOutcome.Cancelled, started,
                "cancelled", "Operation cancelled.", guardedRequest ? ScheduleDisposition.CompletionUnknown : ScheduleDisposition.Default);
        }
        catch (RepositoryBusyException exception)
        {
            await CompleteOwnedWorkflowAsync(ProcessOutcome.Busy, "repository-busy");
            Console.WriteLine(ProcessResultJson.Serialize(
                ProcessResultEnvelope<object>.Success(
                    "backup-worker", runIndex, ProcessOutcome.Busy, started,
                    new { code = "repository-busy", message = exception.Message })));
            return ProcessExitCodes.Busy;
        }
        catch (BackupConfigurationException exception)
        {
            await CompleteOwnedWorkflowAsync(ProcessOutcome.Failed, "invalid-arguments");
            WriteBackupFailure(
                runIndex, ProcessOutcome.Failed, started,
                "invalid-arguments", exception.Message);
            return ProcessExitCodes.InvalidArguments;
        }
        catch (GameSaveException exception)
        {
            var code = "game-save-" + exception.Code;
            await CompleteOwnedWorkflowAsync(ProcessOutcome.Failed, code);
            return WriteBackupFailure(runIndex, ProcessOutcome.Failed, started, code, exception.Message,
                guardedRequest ? ScheduleDisposition.CompletionUnknown : ScheduleDisposition.Default);
        }
        catch (Exception exception)
        {
            await CompleteOwnedWorkflowAsync(ProcessOutcome.Failed, "backup-failed");
            return WriteBackupFailure(
                runIndex, ProcessOutcome.Failed, started,
                "backup-failed", exception.Message,
                guardedRequest ? ScheduleDisposition.CompletionUnknown : ScheduleDisposition.Default);
        }

        async Task CompleteOwnedWorkflowAsync(ProcessOutcome outcome, string? failureCode)
        {
            if (ownedWorkflowRepository is null) return;
            try
            {
                var workflow = await ownedWorkflowRepository.ReadWorkflowAsync(
                    runIndex, CancellationToken.None);
                if (workflow.Status != WorkflowStatus.Running) return;
                var status = outcome switch
                {
                    ProcessOutcome.Succeeded => WorkflowStatus.Succeeded,
                    ProcessOutcome.NoChange => WorkflowStatus.NoChange,
                    ProcessOutcome.Skipped => WorkflowStatus.Skipped,
                    ProcessOutcome.Busy => WorkflowStatus.Busy,
                    ProcessOutcome.Cancelled => WorkflowStatus.Cancelled,
                    _ => WorkflowStatus.Failed,
                };
                var stage = (await ownedWorkflowRepository.ReadWorkflowStagesAsync(
                        runIndex, CancellationToken.None))
                    .SingleOrDefault(item => item.Producer == "backup-worker"
                        && item.Status == WorkflowStatus.Running);
                if (stage is not null)
                    await ownedWorkflowRepository.CompleteWorkflowStageAsync(
                        runIndex, "backup-worker", status, failureCode, CancellationToken.None);
                await ownedWorkflowRepository.CompleteWorkflowAsync(
                    runIndex, "backup-worker", status, failureCode, CancellationToken.None);
            }
            catch
            {
                // 원래 worker 결과를 보존합니다. 다음 복구가 고아 workflow를 정리합니다.
            }
        }
    }

    private static int WriteBackupFailure(
        long runIndex,
        ProcessOutcome outcome,
        DateTimeOffset started,
        string code,
        string message, ScheduleDisposition disposition = ScheduleDisposition.Default)
    {
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Failure(
                "backup-worker", Math.Max(1, runIndex), outcome, started, code, message)
                with { ScheduleDisposition = disposition }));
        return ProcessExitCodes.FromOutcome(outcome);
    }

    private static async Task<int> RestoreAsync(
        string[] arguments,
        CancellationToken cancellationToken)
    {
        var started = DateTimeOffset.UtcNow;
        var runIndex = 1L;
        string? targetPath = null;
        string? telemetryIdentity = null;
        string? configuration = null;
        string? saveId = null;
        string? currentRelativePath = null;
        ProcessTelemetrySession? telemetry = null;
        try
        {
            var values = RepositoryCommandArguments.Parse(
                arguments,
                "--repository",
                "--source-id",
                "--revision",
                "--target",
                "--run-index",
                "--config",
                "--control-db",
                "--telemetry-identity");
            var repositoryPath = RepositoryCommandArguments.Required(values, "--repository");
            targetPath = RepositoryCommandArguments.Required(values, "--target");
            saveId = RepositoryCommandArguments.Required(values, "--source-id");
            runIndex = values.TryGetValue("--run-index", out var runValue)
                ? long.Parse(runValue, System.Globalization.CultureInfo.InvariantCulture)
                : await new RunIndexAllocator(values.GetValueOrDefault("--control-db"))
                    .AllocateAsync(cancellationToken: cancellationToken);
            telemetryIdentity = values.GetValueOrDefault("--telemetry-identity")
                ?? PzToolsPathLayout.CreateDefault().CreateOperationIdentity(
                    "restore-worker", $"restore-{runIndex}");
            configuration = values.GetValueOrDefault("--config");
            telemetry = await ProcessTelemetrySession.StartAsync(
                telemetryIdentity, "restore-worker", runIndex, configuration);
            telemetry.RecordEvent("run.started");
            await using var heartbeat = ProcessTelemetryHeartbeat.Start(telemetry);
            var repository = await RepositoryDatabase.OpenExistingAsync(
                repositoryPath,
                cancellationToken);
            var source = await repository.GetSourceAsync(
                saveId,
                cancellationToken);
            var revision = RepositoryCommandArguments.RequiredInt64(values, "--revision");
            Task ObserveRestoreAsync(RestoreProgress progress, CancellationToken _)
            {
                currentRelativePath = progress.RelativePath;
                telemetry.SetProgress("restore", progress.CompletedItems,
                    progress.TotalItems, progress.CompletedBytes,
                    progress.TotalBytes, progress.RelativePath);
                return Task.CompletedTask;
            }
            var mutex = await OperationMutexSet.TryRunAsync(
                [
                    new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repositoryPath),
                    new OperationMutexRequest(OperationMutexScope.SaveWrite, targetPath),
                ],
                async token =>
                {
                    // Detached maintenance lanes use the writer lease. Keep it
                    // through pack reads and publication, not just catalog lookup.
                    await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
                    return await new SafeRevisionRestoreService().RestoreReplacingAsync(
                        repository, source.SourceId, revision, targetPath,
                        ObserveRestoreAsync, token);
                },
                cancellationToken);
            if (!mutex.Acquired)
            {
                telemetry.RecordEvent("run.busy");
                Console.WriteLine(ProcessResultJson.Serialize(
                    ProcessResultEnvelope<SafeRestoreResult>.Success(
                        "restore-worker", runIndex, ProcessOutcome.Busy, started)));
                return ProcessExitCodes.Busy;
            }
            telemetry.RecordEvent("run.committed", JsonSerializer.Serialize(mutex.Value));
            Console.WriteLine(ProcessResultJson.Serialize(
                ProcessResultEnvelope<SafeRestoreResult>.Success(
                    "restore-worker", runIndex, ProcessOutcome.Succeeded, started, mutex.Value)));
            return ProcessExitCodes.Success;
        }
        catch (OperationCanceledException)
        {
            telemetry?.RecordEvent("run.cancelled");
            return WriteFailure(ProcessOutcome.Cancelled, "cancelled", "Restore was cancelled.");
        }
        catch (RepositoryBusyException)
        {
            telemetry?.RecordEvent("run.busy");
            Console.WriteLine(ProcessResultJson.Serialize(
                ProcessResultEnvelope<SafeRestoreResult>.Success(
                    "restore-worker", runIndex, ProcessOutcome.Busy, started)));
            return ProcessExitCodes.Busy;
        }
        catch (Exception exception) when (
            exception is ArgumentException or FormatException or OverflowException)
        {
            RecordRestoreFailure("invalid-arguments", exception);
            _ = WriteFailure(ProcessOutcome.Failed, "invalid-arguments", exception.Message);
            return ProcessExitCodes.InvalidArguments;
        }
        catch (Exception exception)
        {
            RecordRestoreFailure("restore-failed", exception);
            return WriteFailure(ProcessOutcome.Failed, "restore-failed", exception.Message);
        }
        finally
        {
            if (telemetry is not null) await telemetry.DisposeAsync();
        }

        void RecordRestoreFailure(string code, Exception exception)
        {
            telemetry?.RecordEvent("run.failed", FailureTelemetry.FromException(
                code, exception, status: "Failed", phase: "restore",
                path: currentRelativePath, operation: "restore", saveId: saveId));
        }

        int WriteFailure(ProcessOutcome outcome, string code, string message)
        {
            Console.WriteLine(ProcessResultJson.Serialize(
                ProcessResultEnvelope<object>.Failure(
                    "restore-worker", Math.Max(1, runIndex), outcome, started, code, message)));
            return ProcessExitCodes.FromOutcome(outcome);
        }
    }

    private static async Task<int> VerifyAsync(
        string[] arguments,
        CancellationToken cancellationToken)
    {
        var values = RepositoryCommandArguments.Parse(arguments, "--repository");
        var repository = await RepositoryDatabase.OpenExistingAsync(
            RepositoryCommandArguments.Required(values, "--repository"),
            cancellationToken);
        var result = await new RepositoryVerifier().VerifyAsync(repository, cancellationToken);
        Console.WriteLine(JsonSerializer.Serialize(result, JsonOptions));
        return result.IsValid ? 0 : 3;
    }

    private static async Task<int> PruneAsync(
        string[] arguments,
        CancellationToken cancellationToken)
    {
        var values = RepositoryCommandArguments.Parse(
            arguments,
            "--repository",
            "--source-id",
            "--keep");
        var repositoryPath = RepositoryCommandArguments.Required(values, "--repository");
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath, cancellationToken);
        var sourceKey = RepositoryCommandArguments.Required(values, "--source-id");
        var keepLatest = checked((int)RepositoryCommandArguments.RequiredInt64(values, "--keep"));
        var result = await OperationMutexSet.TryRunAsync(
            [new(OperationMutexScope.RepositoryAccess, repositoryPath)],
            async token =>
            {
                await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
                var source = await repository.GetSourceAsync(sourceKey, token);
                return await repository.PruneRevisionsAsync(lease, source.SourceId, keepLatest, token);
            }, cancellationToken);
        if (!result.Acquired) throw new RepositoryBusyException(repositoryPath);
        Console.WriteLine(JsonSerializer.Serialize(result.Value, JsonOptions));
        return 0;
    }

    private static async Task<int> GarbageCollectAsync(
        string[] arguments,
        CancellationToken cancellationToken)
    {
        var values = RepositoryCommandArguments.Parse(arguments, "--repository");
        var repositoryPath = RepositoryCommandArguments.Required(values, "--repository");
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath, cancellationToken);
        var result = await OperationMutexSet.TryRunAsync(
            [new(OperationMutexScope.RepositoryAccess, repositoryPath)],
            async token =>
            {
                await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
                return await repository.CollectGarbageAsync(lease, token);
            }, cancellationToken);
        if (!result.Acquired) throw new RepositoryBusyException(repositoryPath);
        Console.WriteLine(JsonSerializer.Serialize(result.Value, JsonOptions));
        return result.Value!.FilesThatCouldNotBeDeleted.Count == 0 ? 0 : 4;
    }

    private static int ValidateConfiguration(string[] arguments)
    {
        var request = ConfigurationArguments.Parse(arguments);
        var options = BackupConfiguration.Load(
            request.RepositoryPath,
            request.ConfigPath,
            request.Overrides,
            Path.Combine(PzToolsPathLayout.CreateDefault().DataRoot, "settings.toml"));
        Console.WriteLine(
            $"Configuration is valid: {options.Sources.Count:N0} source(s), "
            + $"repository '{options.RepositoryPath}'.");
        return 0;
    }

    private static int ShowConfiguration(string[] arguments)
    {
        var request = ConfigurationArguments.Parse(arguments);
        var options = BackupConfiguration.Load(
            request.RepositoryPath,
            request.ConfigPath,
            request.Overrides,
            Path.Combine(PzToolsPathLayout.CreateDefault().DataRoot, "settings.toml"));
        Console.Write(BackupConfiguration.Serialize(options));
        return 0;
    }

    private static int ShowUsageError()
    {
        Console.Error.WriteLine("Invalid arguments. Run with --help for usage.");
        return 64;
    }

    private static void WriteError(string code, string message)
    {
        Console.Error.WriteLine(JsonSerializer.Serialize(
            new { success = false, code, message },
            JsonOptions));
    }

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
}
