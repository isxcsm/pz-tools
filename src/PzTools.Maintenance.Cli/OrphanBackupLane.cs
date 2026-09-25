using System.Diagnostics;
using System.Text.Json;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;

internal static class OrphanBackupLane
{
    public static async Task<(ProcessOutcome Outcome, MaintenanceLaneResult? Result, long RunIndex)> RunAsync(
        string repositoryPath, string savesRoot, string? controlDatabasePath, string? configurationPath,
        MaintenanceOptions? options = null)
    {
        options ??= new MaintenanceOptions();
        options.Validate();
        const string lane = "OrphanBackups";
        const string owner = "maintenance-lane-OrphanBackups";
        var acquired = await NamedMutexRunner.TryRunAsync(
            MaintenanceLaneSignal.MutexName(repositoryPath, lane), async _ =>
            {
                using var cancellation = new CancellationTokenSource();
                using var watch = MaintenanceLaneSignal.WatchForYield(repositoryPath, lane, cancellation);
                var access = await OperationMutexSet.TryRunAsync(
                    [new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repositoryPath)], async token =>
                    {
                        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath, token);
                        await repository.RecoverAbandonedWorkflowsAsync(owner, cancellationToken: token);
                        var run = await new RunIndexAllocator(controlDatabasePath).AllocateAsync(cancellationToken: token);
                        await repository.ReserveWorkflowAsync("maintenance-lane", null, owner, null, run, token);
                        await repository.AttachWorkflowStageAsync(run, owner, token);
                        var timer = Stopwatch.StartNew();
                        try
                        {
                            var recovery = await new InterruptedOperationRecoveryService().RunUnderRepositoryLockAsync(
                                repository, savesRoot, token, collectGarbage: false);
                            if (recovery.Busy) throw new RepositoryBusyException(repositoryPath);
                            if (recovery.RecoveredWorkflows + recovery.RecoveredSaves + recovery.DeletedArtifacts > 0 || recovery.Problems.Count > 0)
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                    recovery.Problems.Count == 0 ? "maintenance.recovery.completed" : "maintenance.recovery.failed",
                                    JsonSerializer.Serialize(recovery), configurationPath);
                            await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
                            var result = await new OrphanBackupCleanupService().RunAsync(repository, lease, savesRoot, token,
                                item => BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                    "maintenance.orphanbackups.removed", JsonSerializer.Serialize(new
                                    {
                                        saveId = item.SaveId,
                                        removedRevisions = item.Revisions,
                                    }), configurationPath));
                            var housekeeping = await new RepositoryHousekeepingService().RunAsync(
                                repository, lease, null, run, options, token);
                            var failedFiles = result.FilesThatCouldNotBeDeleted
                                .Concat(housekeeping.FilesThatCouldNotBeDeleted).ToArray();
                            var status = failedFiles.Length == 0
                                ? WorkflowStatus.Succeeded : WorkflowStatus.Degraded;
                            await FinishAsync(status);
                            if (housekeeping.AffectedItems > 0 || housekeeping.Vacuum.Status == "compacted")
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                    "maintenance.database.completed", JsonSerializer.Serialize(new
                                    {
                                        outcome = status.ToString(),
                                        database = housekeeping.ToDetail(),
                                        failureCode = failedFiles.Length == 0 ? null : "file-delete-failed",
                                    }), configurationPath);
                            if (failedFiles.Length > 0)
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                "maintenance.orphanbackups.completed", JsonSerializer.Serialize(new
                                {
                                    outcome = status.ToString(),
                                    removed = result.Removed,
                                    result.DeferredSources,
                                    failureCode = "file-delete-failed",
                                    failedFileCount = failedFiles.Length,
                                    failedFiles = failedFiles.Take(8).Select(Path.GetFileName).ToArray(),
                                }), configurationPath);
                            return (status == WorkflowStatus.Succeeded ? ProcessOutcome.Succeeded : ProcessOutcome.Degraded,
                                (MaintenanceLaneResult?)new MaintenanceLaneResult(lane, status.ToString(),
                                    timer.ElapsedMilliseconds, result.Removed.Sum(item => item.Revisions) + housekeeping.AffectedItems,
                                    housekeeping.ToDetail()), run);
                        }
                        catch (Exception exception)
                        {
                            var status = exception is OperationCanceledException ? WorkflowStatus.Cancelled
                                : exception is RepositoryBusyException ? WorkflowStatus.Busy : WorkflowStatus.Failed;
                            await FinishAsync(status);
                            if (status == WorkflowStatus.Failed)
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                    "maintenance.orphanbackups.failed", FailureTelemetry.FromException(
                                        "orphan-cleanup-failed", exception, operation: "maintenance"), configurationPath);
                            return (status == WorkflowStatus.Cancelled ? ProcessOutcome.Cancelled
                                    : status == WorkflowStatus.Busy ? ProcessOutcome.Busy : ProcessOutcome.Failed,
                                (MaintenanceLaneResult?)new MaintenanceLaneResult(lane, status.ToString(),
                                    timer.ElapsedMilliseconds, 0, exception.GetType().Name), run);
                        }

                        async Task FinishAsync(WorkflowStatus status)
                        {
                            await repository.CompleteWorkflowStageAsync(run, owner, status, cancellationToken: CancellationToken.None);
                            await repository.CompleteWorkflowAsync(run, owner, status, cancellationToken: CancellationToken.None);
                        }
                    }, cancellation.Token);
                return access.Acquired ? access.Value : (ProcessOutcome.Busy, (MaintenanceLaneResult?)null, 0L);
            });
        return acquired.Acquired ? acquired.Value : (ProcessOutcome.Busy, null, 0L);
    }
}
