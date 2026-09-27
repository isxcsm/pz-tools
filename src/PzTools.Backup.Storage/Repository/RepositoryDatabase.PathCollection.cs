using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

public sealed record PathCollectionResult(int InspectedRows, int RemovedRows);

public sealed partial class RepositoryDatabase
{
    internal const string PathSpellingWindowSql =
        """
        SELECT spelling.path_id, spelling.spelling_id,
               NOT EXISTS (SELECT 1 FROM entry_versions AS entry
                           WHERE entry.path_id=spelling.path_id AND entry.spelling_id=spelling.spelling_id)
        FROM path_spellings AS spelling
        WHERE (spelling.path_id, spelling.spelling_id) > ($afterPath, $afterSpelling)
        ORDER BY spelling.path_id, spelling.spelling_id LIMIT $limit;
        """;
    internal const string EmptyPathWindowSql =
        """
        SELECT path.path_id, NOT EXISTS (
            SELECT 1 FROM path_spellings AS spelling WHERE spelling.path_id=path.path_id)
        FROM paths AS path
        /*cursor*/
        ORDER BY path.path_id LIMIT $limit;
        """;
    internal const string DeleteUnreferencedSpellingSql =
        """
        DELETE FROM path_spellings WHERE path_id=$pathId AND spelling_id=$spellingId
          AND NOT EXISTS (SELECT 1 FROM entry_versions
                          WHERE path_id=$pathId AND spelling_id=$spellingId);
        """;
    internal const string DeleteEmptyPathSql =
        """
        DELETE FROM paths WHERE path_id=$pathId
          AND NOT EXISTS (SELECT 1 FROM path_spellings WHERE path_id=$pathId);
        """;

    public async Task<int> PruneUnreferencedPathsAsync(
        RepositoryWriterLease lease, int maximumRows = 1000,
        CancellationToken cancellationToken = default) =>
        (await SweepUnreferencedPathsAsync(lease, maximumRows, cancellationToken)).RemovedRows;

    // maximumRows bounds inspected dictionary rows, not just successful deletions.
    // Progress is persisted so independent maintenance processes continue the scan.
    public async Task<PathCollectionResult> SweepUnreferencedPathsAsync(
        RepositoryWriterLease lease, int maximumRows = 1000,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        if (maximumRows is < 1 or > 10000) throw new ArgumentOutOfRangeException(nameof(maximumRows));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        var result = await SweepUnreferencedPathsCoreAsync(connection, transaction, maximumRows, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        transaction.Commit();
        return result;
    }

    private static async Task<PathCollectionResult> SweepUnreferencedPathsCoreAsync(
        SqliteConnection connection, SqliteTransaction transaction, int maximumRows,
        CancellationToken cancellationToken)
    {
        await using var state = connection.CreateCommand();
        state.Transaction = transaction;
        state.CommandText = "SELECT spelling_path_id,spelling_id,empty_path_id,spellings_first FROM path_gc_cursor WHERE singleton=1;";
        long afterSpellingPath, afterSpelling;
        long? afterPath;
        bool spellingsFirst;
        await using (var reader = await state.ExecuteReaderAsync(cancellationToken))
        {
            if (!await reader.ReadAsync(cancellationToken)) throw new InvalidDataException("Path collection cursor is missing.");
            afterSpellingPath = reader.GetInt64(0);
            afterSpelling = reader.GetInt64(1);
            afterPath = reader.IsDBNull(2) ? null : reader.GetInt64(2);
            spellingsFirst = reader.GetBoolean(3);
        }
        var inspected = 0;
        var removed = 0;
        // With room for both tables, delete spellings before inspecting keys so
        // small orphan batches can finish in one call. Alternate priority for a
        // one-row budget so neither dictionary starves. Pass on unused budget.
        if (maximumRows > 1) spellingsFirst = true;
        for (var pass = 0; pass < 2; pass++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var limit = pass == 0 ? (maximumRows + 1) / 2 : maximumRows - inspected;
            if (limit == 0) continue;
            if ((pass == 0) == spellingsFirst)
                await SweepSpellingsAsync(limit);
            else
                await SweepKeysAsync(limit);
        }
        state.CommandText = "UPDATE path_gc_cursor SET spelling_path_id=$sp,spelling_id=$si,empty_path_id=$p,spellings_first=$first WHERE singleton=1;";
        state.Parameters.AddWithValue("$sp", afterSpellingPath);
        state.Parameters.AddWithValue("$si", afterSpelling);
        state.Parameters.AddWithValue("$p", (object?)afterPath ?? DBNull.Value);
        state.Parameters.AddWithValue("$first", !spellingsFirst);
        await state.ExecuteNonQueryAsync(cancellationToken);
        return new(inspected, removed);

        async Task SweepSpellingsAsync(int limit)
        {
            await using var select = connection.CreateCommand();
            select.Transaction = transaction;
            select.CommandText = PathSpellingWindowSql;
            select.Parameters.AddWithValue("$afterPath", afterSpellingPath);
            select.Parameters.AddWithValue("$afterSpelling", afterSpelling);
            select.Parameters.AddWithValue("$limit", limit);
            var candidates = new List<(long Path, long Spelling)>(limit);
            var count = 0;
            await using (var reader = await select.ExecuteReaderAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    afterSpellingPath = reader.GetInt64(0);
                    afterSpelling = reader.GetInt64(1);
                    if (reader.GetBoolean(2)) candidates.Add((afterSpellingPath, afterSpelling));
                    count++;
                }
            }
            inspected += count;
            // Wrap on a later pass; never loop across the full dictionary here.
            if (count < limit) { afterSpellingPath = long.MinValue; afterSpelling = -1; }
            await using var delete = connection.CreateCommand();
            delete.Transaction = transaction;
            delete.CommandText = DeleteUnreferencedSpellingSql;
            var path = delete.Parameters.Add("$pathId", SqliteType.Integer);
            var spelling = delete.Parameters.Add("$spellingId", SqliteType.Integer);
            foreach (var candidate in candidates)
            {
                cancellationToken.ThrowIfCancellationRequested();
                path.Value = candidate.Path;
                spelling.Value = candidate.Spelling;
                removed += await delete.ExecuteNonQueryAsync(cancellationToken);
            }
        }

        async Task SweepKeysAsync(int limit)
        {
            await using var select = connection.CreateCommand();
            select.Transaction = transaction;
            select.CommandText = EmptyPathWindowSql.Replace("/*cursor*/", afterPath.HasValue ? "WHERE path.path_id>$afterPath" : "");
            if (afterPath.HasValue) select.Parameters.AddWithValue("$afterPath", afterPath.Value);
            select.Parameters.AddWithValue("$limit", limit);
            var candidates = new List<long>(limit);
            var count = 0;
            await using (var reader = await select.ExecuteReaderAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    afterPath = reader.GetInt64(0);
                    if (reader.GetBoolean(1)) candidates.Add(afterPath.Value);
                    count++;
                }
            }
            inspected += count;
            if (count < limit) afterPath = null;
            await using var delete = connection.CreateCommand();
            delete.Transaction = transaction;
            delete.CommandText = DeleteEmptyPathSql;
            var path = delete.Parameters.Add("$pathId", SqliteType.Integer);
            foreach (var candidate in candidates)
            {
                cancellationToken.ThrowIfCancellationRequested();
                path.Value = candidate;
                removed += await delete.ExecuteNonQueryAsync(cancellationToken);
            }
        }
    }
}
