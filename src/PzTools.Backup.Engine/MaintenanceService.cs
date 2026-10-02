using System.Diagnostics;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record MaintenanceOptions(
    int RetainLatestRevisions = 100,
    int RevisionCompactionBatchSize = 20,
    int WriterRetryDelayMs = 200)
{
    public int RevisionCompactionMaxDelayMinutes { get; init; } = 60;
    public RepositoryHousekeepingOptions Housekeeping { get; init; } = new();
    public PackReclamationOptions PackReclamation { get; init; } = new();

    public void Validate()
    {
        if (RetainLatestRevisions <= 0) throw new ArgumentOutOfRangeException(nameof(RetainLatestRevisions));
        if (RevisionCompactionBatchSize <= 0) throw new ArgumentOutOfRangeException(nameof(RevisionCompactionBatchSize));
        if (WriterRetryDelayMs is < 50 or > 5000) throw new ArgumentOutOfRangeException(nameof(WriterRetryDelayMs));
        if (RevisionCompactionMaxDelayMinutes is < 0 or > 10080)
            throw new ArgumentOutOfRangeException(nameof(RevisionCompactionMaxDelayMinutes));
        ArgumentNullException.ThrowIfNull(Housekeeping);
        Housekeeping.Validate();
        ArgumentNullException.ThrowIfNull(PackReclamation);
        PackReclamation.Validate();
    }
}

public sealed record MaintenanceLaneResult(
    string Lane,
    string Status,
    long ElapsedMilliseconds,
    int AffectedItems,
    string? Detail = null);

public sealed record MaintenanceResult(
    long RunIndex,
    long SourceId,
    IReadOnlyList<MaintenanceLaneResult> Lanes,
    IReadOnlyList<string> FilesThatCouldNotBeDeleted);

public sealed record MaintenanceLaneEvent(
    long RunIndex,
    string Lane,
    string Stage,
    MaintenanceLaneResult? Result = null);

public sealed class MaintenanceService
{
    public async Task<MaintenanceResult> RunAsync(
        string repositoryPath,
        long sourceId,
        MaintenanceOptions? options = null,
        long? runIndex = null,
        Func<MaintenanceLaneEvent, CancellationToken, Task>? observer = null,
        CancellationToken cancellationToken = default)
    {
        options ??= new MaintenanceOptions();
        options.Validate();
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath, cancellationToken);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var workflow = runIndex is null
            ? await repository.ReserveWorkflowAsync(
                "maintenance", sourceId, "maintenance-worker", cancellationToken: cancellationToken)
            : await repository.ReadWorkflowAsync(runIndex.Value, cancellationToken);
        if (workflow.SourceId != sourceId || workflow.Status != WorkflowStatus.Running)
        {
            throw new InvalidOperationException(
                $"Workflow {workflow.RunIndex} is not a running workflow for source {sourceId}.");
        }

