using System.Diagnostics;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;

internal static class MaintenanceLanePipeline
{
    private const string Stage = "maintenance-worker";

    // The maintenance lanes stay inside the maintenance process. Each lane starts only its own heavy worker process.
    public static async Task<MaintenanceResult> DispatchAsync(
        string repositoryPath, long sourceId, long runIndex, MaintenanceOptions options,
        string? controlDatabasePath, string? configurationPath, CancellationToken cancellationToken = default)
    {
        options.Validate();
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath, cancellationToken);
        var workflow = await repository.ReadWorkflowAsync(runIndex, cancellationToken);
        if (workflow.SourceId != sourceId || workflow.Status != WorkflowStatus.Running)
            throw new InvalidOperationException("The maintenance dispatch workflow is not running for this source.");

        await repository.AttachWorkflowStageAsync(runIndex, Stage, cancellationToken);
        var lanes = new List<MaintenanceLaneResult>();
        try
        {
            var timer = Stopwatch.StartNew();
            try
            {
                await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
                var retention = await repository.MarkRevisionsForRetentionAsync(
                    lease, sourceId, options.RetainLatestRevisions, cancellationToken);
                lanes.Add(new MaintenanceLaneResult(
                    "Retention", "Succeeded", timer.ElapsedMilliseconds, retention.MarkedDeleted));
            }
            catch (RepositoryBusyException)
            {
                // One lane being busy does not stop the other lanes from starting their processes.
                lanes.Add(new MaintenanceLaneResult(
                    "Retention", "Busy", timer.ElapsedMilliseconds, 0, "repository-writer-busy"));
            }

            var pending = await repository.CountCompactableDeletedRevisionsAsync(sourceId, cancellationToken);
            if (await repository.IsRevisionCompactionDueAsync(sourceId, options.RevisionCompactionBatchSize,
                    TimeSpan.FromMinutes(options.RevisionCompactionMaxDelayMinutes), cancellationToken))
            {
                cancellationToken.ThrowIfCancellationRequested();
                lanes.Add(await DispatchLaneAsync(
                    repositoryPath, sourceId, runIndex, "RevisionReclamation", options,
                    controlDatabasePath, configurationPath));
            }
            else
            {
                lanes.Add(new MaintenanceLaneResult(
                    "RevisionReclamation", "Skipped", 0, 0,
                    $"pending={pending};threshold={options.RevisionCompactionBatchSize};max-delay-minutes={options.RevisionCompactionMaxDelayMinutes}"));
            }

            // A lane started is its own process; a stop asked for before then starts no more of them.
            cancellationToken.ThrowIfCancellationRequested();
            lanes.Add(await DispatchLaneAsync(
                repositoryPath, sourceId, runIndex, "ArtifactCleanup", options,
                controlDatabasePath, configurationPath));

            var status = lanes.Any(lane => lane.Status == "Failed")
                ? WorkflowStatus.Degraded : WorkflowStatus.Succeeded;
            await repository.CompleteWorkflowStageAsync(
                runIndex, Stage, status,
                status == WorkflowStatus.Degraded ? "lane-launch-failed" : null);
            return new MaintenanceResult(runIndex, sourceId, lanes, []);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Asked to stop: the stage ends as cancelled, not failed, and the workflow is its owner's to close.
            await repository.CompleteWorkflowStageAsync(
                runIndex, Stage, WorkflowStatus.Cancelled, "cancelled", CancellationToken.None);
            throw;
        }
        catch (Exception exception)
        {
            await repository.CompleteWorkflowStageAsync(
                runIndex, Stage, WorkflowStatus.Failed, "maintenance-dispatch-failed");
            await BestEffortProcessTelemetry.TryRecordAsync(
                repositoryPath, "maintenance-worker", runIndex,
                "maintenance.dispatch.failed",
                FailureTelemetry.FromException(
                    "maintenance-dispatch-failed", exception,
                    phase: "maintenance-dispatch", operation: "maintenance"),
                configurationPath);
            throw;
        }
    }

    private static async Task<MaintenanceLaneResult> DispatchLaneAsync(
        string repositoryPath, long sourceId, long dispatchRunIndex,
        string lane, MaintenanceOptions options,
        string? controlDatabasePath, string? configurationPath)
    {
        if (GameplayWorkGate.ShouldDeferMaintenance())
            return new MaintenanceLaneResult(lane, "Skipped", 0, 0, "deferred-during-gameplay");

        if (await MaintenanceLaneSignal.IsRunningAsync(repositoryPath, lane))
            return new MaintenanceLaneResult(lane, "Busy", 0, 0, "lane-already-running");

        var executable = Environment.ProcessPath
            ?? throw new InvalidOperationException("The maintenance executable path is unavailable.");
        var arguments = new List<string>();
        foreach (var argument in new[]
                 {
                     "--repository", repositoryPath,
                     "--source-id", sourceId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                     "--lane", lane,
                     "--revision-batch", options.RevisionCompactionBatchSize.ToString(
                         System.Globalization.CultureInfo.InvariantCulture),
                 })
            arguments.Add(argument);
        if (!string.IsNullOrWhiteSpace(controlDatabasePath))
        {
            arguments.Add("--control-db");
            arguments.Add(controlDatabasePath);
        }
        if (!string.IsNullOrWhiteSpace(configurationPath))
        {
            arguments.Add("--config");
            arguments.Add(configurationPath);
        }
        try
        {
            DetachedProcessLauncher.Start(executable, arguments, AppContext.BaseDirectory);
            return new MaintenanceLaneResult(lane, "Dispatched", 0, 0);
        }
        catch (Exception exception) when (exception is InvalidOperationException
            or System.ComponentModel.Win32Exception or FileNotFoundException)
        {
            await BestEffortProcessTelemetry.TryRecordAsync(
                repositoryPath, "maintenance-worker", dispatchRunIndex,
                $"maintenance.{lane.ToLowerInvariant()}.failed",
                FailureTelemetry.FromException(
                    "lane-launch-failed", exception,
                    phase: "maintenance-dispatch", operation: lane),
                configurationPath);
            return new MaintenanceLaneResult(lane, "Failed", 0, 0, exception.GetType().Name);
        }
    }

    public static async Task<(ProcessOutcome Outcome, MaintenanceLaneResult? Result, long RunIndex)> RunLaneAsync(
        string repositoryPath, long sourceId, string lane, MaintenanceOptions options,
        string? controlDatabasePath, string? configurationPath, CancellationToken stopRequested = default)
    {
        options.Validate();
        if (!MaintenanceLaneSignal.HeavyLanes.Contains(lane, StringComparer.Ordinal))
            throw new ArgumentException($"Unknown maintenance lane '{lane}'.", nameof(lane));

        if (GameplayWorkGate.ShouldDeferMaintenance())
            return (ProcessOutcome.Skipped, new MaintenanceLaneResult(lane, "Skipped", 0, 0, "deferred-during-gameplay"), 0);
        var acquired = await NamedMutexRunner.TryRunAsync(
            MaintenanceLaneSignal.MutexName(repositoryPath, lane), async _ =>
            {
                if (GameplayWorkGate.ShouldDeferMaintenance())
                    return (ProcessOutcome.Skipped, new MaintenanceLaneResult(lane, "Skipped", 0, 0, "deferred-during-gameplay"), 0L);
                // A stop request ends the lane as a yield to a backup or to the game does: cancelled, at a safe point.
                using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(stopRequested);
                using var yieldWatch = MaintenanceLaneSignal.WatchForYield(
                    repositoryPath, lane, cancellation);
                var token = cancellation.Token;
                var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath, token);
                var owner = $"maintenance-lane-{lane}";
                await repository.RecoverAbandonedWorkflowsAsync(owner, sourceId, token);
                var runIndex = await new RunIndexAllocator(controlDatabasePath)
                    .AllocateAsync(cancellationToken: token);
                await repository.ReserveWorkflowAsync("maintenance-lane", sourceId, owner,
                    null, runIndex, token);
                // Once reserved, the workflow reaches the handler below that closes it, whatever stops the lane.
                await repository.AttachWorkflowStageAsync(runIndex, owner, CancellationToken.None);
                ProcessTelemetryHeartbeat? heartbeat = null;
                var announced = false;
                // "planned" means the lane already knows it has work; otherwise only a long run is worth showing.
                async Task StartedAsync(bool planned)
                {
                    announced = planned;
                    await BestEffortProcessTelemetry.TryRecordAsync(
                        repositoryPath, owner, runIndex, $"maintenance.{lane.ToLowerInvariant()}.started",
                        System.Text.Json.JsonSerializer.Serialize(new { lane, planned }), configurationPath);
                    heartbeat = ProcessTelemetryHeartbeat.Start(
                        repositoryPath, owner, runIndex, configurationPath, TimeSpan.FromSeconds(3));
                }
                async Task StopHeartbeatAsync()
                {
                    if (heartbeat is not null) await heartbeat.DisposeAsync();
                    heartbeat = null;
                }
                try
                {
                    using var gameplayWatch = GameplayWorkGate.WatchForGameplay(cancellation);
                    RepositoryWriterLease lease;
                    while (true)
                    {
                        token.ThrowIfCancellationRequested();
                        try { lease = RepositoryWriterLease.Acquire(repositoryPath); break; }
                        catch (RepositoryBusyException) { await Task.Delay(options.WriterRetryDelayMs, token); }
                    }

                    await using (lease)
                    {
                        var timer = Stopwatch.StartNew();
                        var failed = new List<string>();
                        var count = 0;
                        RepositoryHousekeepingResult? housekeeping = null;
                        if (lane == "RevisionReclamation")
                        {
                            if (await repository.IsRevisionCompactionDueAsync(sourceId,
                                    options.RevisionCompactionBatchSize,
                                    TimeSpan.FromMinutes(options.RevisionCompactionMaxDelayMinutes), token))
                            {
                                await StartedAsync(planned: true);
                                var compacted = await repository.CompactDeletedRevisionsAsync(
                                    lease, sourceId, options.RevisionCompactionBatchSize, token);
                                count += compacted.CompactedRevisions;
                                if (compacted.CompactedRevisions > 0)
                                {
                                    var garbage = await repository.CollectGarbageAsync(lease, token);
                                    count += garbage.DeletedObjects + garbage.DeletedPacks
                                        + garbage.DeletedOrphanFiles;
                                    failed.AddRange(garbage.FilesThatCouldNotBeDeleted);
                                }
                            }
                        }
                        else
                        {
                            await StartedAsync(planned: false);
                            var cleanup = await repository.CleanupArtifactsAsync(lease, token);
                            count = cleanup.DeletedTemporaryFiles;
                            failed.AddRange(cleanup.FilesThatCouldNotBeDeleted);
                            housekeeping = await new RepositoryHousekeepingService().RunAsync(
                                repository, lease, sourceId, runIndex, options, token);
                            count += housekeeping.AffectedItems;
                            failed.AddRange(housekeeping.FilesThatCouldNotBeDeleted);
                        }

                        var outcome = failed.Count == 0
                            ? ProcessOutcome.Succeeded : ProcessOutcome.Degraded;
                        var status = failed.Count == 0
                            ? WorkflowStatus.Succeeded : WorkflowStatus.Degraded;
                        await repository.CompleteWorkflowStageAsync(
                            runIndex, owner, status, cancellationToken: CancellationToken.None);
                        await repository.CompleteWorkflowAsync(
                            runIndex, owner, status, cancellationToken: CancellationToken.None);
                        var laneResult = new MaintenanceLaneResult(
                            lane, status.ToString(), timer.ElapsedMilliseconds, count,
                            housekeeping is null
                                ? (failed.Count == 0 ? null : $"failed-files={failed.Count}")
                                : $"failed-files={failed.Count};{housekeeping.ToDetail()}");
                        await StopHeartbeatAsync();
                        await BestEffortProcessTelemetry.TryRecordAsync(
                            repositoryPath, owner, runIndex, $"maintenance.{lane.ToLowerInvariant()}.completed",
                            System.Text.Json.JsonSerializer.Serialize(new
                            {
                                outcome = outcome.ToString(),
                                lane,
                                planned = announced, // An announced start always gets its matching completion line.
                                laneResult.ElapsedMilliseconds,
                                laneResult.AffectedItems,
                                database = housekeeping?.ToDetail(),
                                failureCode = failed.Count == 0 ? null : "file-delete-failed",
                                failedFileCount = failed.Count,
                                failedFiles = failed.Take(8).Select(Path.GetFileName).ToArray(),
                            }), configurationPath);
                        return (outcome, laneResult, runIndex);
                    }
                }
                catch (Exception exception)
                {
                    var cancelled = exception is OperationCanceledException && token.IsCancellationRequested;
                    var status = cancelled ? WorkflowStatus.Cancelled : WorkflowStatus.Failed;
                    await repository.CompleteWorkflowStageAsync(
                        runIndex, owner, status, exception.GetType().Name, CancellationToken.None);
                    await repository.CompleteWorkflowAsync(
                        runIndex, owner, status, exception.GetType().Name, CancellationToken.None);
                    await StopHeartbeatAsync();
                    await BestEffortProcessTelemetry.TryRecordAsync(
                        repositoryPath, owner, runIndex,
                        $"maintenance.{lane.ToLowerInvariant()}." +
                            (cancelled ? "cancelled" : "failed"),
                        FailureTelemetry.FromException(
                            exception.GetType().Name, exception,
                            status: status.ToString(), phase: lane,
                            operation: "maintenance"),
                        configurationPath);
                    return (cancelled ? ProcessOutcome.Cancelled : ProcessOutcome.Failed,
                        new MaintenanceLaneResult(lane, status.ToString(), 0, 0,
                            exception.Message), runIndex);
                }
            }, stopRequested);
        return acquired.Acquired
            ? acquired.Value
            : (ProcessOutcome.Busy, null, 0);
    }
}
