using System.Globalization;
using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

public sealed record RepositoryHousekeepingOptions(
    int HistoryRetentionDays = 90,
    int MinimumRetainedRuns = 1000,
    int BatchSize = 1000,
    bool VacuumEnabled = true,
    int VacuumMinimumFreeMib = 4,
    int VacuumMinimumFreePercent = 25,
    int VacuumMaximumDatabaseMib = 256)
{
    public void Validate()
    {
        if (HistoryRetentionDays is < 0 or > 3650) throw new ArgumentOutOfRangeException(nameof(HistoryRetentionDays));
        if (MinimumRetainedRuns < 1) throw new ArgumentOutOfRangeException(nameof(MinimumRetainedRuns));
        if (BatchSize is < 1 or > 10000) throw new ArgumentOutOfRangeException(nameof(BatchSize));
        if (VacuumMinimumFreeMib < 1) throw new ArgumentOutOfRangeException(nameof(VacuumMinimumFreeMib));
        if (VacuumMinimumFreePercent is < 1 or > 100) throw new ArgumentOutOfRangeException(nameof(VacuumMinimumFreePercent));
        if (VacuumMaximumDatabaseMib < 1) throw new ArgumentOutOfRangeException(nameof(VacuumMaximumDatabaseMib));
    }
}

public sealed record CompletedHistoryCleanup(int Runs, int Workflows, int Stages);
public sealed record RepositoryVacuumResult(string Status, long BeforeBytes, long AfterBytes, bool CheckpointCompleted = false);