        await repository.StartMaintenanceStageAsync(
            lease, sourceId, workflow.RunIndex, cancellationToken);
        var lanes = new List<MaintenanceLaneResult>();
        var failedFiles = new List<string>();
        try
        {
            var timer = Stopwatch.StartNew();
            await NotifyAsync("Retention", "started");
            var retention = await repository.MarkRevisionsForRetentionAsync(
                lease, sourceId, options.RetainLatestRevisions, cancellationToken);
            lanes.Add(new MaintenanceLaneResult(
                "Retention", "Succeeded", timer.ElapsedMilliseconds, retention.MarkedDeleted));
            await NotifyAsync("Retention", "completed", lanes[^1]);

            var pendingCompaction = await repository.CountCompactableDeletedRevisionsAsync(
                sourceId, cancellationToken);
            var shouldCompact = await repository.IsRevisionCompactionDueAsync(
                sourceId, options.RevisionCompactionBatchSize,
                TimeSpan.FromMinutes(options.RevisionCompactionMaxDelayMinutes), cancellationToken);

            timer.Restart();
            await NotifyAsync("RevisionCompaction", "started");
            RevisionCompactionResult? revisionCompaction = null;
            if (shouldCompact)
            {
                revisionCompaction = await repository.CompactDeletedRevisionsAsync(
                    lease, sourceId, options.RevisionCompactionBatchSize, cancellationToken);
                lanes.Add(new MaintenanceLaneResult(
                    "RevisionCompaction", "Succeeded", timer.ElapsedMilliseconds,
                    revisionCompaction.CompactedRevisions,
                    $"rebased={revisionCompaction.RebasedEntryVersions}"));
            }
            else
            {
                lanes.Add(new MaintenanceLaneResult(
                    "RevisionCompaction", "Skipped", timer.ElapsedMilliseconds, 0,
                    $"pending={pendingCompaction};threshold={options.RevisionCompactionBatchSize};max-delay-minutes={options.RevisionCompactionMaxDelayMinutes}"));
            }
            await NotifyAsync("RevisionCompaction", "completed", lanes[^1]);

            timer.Restart();
            await NotifyAsync("ObjectGc", "started");
            if (revisionCompaction is not null)
            {
                var garbage = await repository.CollectGarbageAsync(lease, cancellationToken, collectPaths: false);
                failedFiles.AddRange(garbage.FilesThatCouldNotBeDeleted);
                lanes.Add(new MaintenanceLaneResult(
                    "ObjectGc", failedFiles.Count == 0 ? "Succeeded" : "Degraded",
                    timer.ElapsedMilliseconds,
                    garbage.DeletedObjects + garbage.DeletedPacks + garbage.DeletedOrphanFiles));
            }
            else
            {
                lanes.Add(new MaintenanceLaneResult(
                    "ObjectGc", "Skipped", timer.ElapsedMilliseconds, 0,
                    "revision-compaction-not-due"));
            }
            await NotifyAsync("ObjectGc", "completed", lanes[^1]);

            timer.Restart();
            await NotifyAsync("ArtifactCleanup", "started");
            var cleanup = await repository.CleanupArtifactsAsync(lease, cancellationToken);
            failedFiles.AddRange(cleanup.FilesThatCouldNotBeDeleted);
            var housekeeping = await new RepositoryHousekeepingService().RunAsync(
                repository, lease, sourceId, workflow.RunIndex, options, cancellationToken);
            failedFiles.AddRange(housekeeping.FilesThatCouldNotBeDeleted);
            lanes.Add(new MaintenanceLaneResult(
                "ArtifactCleanup",
                failedFiles.Count == 0 ? "Succeeded" : "Degraded",
                timer.ElapsedMilliseconds,
                cleanup.DeletedTemporaryFiles + housekeeping.AffectedItems,
                $"failed={failedFiles.Count};{housekeeping.ToDetail()}"));
            await NotifyAsync("ArtifactCleanup", "completed", lanes[^1]);
            var status = failedFiles.Count == 0
                ? WorkflowStatus.Succeeded
                : WorkflowStatus.Degraded;
            await repository.CompleteMaintenanceStageAsync(
                lease, workflow.RunIndex, status,
                failedFiles.Count == 0 ? null : "artifact-cleanup-incomplete",
                CancellationToken.None);
            return new MaintenanceResult(workflow.RunIndex, sourceId, lanes, failedFiles);
        }
        catch (OperationCanceledException)
        {
            await repository.CompleteMaintenanceStageAsync(
                lease, workflow.RunIndex, WorkflowStatus.Cancelled,
                "cancelled", CancellationToken.None);
            throw;
        }
        catch
        {
            await repository.CompleteMaintenanceStageAsync(
                lease, workflow.RunIndex, WorkflowStatus.Failed,
                "maintenance-failed", CancellationToken.None);
            throw;
        }

        async Task NotifyAsync(
            string lane,
            string stage,
            MaintenanceLaneResult? result = null)
        {
            if (observer is not null)
                await observer(new MaintenanceLaneEvent(
                    workflow.RunIndex, lane, stage, result), cancellationToken);
        }
    }
}
