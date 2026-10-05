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
        MaintenanceOptions? options = null, CancellationToken stopRequested = default)
    {
        options ??= new MaintenanceOptions();
        options.Validate();
        const string lane = "OrphanBackups";
        const string owner = "maintenance-lane-OrphanBackups";
        if (GameplayWorkGate.ShouldDeferMaintenance())
            return (ProcessOutcome.Skipped, new MaintenanceLaneResult(lane, "Skipped", 0, 0, "deferred-during-gameplay"), 0);
        var acquired = await NamedMutexRunner.TryRunAsync(
            MaintenanceLaneSignal.MutexName(repositoryPath, lane), async _ =>
            {
                if (GameplayWorkGate.ShouldDeferMaintenance())
                    return (ProcessOutcome.Skipped, (MaintenanceLaneResult?)new MaintenanceLaneResult(lane, "Skipped", 0, 0, "deferred-during-gameplay"), 0L);
                // A stop request ends the lane as a yield to a backup or to the game does: cancelled, at a safe point.
                using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(stopRequested);
                using var watch = MaintenanceLaneSignal.WatchForYield(repositoryPath, lane, cancellation);
                var access = await OperationMutexSet.TryRunAsync(
                    [new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repositoryPath)], async token =>
                    {
                        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath, token);
                        await repository.RecoverAbandonedWorkflowsAsync(owner, cancellationToken: token);
                        var run = await new RunIndexAllocator(controlDatabasePath).AllocateAsync(cancellationToken: token);
                        await repository.ReserveWorkflowAsync("maintenance-lane", null, owner, null, run, token);
                        // Once reserved, the workflow reaches the handler below that closes it, whatever stops the lane.
                        await repository.AttachWorkflowStageAsync(run, owner, CancellationToken.None);
                        var timer = Stopwatch.StartNew();
                        ProcessTelemetryHeartbeat? heartbeat = null;
                        var announced = false;
                        async Task StopHeartbeatAsync()
                        {
                            if (heartbeat is not null) await heartbeat.DisposeAsync();
                            heartbeat = null;
                        }
                        try
                        {
                            using var gameplayWatch = GameplayWorkGate.WatchForGameplay(cancellation);
                            token.ThrowIfCancellationRequested();
                            var recovery = await new InterruptedOperationRecoveryService().RunUnderRepositoryLockAsync(
                                repository, savesRoot, token, collectGarbage: false);
                            if (recovery.Busy) throw new RepositoryBusyException(repositoryPath);
                            if (recovery.RecoveredWorkflows + recovery.RecoveredSaves + recovery.DeletedArtifacts > 0 || recovery.Problems.Count > 0)
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                    recovery.Problems.Count == 0 ? "maintenance.recovery.completed" : "maintenance.recovery.failed",
                                    JsonSerializer.Serialize(recovery), configurationPath);
                            await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
                            var result = await new OrphanBackupCleanupService().RunAsync(repository, lease, savesRoot, token,
                                async item =>
                                {
                                    // The first confirmed orphan is when this once-a-minute check turns into real work.
                                    if (!announced)
                                    {
                                        announced = true;
                                        await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                            "maintenance.orphanbackups.started",
                                            JsonSerializer.Serialize(new { lane, planned = true }), configurationPath);
                                        heartbeat = ProcessTelemetryHeartbeat.Start(
                                            repositoryPath, owner, run, configurationPath, TimeSpan.FromSeconds(3));
                                    }
                                    await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                        "maintenance.orphanbackups.removed", JsonSerializer.Serialize(new
                                        {
                                            saveId = item.SaveId,
                                            removedRevisions = item.Revisions,
                                        }), configurationPath);
                                }, collectPaths: false);
                            // The count for every save, not only the one just backed up: otherwise a lowered count
                            // waits for that save's next automatic backup, which a save no longer played, or played
                            // with automatic backups off, never gets. The housekeeping pass below reclaims the space.
                            var retained = 0;
                            foreach (var source in await repository.ReadMaintenanceSourcesAsync(token))
                            {
                                token.ThrowIfCancellationRequested();
                                retained += (await repository.MarkRevisionsForRetentionAsync(
                                    lease, source.SourceId, options.RetainLatestRevisions, token)).MarkedDeleted;
                            }
                            var housekeeping = await new RepositoryHousekeepingService().RunAsync(
                                repository, lease, null, run, options, token);
                            // Last: the steps above free objects, and only data still needed should be copied.
                            var reclaimed = await new PackSpaceReclaimer().RunAsync(
                                repository, lease, options.PackReclamation, async plan =>
                                {
                                    announced = true;
                                    await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                        "maintenance.packreclamation.started", JsonSerializer.Serialize(new
                                        {
                                            lane, planned = true, packs = plan.Packs.Count,
                                            packBytes = plan.PackBytes, liveBytes = plan.LiveBytes,
                                        }), configurationPath);
                                    heartbeat ??= ProcessTelemetryHeartbeat.Start(
                                        repositoryPath, owner, run, configurationPath, TimeSpan.FromSeconds(3));
                                }, token);
                            var failedFiles = result.FilesThatCouldNotBeDeleted
                                .Concat(housekeeping.FilesThatCouldNotBeDeleted)
                                .Concat(reclaimed.FilesThatCouldNotBeDeleted).ToArray();
                            var status = failedFiles.Length == 0
                                ? WorkflowStatus.Succeeded : WorkflowStatus.Degraded;
                            await FinishAsync(status);
                            await StopHeartbeatAsync();
                            if (reclaimed.RewrittenPacks > 0)
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                    "maintenance.packreclamation.completed", JsonSerializer.Serialize(new
                                    {
                                        outcome = status.ToString(),
                                        planned = true,
                                        AffectedItems = reclaimed.RewrittenPacks,
                                        reclaimedBytes = reclaimed.ReclaimedBytes,
                                        relocatedObjects = reclaimed.RelocatedObjects,
                                    }), configurationPath);
                            if (housekeeping.AffectedItems > 0 || housekeeping.Vacuum.Status == "compacted")
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                    "maintenance.database.completed", JsonSerializer.Serialize(new
                                    {
                                        outcome = status.ToString(),
                                        housekeeping.AffectedItems,
                                        database = housekeeping.ToDetail(),
                                        failureCode = failedFiles.Length == 0 ? null : "file-delete-failed",
                                    }), configurationPath);
                            if (result.Removed.Count > 0 || failedFiles.Length > 0)
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                "maintenance.orphanbackups.completed", JsonSerializer.Serialize(new
                                {
                                    outcome = status.ToString(),
                                    planned = result.Removed.Count > 0,
                                    AffectedItems = result.Removed.Sum(item => item.Revisions),
                                    removed = result.Removed,
                                    result.DeferredSources,
                                    failureCode = failedFiles.Length == 0 ? null : "file-delete-failed",
                                    failedFileCount = failedFiles.Length,
                                    failedFiles = failedFiles.Take(8).Select(Path.GetFileName).ToArray(),
                                }), configurationPath);
                            return (status == WorkflowStatus.Succeeded ? ProcessOutcome.Succeeded : ProcessOutcome.Degraded,
                                (MaintenanceLaneResult?)new MaintenanceLaneResult(lane, status.ToString(),
                                    timer.ElapsedMilliseconds, result.Removed.Sum(item => item.Revisions) + retained
                                        + housekeeping.AffectedItems + reclaimed.RewrittenPacks,
                                    housekeeping.ToDetail()), run);
                        }
                        catch (Exception exception)
                        {
                            var status = exception is OperationCanceledException ? WorkflowStatus.Cancelled
                                : exception is RepositoryBusyException ? WorkflowStatus.Busy : WorkflowStatus.Failed;
                            await FinishAsync(status);
                            await StopHeartbeatAsync();
                            // A yield after an announced start needs its closing event; an unannounced one stays silent.
                            if (status == WorkflowStatus.Cancelled && announced)
                                await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, owner, run,
                                    "maintenance.orphanbackups.cancelled", FailureTelemetry.FromException(
                                        "cancelled", exception, status: status.ToString(), operation: "maintenance"), configurationPath);
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
            }, stopRequested);
        return acquired.Acquired ? acquired.Value : (ProcessOutcome.Busy, null, 0L);
    }
}