public sealed partial class RepositoryDatabase
{
    public async Task<bool> IsRevisionCompactionDueAsync(
        long sourceId, int batchSize, TimeSpan maximumDelay,
        CancellationToken cancellationToken = default)
    {
        if (sourceId <= 0) throw new ArgumentOutOfRangeException(nameof(sourceId));
        if (batchSize <= 0) throw new ArgumentOutOfRangeException(nameof(batchSize));
        if (maximumDelay < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(maximumDelay));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT COUNT(*) >= $batch OR COALESCE(MIN(julianday(deleted_utc)) <= julianday($cutoff), 0)
            FROM revisions
            WHERE source_id=$sourceId AND state='Deleted'
              AND revision < (SELECT current_revision FROM source_state WHERE source_id=$sourceId);
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        command.Parameters.AddWithValue("$batch", batchSize);
        command.Parameters.AddWithValue("$cutoff", (DateTimeOffset.UtcNow - maximumDelay).ToString("O"));
        return Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) != 0;
    }

    // The periodic orphan-maintenance worker also services inactive saves. Otherwise
    // an age-based admission rule would still wait forever for another backup.
    public async Task<IReadOnlyList<long>> ReadSourcesDueForRevisionCompactionAsync(
        int batchSize, TimeSpan maximumDelay, int maximumSources = 4,
        CancellationToken cancellationToken = default)
    {
        if (batchSize <= 0) throw new ArgumentOutOfRangeException(nameof(batchSize));
        if (maximumDelay < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(maximumDelay));
        if (maximumSources is < 1 or > 64) throw new ArgumentOutOfRangeException(nameof(maximumSources));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT revision.source_id FROM revisions AS revision
            JOIN source_state AS state ON state.source_id=revision.source_id
            WHERE revision.state='Deleted' AND revision.revision<state.current_revision
            GROUP BY revision.source_id
            HAVING COUNT(*) >= $batch OR MIN(julianday(revision.deleted_utc)) <= julianday($cutoff)
            ORDER BY MIN(julianday(revision.deleted_utc)), revision.source_id
            LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$batch", batchSize);
        command.Parameters.AddWithValue("$cutoff", (DateTimeOffset.UtcNow - maximumDelay).ToString("O"));
        command.Parameters.AddWithValue("$limit", maximumSources);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var sources = new List<long>();
        while (await reader.ReadAsync(cancellationToken)) sources.Add(reader.GetInt64(0));
        return sources;
    }

    // Run IDs are retained by repository_info, not recycled from deleted history.
    // Keep the newest IDs of BOTH histories and every revision/pack/live-stage owner.
    public async Task<CompletedHistoryCleanup> PruneCompletedHistoryAsync(
        RepositoryWriterLease lease, DateTimeOffset completedBefore,
        int minimumRetainedRuns = 1000, int maximumRuns = 1000,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        if (minimumRetainedRuns < 1) throw new ArgumentOutOfRangeException(nameof(minimumRetainedRuns));
        if (maximumRuns is < 1 or > 10000) throw new ArgumentOutOfRangeException(nameof(maximumRuns));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            CREATE TEMP TABLE housekeeping_recent(run_index INTEGER PRIMARY KEY);
            INSERT OR IGNORE INTO housekeeping_recent
                SELECT run_index FROM runs ORDER BY run_index DESC LIMIT $keep;
            INSERT OR IGNORE INTO housekeeping_recent
                SELECT run_index FROM workflow_runs ORDER BY run_index DESC LIMIT $keep;
            CREATE TEMP TABLE housekeeping_workflows(run_index INTEGER PRIMARY KEY);
            INSERT INTO housekeeping_workflows
                SELECT workflow.run_index FROM workflow_runs AS workflow
                WHERE workflow.status!='Running'
                  AND julianday(workflow.completed_utc)<julianday($cutoff)
                  AND NOT EXISTS (SELECT 1 FROM housekeeping_recent AS recent WHERE recent.run_index=workflow.run_index)
                  AND NOT EXISTS (SELECT 1 FROM revisions WHERE run_index=workflow.run_index)
                  AND NOT EXISTS (SELECT 1 FROM packs WHERE created_run_index=workflow.run_index)
                  AND NOT EXISTS (
                      SELECT 1 FROM workflow_stages AS stage WHERE stage.run_index=workflow.run_index
                        AND (stage.status='Running' OR julianday(stage.completed_utc) IS NULL
                             OR julianday(stage.completed_utc)>=julianday($cutoff)))
                  AND NOT EXISTS (
                      SELECT 1 FROM runs AS run WHERE run.run_index=workflow.run_index
                        AND (run.status='Running' OR julianday(run.completed_utc) IS NULL
                             OR julianday(run.completed_utc)>=julianday($cutoff)))
                ORDER BY workflow.run_index LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$keep", minimumRetainedRuns);
        command.Parameters.AddWithValue("$cutoff", completedBefore.ToUniversalTime().ToString("O"));
        command.Parameters.AddWithValue("$limit", maximumRuns);
        await command.ExecuteNonQueryAsync(cancellationToken);
        command.CommandText = "DELETE FROM workflow_stages WHERE run_index IN (SELECT run_index FROM housekeeping_workflows);";
        var stages = await command.ExecuteNonQueryAsync(cancellationToken);
        command.CommandText = "DELETE FROM workflow_runs WHERE run_index IN (SELECT run_index FROM housekeeping_workflows);";
        var workflows = await command.ExecuteNonQueryAsync(cancellationToken);
        command.CommandText =
            """
            DELETE FROM runs WHERE run_index IN (
                SELECT run.run_index FROM runs AS run
                WHERE run.status!='Running' AND julianday(run.completed_utc)<julianday($cutoff)
                  AND NOT EXISTS (SELECT 1 FROM housekeeping_recent AS recent WHERE recent.run_index=run.run_index)
                  AND NOT EXISTS (SELECT 1 FROM workflow_runs WHERE run_index=run.run_index)
                  AND NOT EXISTS (SELECT 1 FROM revisions WHERE run_index=run.run_index)
                  AND NOT EXISTS (SELECT 1 FROM packs WHERE created_run_index=run.run_index)
                ORDER BY run.run_index LIMIT $limit
            );
            """;
        var runs = await command.ExecuteNonQueryAsync(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        transaction.Commit();
        return new CompletedHistoryCleanup(runs, workflows, stages);
    }

    // Opportunistic, bounded-size work on a private connection, never a file swap.
    // In particular, never replace repository.db while WAL readers are alive.
    public async Task<RepositoryVacuumResult> TryVacuumAsync(
        RepositoryWriterLease lease, long maintenanceRunIndex,
        RepositoryHousekeepingOptions options, CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        ArgumentNullException.ThrowIfNull(options);
        options.Validate();
        cancellationToken.ThrowIfCancellationRequested();
        if (!options.VacuumEnabled) return new("disabled", 0, 0);
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWrite,
            Cache = SqliteCacheMode.Private,
            Pooling = false,
            DefaultTimeout = 1,
        }.ToString());
        long before = 0;
        try
        {
            await connection.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandTimeout = 1;
            command.CommandText = "PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;";
            await command.ExecuteNonQueryAsync(cancellationToken);
            var pageSize = await ScalarAsync("PRAGMA page_size;");
            var pages = await ScalarAsync("PRAGMA page_count;");
            var freePages = await ScalarAsync("PRAGMA freelist_count;");
            before = checked(pages * pageSize);
            if (before > (long)options.VacuumMaximumDatabaseMib * 1024 * 1024)
                return new("database-size-limit", before, before);
            if (freePages * pageSize < (long)options.VacuumMinimumFreeMib * 1024 * 1024
                || pages == 0 || (double)freePages / pages * 100 < options.VacuumMinimumFreePercent)
                return new("below-threshold", before, before);
            command.CommandText =
                """
                SELECT EXISTS(SELECT 1 FROM runs WHERE status='Running' AND run_index!=$run)
                    OR EXISTS(SELECT 1 FROM workflow_runs WHERE status='Running' AND run_index!=$run
                              AND pipeline NOT IN ('maintenance','maintenance-lane'));
                """;
            command.Parameters.AddWithValue("$run", maintenanceRunIndex);
            if (Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) != 0)
                return new("active-work", before, before);
            command.Parameters.Clear();
            try
            {
                var required = checked(before * 2 + 64L * 1024 * 1024);
                foreach (var path in new[] { DatabasePath, Path.GetTempPath() })
                {
                    var root = Path.GetPathRoot(Path.GetFullPath(path));
                    if (string.IsNullOrEmpty(root) || new DriveInfo(root).AvailableFreeSpace < required)
                        return new("insufficient-space", before, before);
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
            {
                return new("space-check-unavailable", before, before);
            }

            // Microsoft.Data.Sqlite async calls execute native work synchronously.
            // Register native interruption so the maintenance yield watcher can stop VACUUM.
            using (cancellationToken.Register(() => SQLitePCL.raw.sqlite3_interrupt(connection.Handle!)))
            {
                cancellationToken.ThrowIfCancellationRequested();
                command.CommandText = "VACUUM;";
                await command.ExecuteNonQueryAsync(cancellationToken);
            }
            var after = checked(await ScalarAsync("PRAGMA page_count;") * pageSize);
            var checkpointCompleted = false;
            try
            {
                command.CommandText = "PRAGMA wal_checkpoint(TRUNCATE);";
                await using var reader = await command.ExecuteReaderAsync(cancellationToken);
                checkpointCompleted = await reader.ReadAsync(cancellationToken) && reader.GetInt64(0) == 0;
            }
            catch (SqliteException exception) when (exception.SqliteErrorCode is 5 or 6)
            {
                // Compaction committed. Existing readers may defer physical WAL truncation.
            }
            return new("compacted", before, after, checkpointCompleted);

            async Task<long> ScalarAsync(string sql)
            {
                command.CommandText = sql;
                return Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
            }
        }
        catch (SqliteException exception) when (exception.SqliteErrorCode == 9 && cancellationToken.IsCancellationRequested)
        {
            throw new OperationCanceledException("Repository vacuum yielded to another operation.", exception, cancellationToken);
        }
        catch (SqliteException exception) when (exception.SqliteErrorCode is 5 or 6)
        {
            return new("busy", before, before);
        }
    }
}
