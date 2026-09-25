using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

public sealed record EntryVersionCollectionResult(int InspectedRows, int RemovedRows);

public sealed partial class RepositoryDatabase
{
    // The row limit applies before eligibility: a repository with nothing to delete
    // must not walk its entire history while holding the writer lease.
    internal const string EntryVersionWindowSql =
        """
        SELECT entry.rowid,
               CASE WHEN ($sourceId IS NULL OR entry.source_id=$sourceId)
                    AND entry.valid_to_revision IS NOT NULL THEN
                   NOT EXISTS (
                       SELECT 1 FROM revisions AS revision
                       WHERE revision.source_id=entry.source_id
                         AND revision.revision>=entry.valid_from_revision
                         AND revision.revision<entry.valid_to_revision
                         AND (revision.state='Active' OR revision.revision=(
                             SELECT current_revision FROM source_state WHERE source_id=entry.source_id))
                   ) ELSE 0 END
        FROM entry_versions AS entry
        /*cursor*/
        ORDER BY entry.rowid LIMIT $limit;
        """;

    public async Task<int> PruneUnreachableEntryVersionsAsync(
        RepositoryWriterLease lease, long? sourceId, int maximumEntries = 1000,
        CancellationToken cancellationToken = default) =>
        (await SweepUnreachableEntryVersionsAsync(lease, sourceId, maximumEntries, cancellationToken)).RemovedRows;

    public async Task<EntryVersionCollectionResult> SweepUnreachableEntryVersionsAsync(
        RepositoryWriterLease lease, long? sourceId, int maximumEntries = 1000,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        if (sourceId <= 0) throw new ArgumentOutOfRangeException(nameof(sourceId));
        if (maximumEntries is < 1 or > 10000) throw new ArgumentOutOfRangeException(nameof(maximumEntries));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        await using var state = connection.CreateCommand();
        state.Transaction = transaction;
        state.CommandText = "INSERT INTO entry_gc_cursors(scope_source_id,after_rowid) VALUES($scope,NULL) ON CONFLICT DO NOTHING;"
            + "SELECT after_rowid FROM entry_gc_cursors WHERE scope_source_id=$scope;";
        state.Parameters.AddWithValue("$scope", sourceId ?? 0);
        var previous = await state.ExecuteScalarAsync(cancellationToken);
        long? after = previous is null or DBNull ? null : Convert.ToInt64(previous, System.Globalization.CultureInfo.InvariantCulture);
        await using var select = connection.CreateCommand();
        select.Transaction = transaction;
        select.CommandText = EntryVersionWindowSql.Replace("/*cursor*/", after.HasValue ? "WHERE entry.rowid>$after" : "");
        if (after.HasValue) select.Parameters.AddWithValue("$after", after.Value);
        select.Parameters.AddWithValue("$sourceId", (object?)sourceId ?? DBNull.Value);
        select.Parameters.AddWithValue("$limit", maximumEntries);
        var candidates = new List<long>();
        var inspected = 0;
        await using (var reader = await select.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                after = reader.GetInt64(0);
                inspected++;
                if (reader.GetBoolean(1)) candidates.Add(after.Value);
            }
        }
        // A later invocation wraps; do not loop over a full dictionary in one call.
        // Revisits also cover old revisions newly deleted, rowid reuse and VACUUM renumbering.
        if (inspected < maximumEntries) after = null;
        await using var delete = connection.CreateCommand();
        delete.Transaction = transaction;
        delete.CommandText = "DELETE FROM entry_versions WHERE rowid=$id;";
        var id = delete.Parameters.Add("$id", SqliteType.Integer);
        var removed = 0;
        foreach (var candidate in candidates)
        {
            cancellationToken.ThrowIfCancellationRequested();
            id.Value = candidate;
            removed += await delete.ExecuteNonQueryAsync(cancellationToken);
        }
        state.CommandText = "UPDATE entry_gc_cursors SET after_rowid=$after WHERE scope_source_id=$scope;";
        state.Parameters.AddWithValue("$after", (object?)after ?? DBNull.Value);
        await state.ExecuteNonQueryAsync(cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        transaction.Commit();
        return new(inspected, removed);
    }
}
