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
