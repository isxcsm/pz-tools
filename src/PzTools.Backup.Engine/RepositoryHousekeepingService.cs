using System.Text.Json;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record RepositoryHousekeepingResult(
    int CompactedRevisions, int RemovedEntryVersions, int RemovedObjects, CompletedHistoryCleanup History,
    RepositoryVacuumResult Vacuum, IReadOnlyList<string> FilesThatCouldNotBeDeleted, int RemovedPathRows = 0, int InspectedPathRows = 0, int InspectedEntryVersions = 0)
{
    public int AffectedItems => CompactedRevisions + RemovedEntryVersions + RemovedObjects + History.Workflows + History.Stages + RemovedPathRows;
    public string ToDetail() => JsonSerializer.Serialize(new
    {
        compactedRevisions = CompactedRevisions,
        removedEntryVersions = RemovedEntryVersions,
        inspectedEntryVersions = InspectedEntryVersions,
        removedObjects = RemovedObjects,
        removedPathRows = RemovedPathRows,
        inspectedPathRows = InspectedPathRows,
        history = History,
        vacuum = Vacuum,
        failedFileCount = FilesThatCouldNotBeDeleted.Count,
    });
}

public sealed class RepositoryHousekeepingService
{
    // Called only in maintenance workers, under the existing writer lease/yield protocol.
    // A null source also services aged deletions in inactive saves and global upkeep
    // after orphan cleanup. It does not change orphan-backup retention policy.
    public async Task<RepositoryHousekeepingResult> RunAsync(
        RepositoryDatabase repository, RepositoryWriterLease lease, long? sourceId,
        long maintenanceRunIndex, MaintenanceOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        options.Validate();
        var policy = options.Housekeeping;
        var compacted = 0;
        if (sourceId is null)
        {
            var dueSources = await repository.ReadSourcesDueForRevisionCompactionAsync(
                options.RevisionCompactionBatchSize,
                TimeSpan.FromMinutes(options.RevisionCompactionMaxDelayMinutes),
                cancellationToken: cancellationToken);
            foreach (var id in dueSources)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var result = await repository.CompactDeletedRevisionsAsync(
                    lease, id, options.RevisionCompactionBatchSize, cancellationToken);
                compacted += result.CompactedRevisions;
            }
        }
        var entrySweep = await repository.SweepUnreachableEntryVersionsAsync(
            lease, sourceId, policy.BatchSize, cancellationToken);
        var entries = entrySweep.RemovedRows;
        var removedObjects = 0;
        IReadOnlyList<string> failed = [];
        if (entries > 0 || compacted > 0)
        {
            var garbage = await repository.CollectGarbageAsync(lease, cancellationToken, collectPaths: false);
            removedObjects = garbage.DeletedObjects + garbage.DeletedPacks + garbage.DeletedOrphanFiles;
            failed = garbage.FilesThatCouldNotBeDeleted;
        }
        // Exactly one dictionary pass per housekeeping cycle, sharing one inspection budget.
        var pathSweep = await repository.SweepUnreferencedPathsAsync(lease, policy.BatchSize, cancellationToken);
        var history = policy.HistoryRetentionDays == 0
            ? new CompletedHistoryCleanup(0, 0)
            : await repository.PruneCompletedHistoryAsync(
                lease, DateTimeOffset.UtcNow.AddDays(-policy.HistoryRetentionDays),
                policy.MinimumRetainedRuns, policy.BatchSize, cancellationToken);
        var vacuum = await repository.TryVacuumAsync(lease, maintenanceRunIndex, policy, cancellationToken);
        return new RepositoryHousekeepingResult(compacted, entries, removedObjects, history, vacuum, failed, pathSweep.RemovedRows, pathSweep.InspectedRows, entrySweep.InspectedRows);
    }
}
