using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Projections;
using PzTools.Zomboid.Archive;

namespace PzTools.App.Core;

public enum OperationScope { RepositoryRead, RepositoryWrite, SaveWrite }

public sealed record AppOperationResult(
    string OperationId,
    long RunIndex,
    ProcessOutcome Outcome,
    int? ExitCode,
    string? Error,
    string? ErrorMessage = null);

public sealed class OperationCoordinator(
    RepositoryDatabase repository,
    string workerDirectory,
    TelemetrySourceCatalog telemetrySources,
    IManagedProcessLauncher launcher,
    RunIndexAllocator runIndexes,
    string operationsRoot,
    AppRuntimeOptions? runtimeOptions = null,
    LogInboxStore? diagnostics = null,
    Func<string, string?>? gameVersion = null)
{
    private readonly AppRuntimeOptions runtime = runtimeOptions ?? new();
    private readonly ConcurrentDictionary<string, SemaphoreSlim> gates =
        new(StringComparer.OrdinalIgnoreCase);
    private int runningDeletions;
    public bool IsDeletionRunning => Volatile.Read(ref runningDeletions) > 0;

    public async Task RefreshStateAsync(string stateDatabasePath, string savesRoot, CancellationToken cancellationToken = default)
    {
        // 정기 runner와 같은 StateCollection mutex를 사용합니다. UI에서 주기 설정이나 DB를 직접 바꾸지 않습니다.
        for (var attempt = 0; attempt < runtime.StateRefreshAttempts; attempt++)
        {
            var runIndex = await runIndexes.AllocateAsync(cancellationToken: cancellationToken);
            var execution = await RunAndValidateAsync(Path.Combine(workerDirectory, "PzTools.State.Runner.exe"),
                ["--state-db", Path.GetFullPath(stateDatabasePath), "--saves-root", Path.GetFullPath(savesRoot),
                 "--worker-directory", workerDirectory, "--run-index", runIndex.ToString(System.Globalization.CultureInfo.InvariantCulture)],
                "state-runner", runIndex, cancellationToken);
            if (execution.Outcome == ProcessOutcome.Succeeded) return;
            if (execution.Outcome != ProcessOutcome.Busy)
                throw new IOException(execution.ErrorMessage ?? execution.Error ?? "State refresh failed.");
            await Task.Delay(runtime.StateRefreshRetryMs, cancellationToken);
        }
        throw new IOException("State refresh remained busy. The next scheduled collection will retry.");
    }

    public async Task<SaveDeletionResult> DeleteSaveAsync(
        string savesRoot, string saveId, CancellationToken cancellationToken = default,
        IProgress<SaveDeletionProgress>? progress = null)
    {
        var sourcePath = Path.GetFullPath(Path.Combine(savesRoot, saveId.Replace('/', Path.DirectorySeparatorChar)));
        Interlocked.Increment(ref runningDeletions);
        try
        {
            await using var admission = await TryAcquireAsync([
                (OperationScope.RepositoryWrite, repository.RepositoryPath),
                (OperationScope.SaveWrite, sourcePath)], cancellationToken);
            if (admission is null) throw new IOException("Another operation is using this save.");
            var result = await OperationMutexSet.TryRunAsync([
                new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repository.RepositoryPath),
                new OperationMutexRequest(OperationMutexScope.SaveWrite, sourcePath)],
                async token =>
                {
                    await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
                    await using var deletion = await repository.PrepareSaveRevisionDeletionAsync(
                        lease, saveId.Replace('\\', '/'), sourcePath, token);
                    // The caller's latest-only mailbox owns the UI window. Keep its counters
                    // current without a second sampling delay; no dispatcher/DB writes occur here.
                    var deleted = SaveDeletionService.DeletePermanently(savesRoot, saveId, token, progress,
                        TimeSpan.Zero);
                    progress?.Report(new(SaveDeletionPhase.DeletingBackups));
                    try { await deletion.CommitAsync(); }
                    catch (Exception exception)
                    {
                        throw new SaveBackupDeletionFailedException(deleted.SourcePath, exception);
                    }
                    return deleted;
                },
                cancellationToken);
            return result.Acquired ? result.Value! : throw new IOException("Another operation is using this save.");
        }
        finally { Interlocked.Decrement(ref runningDeletions); }
    }

    public async Task DeleteRevisionAsync(long sourceId, long revision, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref runningDeletions);
        try
        {
            await using var admission = await TryAcquireAsync(
                [(OperationScope.RepositoryWrite, repository.RepositoryPath)], cancellationToken);
            if (admission is null) throw new IOException("Another operation is using the backup repository.");
            var result = await OperationMutexSet.TryRunAsync([
                new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repository.RepositoryPath)],
                async token =>
                {
                    await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
                    await repository.MarkRevisionDeletedAsync(lease, sourceId, revision, cancellationToken: token);
                    return true;
                }, cancellationToken);
            if (!result.Acquired) throw new IOException("Another operation is using the backup repository.");
        }
        finally { Interlocked.Decrement(ref runningDeletions); }
    }

    public async Task<int> DeleteAllRevisionsAsync(
        long sourceId, string saveId, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref runningDeletions);
        try
        {
            await using var admission = await TryAcquireAsync(
                [(OperationScope.RepositoryWrite, repository.RepositoryPath)], cancellationToken);
            if (admission is null) throw new IOException("Another operation is using the backup repository.");
            var result = await OperationMutexSet.TryRunAsync([
                new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repository.RepositoryPath)],
                async token =>
                {
                    await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
                    return await repository.MarkAllRevisionsDeletedAsync(lease, sourceId, saveId, token);
                }, cancellationToken);
            return result.Acquired ? result.Value : throw new IOException("Another operation is using the backup repository.");
        }
        finally { Interlocked.Decrement(ref runningDeletions); }
    }

    public async Task RenameRevisionAsync(
        long sourceId, long revision, string displayName,
        CancellationToken cancellationToken = default)
    {
        await using var admission = await TryAcquireAsync(
            [(OperationScope.RepositoryWrite, repository.RepositoryPath)], cancellationToken);
        if (admission is null) throw new IOException("Another operation is using the backup repository.");
        var result = await OperationMutexSet.TryRunAsync([
            new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repository.RepositoryPath)],
            async token =>
            {
                await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
                await repository.RenameRevisionAsync(lease, sourceId, revision, displayName, token);
                return true;
            }, cancellationToken);
        if (!result.Acquired) throw new IOException("Another operation is using the backup repository.");
    }

    public async Task<ArchiveInspection> InspectArchiveAsync(
        string archivePath,
        CancellationToken cancellationToken = default)
    {
        var identity = Path.GetFullPath(archivePath);
        var runIndex = await runIndexes.AllocateAsync(cancellationToken: cancellationToken);
        var operationId = $"archive-inspect-{Guid.NewGuid():N}";
        var sourceKey = operationId;
        var telemetryIdentity = CreateTelemetryIdentity("archive-worker", operationId);
        var telemetryPath = Path.Combine(
            ComponentRuntimePaths.GetComponentDirectory(telemetryIdentity, "archive-worker"),
            "telemetry.db");
        var workflow = new WorkflowOperation(
            operationId, "inspect", runIndex,
            OperationStatus.Running, DateTimeOffset.UtcNow);
        telemetrySources.Register(new TelemetrySourceRegistration(
            sourceKey, "archive-worker", telemetryIdentity, telemetryPath,
            TelemetryDatabaseKind.Process, true, workflow, Transient: true));
        var finalStatus = OperationStatus.Running;
        try
        {
            var execution = await RunAndValidateAsync(
                Path.Combine(workerDirectory, "PzTools.Zomboid.Archive.Cli.exe"),
                [
                    "inspect", "--archive", identity,
                    "--run-index", runIndex.ToString(
                        System.Globalization.CultureInfo.InvariantCulture),
                    "--telemetry-identity", telemetryIdentity,
                ],
                "archive-worker",
                runIndex,
                cancellationToken);
            finalStatus = ToOperationStatus(execution.Outcome);
            if (execution.Outcome != ProcessOutcome.Succeeded
                || execution.Result.ValueKind != JsonValueKind.Object)
            {
                throw new InvalidDataException(
                    execution.ErrorMessage ?? execution.Error ?? "Archive inspection failed.");
            }
            return JsonSerializer.Deserialize<ArchiveInspection>(
                    execution.Result.GetRawText(), ProcessResultJson.Options)
                ?? throw new InvalidDataException("Archive inspection returned no result.");
        }
        catch (OperationCanceledException)
        {
            finalStatus = OperationStatus.Cancelled;
            throw;
        }
        catch
        {
            finalStatus = OperationStatus.Failed;
            throw;
        }
        finally
        {
            telemetrySources.SetWorkflow(sourceKey, workflow with
            {
                Status = finalStatus,
                CompletedUtc = DateTimeOffset.UtcNow,
            });
        }
    }

    public async Task<AppOperationResult> BackupAsync(
        string saveId,
        string sourcePath,
        CancellationToken cancellationToken = default,
        string? operationId = null)
    {
        operationId ??= $"manual-backup:{Guid.NewGuid():N}";
        var runIndex = await runIndexes.AllocateAsync(cancellationToken: cancellationToken);
        await using var admission = await TryAcquireAsync(
            [(OperationScope.RepositoryWrite, repository.RepositoryPath)], cancellationToken);
        if (admission is null)
            return new AppOperationResult(operationId, 0, ProcessOutcome.Busy, null, "operation-busy");

        var workflow = await repository.ReserveWorkflowAsync(
            "manual-backup", null, "backup-worker", operationId, runIndex, cancellationToken);
        var workflowView = new WorkflowOperation(
            operationId, "backup", workflow.RunIndex, OperationStatus.Running,
            workflow.StartedUtc);
        telemetrySources.SetWorkflow("backup-worker", workflowView);
        var finalStatus = OperationStatus.Running;
        try
        {
            var execution = await RunAndValidateAsync(
                Path.Combine(workerDirectory, "PzTools.Backup.Runner.exe"),
                [
                    "--repository", repository.RepositoryPath,
                    "--source-id", saveId,
                    "--source", $"{saveId}={Path.GetFullPath(sourcePath)}",
                    "--save-game",
                    "--run-index", workflow.RunIndex.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    "--worker-directory", workerDirectory,
                    // Saves carry no version of their own; record what the game reports while this save is loaded.
                    .. gameVersion?.Invoke(sourcePath) is { } version ? new[] { "--game-version", version } : [],
                ],
                "backup-runner",
                workflow.RunIndex,
                cancellationToken);
            var outcome = execution.Outcome;
            finalStatus = ToOperationStatus(outcome);
            await CompleteWorkflowAsync(
                workflow.RunIndex, "backup-worker", outcome, execution.Error);
            return new AppOperationResult(
                operationId, workflow.RunIndex, outcome, execution.ExitCode,
                execution.Error, execution.ErrorMessage);
        }
        catch (OperationCanceledException)
        {
            finalStatus = OperationStatus.Cancelled;
            await CompleteWorkflowAsync(
                workflow.RunIndex, "backup-worker", ProcessOutcome.Cancelled, "cancelled");
            throw;
        }
        catch (Exception exception)
        {
            finalStatus = OperationStatus.Failed;
            try
            {
                await CompleteWorkflowAsync(workflow.RunIndex, "backup-worker",
                    ProcessOutcome.Failed, "backup-dispatch-failed");
            }
            catch (Exception cleanupException)
            {
                throw new AggregateException("Backup failed and its workflow could not be finalized.",
                    exception, cleanupException);
            }
            throw;
        }
        finally
        {
            telemetrySources.SetWorkflow(
                "backup-worker", workflowView with
                {
                    Status = finalStatus,
                    CompletedUtc = DateTimeOffset.UtcNow,
                });
        }
    }

    public async Task<AppOperationResult> RestoreAsync(
        long sourceId,
        long revision,
        string targetPath,
        CancellationToken cancellationToken = default,
        string? operationId = null)
    {
        operationId ??= $"restore:{Guid.NewGuid():N}";
        var runIndex = await runIndexes.AllocateAsync(cancellationToken: cancellationToken);
        await using var admission = await TryAcquireAsync(
            [
                (OperationScope.RepositoryRead, repository.RepositoryPath),
                (OperationScope.SaveWrite, targetPath),
            ], cancellationToken);
        if (admission is null)
            return new AppOperationResult(operationId, 0, ProcessOutcome.Busy, null, "operation-busy");

        var sourceKey = $"restore-{Guid.NewGuid():N}";
        var telemetryIdentity = CreateTelemetryIdentity("restore-worker", sourceKey);
        var telemetryPath = Path.Combine(
            ComponentRuntimePaths.GetComponentDirectory(telemetryIdentity, "restore-worker"),
            "telemetry.db");
        var workflow = new WorkflowOperation(operationId, "restore", runIndex,
            OperationStatus.Running, DateTimeOffset.UtcNow);
        telemetrySources.Register(new TelemetrySourceRegistration(
            sourceKey, "restore-worker", telemetryIdentity, telemetryPath,
            TelemetryDatabaseKind.Process, true, workflow, Transient: true));
        var finalStatus = OperationStatus.Running;
        try
        {
            // 복구 CLI의 --source-id는 숫자형 DB ID가 아니라 논리 세이브 키입니다.
            var source = await repository.GetSourceByIdAsync(sourceId, cancellationToken);
            var execution = await RunAndValidateAsync(
                Path.Combine(workerDirectory, "PzTools.Backup.Cli.exe"),
                [
                    "restore",
                    "--repository", repository.RepositoryPath,
                    "--source-id", source.SourceKey,
                    "--revision", revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    "--target", Path.GetFullPath(targetPath),
                    "--run-index", runIndex.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    "--telemetry-identity", telemetryIdentity,
                ],
                "restore-worker",
                runIndex,
                cancellationToken);
            var outcome = execution.Outcome;
            finalStatus = ToOperationStatus(outcome);
            return new AppOperationResult(
                operationId, runIndex, outcome, execution.ExitCode,
                execution.Error, execution.ErrorMessage);
        }
        catch (OperationCanceledException)
        {
            finalStatus = OperationStatus.Cancelled;
            throw;
        }
        catch
        {
            finalStatus = OperationStatus.Failed;
            throw;
        }
        finally
        {
            telemetrySources.SetWorkflow(sourceKey, workflow with
            {
                Status = finalStatus,
                CompletedUtc = DateTimeOffset.UtcNow,
            });
        }
    }

    public Task<AppOperationResult> ExportArchiveAsync(
        long sourceId,
        long revision,
        string outputPath,
        CancellationToken cancellationToken = default,
        string? operationId = null) =>
        RunArchiveAsync(
            "export", repository.RepositoryPath, OperationScope.RepositoryRead,
            [
                "export",
                "--repository", repository.RepositoryPath,
                "--source-id", sourceId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--revision", revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--output", Path.GetFullPath(outputPath),
            ], cancellationToken, operationId: operationId);

    public Task<AppOperationResult> ExportLiveArchiveAsync(
        string sourcePath, string saveId, string outputPath,
        CancellationToken cancellationToken = default,
        string? operationId = null) =>
        RunArchiveAsync(
            "export", Path.GetFullPath(sourcePath), OperationScope.SaveWrite,
            [
                "export-live", "--source", Path.GetFullPath(sourcePath),
                "--save-id", saveId, "--output", Path.GetFullPath(outputPath),
            ], cancellationToken, operationId: operationId);

    public Task<AppOperationResult> ImportArchiveAsync(
        string archivePath,
        string savesRoot,
        CancellationToken cancellationToken = default,
        string? operationId = null) =>
        RunArchiveAsync(
            "import", savesRoot, OperationScope.SaveWrite,
            [
                "import",
                "--archive", Path.GetFullPath(archivePath),
                "--saves-root", Path.GetFullPath(savesRoot),
            ], cancellationToken, operationId: operationId);

    public Task<AppOperationResult> RecoverCharacterAsync(
        string savesRoot, string saveId, CancellationToken cancellationToken = default,
        string? operationId = null)
    {
        var source = Path.GetFullPath(Path.Combine(savesRoot, saveId));
        return RunArchiveAsync("character-recovery", source, OperationScope.SaveWrite,
            ["--saves-root", savesRoot, "--save-id", saveId,
             "--repository", repository.RepositoryPath],
            cancellationToken, "character-recovery", "PzTools.Zomboid.Recovery.Cli.exe", operationId);
    }

    /// <summary>
    /// One recording of the running game, from start to converted file. It returns when the worker
    /// ends: after <paramref name="stopFile"/> appears, at the time limit, or when the game exits.
    /// Nothing here touches a save or the repository, so it runs alongside backups.
    /// </summary>
    /// <param name="progress">Lines the worker reports while it runs: "recording ..." and "converting".</param>
    public Task<AppOperationResult> RecordProfileAsync(
        string outputPath, string stopFile, bool detailed, int maximumSeconds,
        Action<string>? progress = null, CancellationToken cancellationToken = default, string? operationId = null) =>
        RunArchiveAsync("profile", Path.GetFullPath(outputPath), OperationScope.SaveWrite,
            [
                "record", "--output", Path.GetFullPath(outputPath), "--stop-file", Path.GetFullPath(stopFile),
                "--mode", detailed ? "detailed" : "general",
                "--max-seconds", maximumSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--bridge", Path.Combine(workerDirectory, "save-bridge"),
            ], cancellationToken, "profiler", "PzTools.Profiler.Cli.exe", operationId,
            line => { if (line.StartsWith("PROFILE\t", StringComparison.Ordinal)) progress?.Invoke(line["PROFILE\t".Length..]); });

    private async Task<AppOperationResult> RunArchiveAsync(
        string kind,
        string identity,
        OperationScope scope,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken,
        string component = "archive-worker",
        string executable = "PzTools.Zomboid.Archive.Cli.exe",
        string? operationId = null,
        Action<string>? standardOutput = null)
    {
        var prefix = component == "archive-worker" ? $"archive-{kind}" : component == "profiler" ? component : kind;
        operationId ??= $"{prefix}:{Guid.NewGuid():N}";
        var runIndex = await runIndexes.AllocateAsync(cancellationToken: cancellationToken);
        await using var admission = await TryAcquireAsync(component == "character-recovery"
            ? [(scope, identity), (OperationScope.RepositoryWrite, repository.RepositoryPath)]
            // Only one recording at a time, whatever its file is called.
            : component == "profiler" ? [(scope, Path.Combine(operationsRoot, "profiler"))]
            : [(scope, identity)], cancellationToken);
        if (admission is null)
            return new AppOperationResult(operationId, 0, ProcessOutcome.Busy, null, "operation-busy");
        var sourceKey = $"{prefix}-{Guid.NewGuid():N}";
        var telemetryIdentity = CreateTelemetryIdentity(component, sourceKey);
        var telemetryPath = Path.Combine(
            ComponentRuntimePaths.GetComponentDirectory(telemetryIdentity, component),
            "telemetry.db");
        var workflow = new WorkflowOperation(operationId, kind, runIndex,
            OperationStatus.Running, DateTimeOffset.UtcNow);
        telemetrySources.Register(new TelemetrySourceRegistration(
            sourceKey, component, telemetryIdentity, telemetryPath,
            TelemetryDatabaseKind.Process, true, workflow, Transient: true));
        var finalStatus = OperationStatus.Running;
        try
        {
            var invocation = arguments.Concat([
                "--run-index", runIndex.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--telemetry-identity", telemetryIdentity,
            ]).ToArray();
            var execution = await RunAndValidateAsync(
                Path.Combine(workerDirectory, executable),
                invocation,
                component,
                runIndex,
                cancellationToken,
                standardOutput);
            var outcome = execution.Outcome;
            finalStatus = ToOperationStatus(outcome);
            return new AppOperationResult(
                operationId, runIndex, outcome, execution.ExitCode,
                execution.Error, execution.ErrorMessage);
        }
        catch (OperationCanceledException)
        {
            finalStatus = OperationStatus.Cancelled;
            throw;
        }
        catch
        {
            finalStatus = OperationStatus.Failed;
            throw;
        }
        finally
        {
            telemetrySources.SetWorkflow(sourceKey, workflow with
            {
                Status = finalStatus,
                CompletedUtc = DateTimeOffset.UtcNow,
            });
        }
    }

    private async Task CompleteWorkflowAsync(
        long runIndex, string owner, ProcessOutcome outcome, string? error)
    {
        var workflow = await repository.ReadWorkflowAsync(runIndex);
        if (workflow.Status != WorkflowStatus.Running) return;
        var status = outcome switch
        {
            ProcessOutcome.Succeeded => WorkflowStatus.Succeeded,
            ProcessOutcome.NoChange => WorkflowStatus.NoChange,
            ProcessOutcome.Skipped => WorkflowStatus.Skipped,
            ProcessOutcome.Busy => WorkflowStatus.Busy,
            ProcessOutcome.Degraded => WorkflowStatus.Degraded,
            ProcessOutcome.Cancelled => WorkflowStatus.Cancelled,
            _ => WorkflowStatus.Failed,
        };
        var stage = (await repository.ReadWorkflowStagesAsync(runIndex))
            .SingleOrDefault(item => item.Producer == owner && item.Status == WorkflowStatus.Running);
        if (stage is not null)
            await repository.CompleteWorkflowStageAsync(runIndex, owner, status, error);
        await repository.CompleteWorkflowAsync(runIndex, owner, status, error);
    }

    private async Task<ValidatedExecution> RunAndValidateAsync(
        string executable,
        IReadOnlyList<string> arguments,
        string expectedComponent,
        long expectedRunIndex,
        CancellationToken cancellationToken,
        Action<string>? observeOutput = null)
    {
        var standardOutput = new StringBuilder();
        var standardError = new StringBuilder();
        var exit = await launcher.RunAsync(executable, arguments,
            line => { standardOutput.AppendLine(line); observeOutput?.Invoke(line); },
            line =>
            {
                standardError.AppendLine(line);
                if (standardError.Length > 8192) standardError.Remove(0, standardError.Length - 8192);
            }, cancellationToken);
        if (!exit.Started)
        {
            if (diagnostics is not null)
                await diagnostics.AppendAsync([new LogEntryView(
                    Guid.NewGuid().ToString("N"), "app-dispatch", Guid.Empty, 0, DateTimeOffset.UtcNow,
                    LogLevel.Error, expectedComponent, expectedRunIndex, "run.failed",
                    JsonSerializer.Serialize(new { failureCode = exit.FailureCode ?? "launch-failed",
                        phase = "process-launch", message = standardError.ToString(), path = executable,
                        nativeErrorCode = exit.NativeErrorCode }))]);
            // Keep the code in front of Windows' own text so the user-facing mapping can recognise a policy block.
            return new ValidatedExecution(ProcessOutcome.Failed, exit.ExitCode,
                exit.FailureCode ?? LaunchFailure.Failed,
                exit.FailureCode == LaunchFailure.Blocked ? $"{LaunchFailure.Blocked}: {standardError}" : standardError.ToString(),
                default);
        }
        try
        {
            var envelope = ProcessResultValidator.Read<JsonElement>(standardOutput.ToString(),
                expectedComponent, expectedRunIndex, exit.ExitCode, standardError.ToString());
            return new(envelope.Outcome, exit.ExitCode, envelope.Error?.Code,
                envelope.Error?.Message, envelope.Result);
        }
        catch (ProcessResultValidationException exception)
        {
            if (diagnostics is not null)
                await diagnostics.AppendAsync([new LogEntryView(
                    Guid.NewGuid().ToString("N"), "app-dispatch", Guid.Empty, 0, DateTimeOffset.UtcNow,
                    LogLevel.Error, expectedComponent, expectedRunIndex, "run.failed",
                    FailureTelemetry.FromException(exception.Code, exception, phase: "process-result"))]);
            return new(ProcessOutcome.Failed, exit.ExitCode, exception.Code, exception.Message, default);
        }
    }

    private string CreateTelemetryIdentity(string component, string operationId)
    {
        var safeId = operationId.Replace(':', '-');
        return Path.Combine(Path.GetFullPath(operationsRoot), component, safeId);
    }

    private static OperationStatus ToOperationStatus(ProcessOutcome outcome) => outcome switch
    {
        ProcessOutcome.Succeeded => OperationStatus.Succeeded,
        ProcessOutcome.NoChange => OperationStatus.NoChange,
        ProcessOutcome.Busy => OperationStatus.Busy,
        ProcessOutcome.Degraded => OperationStatus.Degraded,
        ProcessOutcome.Cancelled => OperationStatus.Cancelled,
        _ => OperationStatus.Failed,
    };

    private Task<SemaphoreAdmission?> TryAcquireAsync(
        IEnumerable<(OperationScope Scope, string Identity)> scopes,
        CancellationToken cancellationToken)
    {
        var keys = scopes.Select(scope => GateKey(scope.Scope, scope.Identity))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        return SemaphoreAdmission.TryAcquireAsync(
            keys.Select(key => gates.GetOrAdd(key, _ => new SemaphoreSlim(1, 1))), cancellationToken);
    }

    private static string GateKey(OperationScope scope, string identity)
    {
        var family = scope is OperationScope.RepositoryRead or OperationScope.RepositoryWrite
            ? "repository" : "save";
        return $"{family}:{Path.GetFullPath(identity)}";
    }

    private sealed record ValidatedExecution(
        ProcessOutcome Outcome,
        int? ExitCode,
        string? Error,
        string? ErrorMessage,
        JsonElement Result);
}
