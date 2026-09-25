using System.Globalization;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;

namespace PzTools.Backup.Storage.Repository;

// Owned by one commit transaction. No cross-transaction cache: rollback or GC must
// never leave a cached ID that could refer to a different dictionary row later.
internal sealed class RepositoryPathWriter : IAsyncDisposable
{
    private readonly SqliteCommand path;
    private readonly SqliteCommand spelling;

    internal RepositoryPathWriter(SqliteConnection connection, SqliteTransaction transaction)
    {
        path = connection.CreateCommand();
        spelling = connection.CreateCommand();
        path.Transaction = spelling.Transaction = transaction;
        path.CommandText =
            """
            INSERT INTO paths(path_key) VALUES($key) ON CONFLICT(path_key) DO NOTHING;
            SELECT path_id FROM paths WHERE path_key=$key;
            """;
        path.Parameters.Add("$key", SqliteType.Text);
        spelling.CommandText =
            """
            INSERT INTO path_spellings(path_id, spelling_id, display_path)
            SELECT $id, COALESCE(MAX(spelling_id), -1) + 1, $display
            FROM path_spellings WHERE path_id=$id
            HAVING NOT EXISTS (SELECT 1 FROM path_spellings WHERE path_id=$id AND display_path=$display);
            SELECT spelling_id FROM path_spellings WHERE path_id=$id AND display_path=$display;
            """;
        spelling.Parameters.Add("$id", SqliteType.Integer);
        spelling.Parameters.Add("$display", SqliteType.Text);
    }

    internal async Task<(long PathId, long SpellingId)> InternAsync(
        string relativePath, CancellationToken cancellationToken = default)
    {
        // Do not use SQLite upper()/NOCASE, which do not implement the existing
        // .NET Unicode invariant-case contract. Keep the spelling byte-exact.
        var displayPath = BackupPath.NormalizeRelative(relativePath);
        path.Parameters["$key"].Value = displayPath.ToUpperInvariant();
        var id = Convert.ToInt64(await path.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
        spelling.Parameters["$id"].Value = id;
        spelling.Parameters["$display"].Value = displayPath;
        var spellingId = Convert.ToInt64(await spelling.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
        return (id, spellingId);
    }

    public async ValueTask DisposeAsync()
    {
        await spelling.DisposeAsync();
        await path.DisposeAsync();
    }
}

public sealed partial class RepositoryDatabase
{
    // Global dictionaries can be shared by sources. A spelling is collectible only
    // after ALL entry versions release it, including tombstones/hidden baselines.
    // Run this even without fresh deletions so a bounded backlog can drain.
    public async Task<int> PruneUnreferencedPathsAsync(
        RepositoryWriterLease lease, int maximumRows = 1000,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        if (maximumRows is < 1 or > 10000) throw new ArgumentOutOfRangeException(nameof(maximumRows));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        var removed = await PruneUnreferencedPathsCoreAsync(connection, transaction, maximumRows, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        transaction.Commit();
        return removed;
    }

    private static async Task<int> PruneUnreferencedPathsCoreAsync(
        SqliteConnection connection, SqliteTransaction transaction, int maximumRows,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.Parameters.AddWithValue("$limit", maximumRows);
        command.CommandText =
            """
            DELETE FROM path_spellings WHERE (path_id, spelling_id) IN (
                SELECT spelling.path_id, spelling.spelling_id FROM path_spellings AS spelling
                WHERE NOT EXISTS (SELECT 1 FROM entry_versions AS entry
                                  WHERE entry.path_id=spelling.path_id
                                    AND entry.spelling_id=spelling.spelling_id)
                ORDER BY spelling.path_id, spelling.spelling_id LIMIT $limit
            );
            """;
        var removed = await command.ExecuteNonQueryAsync(cancellationToken);
        // Bound total rows across both tables, not a separate full batch per table.
        command.Parameters["$limit"].Value = maximumRows - removed;
        command.CommandText =
            """
            DELETE FROM paths WHERE path_id IN (
                SELECT path.path_id FROM paths AS path
                WHERE NOT EXISTS (SELECT 1 FROM path_spellings AS spelling WHERE spelling.path_id=path.path_id)
                ORDER BY path.path_id LIMIT $limit
            );
            """;
        return removed + await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
