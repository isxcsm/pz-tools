using System.Globalization;
using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

/// <summary>
/// Schema 5 kept a second history of worker runs, <c>runs</c>, next to <c>workflow_runs</c> and
/// <c>workflow_stages</c>, and every writer kept both in step by hand. Schema 6 drops it: revisions and
/// packs refer to <c>workflow_runs</c>, and the <c>worker_runs</c> view answers what <c>runs</c> did.
/// </summary>
internal static class RepositorySchemaUpgrade
{
    // Rows of runs without a workflow or a worker stage are copied there first, so that no revision, pack
    // or history entry loses its run. Run statuses are a subset of workflow statuses.
    private static readonly string Upgrade =
        $$"""
        INSERT INTO workflow_runs(run_index, pipeline, source_id, owner_component, status,
                                  started_utc, completed_utc, failure_code)
        SELECT run.run_index, 'backup', run.source_id, 'backup-worker', run.status,
               run.started_utc, run.completed_utc, run.failure_code
        FROM runs AS run
        WHERE NOT EXISTS (SELECT 1 FROM workflow_runs AS workflow WHERE workflow.run_index = run.run_index);

        INSERT INTO workflow_stages(run_index, producer, status, started_utc, completed_utc, failure_code)
        SELECT run.run_index, 'backup-worker', run.status, run.started_utc, run.completed_utc, run.failure_code
        FROM runs AS run
        WHERE NOT EXISTS (
            SELECT 1 FROM workflow_stages AS stage
            WHERE stage.run_index = run.run_index
              AND stage.producer IN ('backup-worker', 'maintenance-worker'));

        {{RepositorySchema.RevisionsTable.Replace("CREATE TABLE revisions (", "CREATE TABLE revisions_v6 (", StringComparison.Ordinal)}}
        INSERT INTO revisions_v6({{RepositorySchema.RevisionsColumns}})
            SELECT {{RepositorySchema.RevisionsColumns}} FROM revisions;
        DROP TABLE revisions;
        ALTER TABLE revisions_v6 RENAME TO revisions;
        {{RepositorySchema.RevisionsIndexes}}

        {{RepositorySchema.PacksTable.Replace("CREATE TABLE packs (", "CREATE TABLE packs_v6 (", StringComparison.Ordinal)}}
        INSERT INTO packs_v6({{RepositorySchema.PacksColumns}})
            SELECT {{RepositorySchema.PacksColumns}} FROM packs;
        DROP TABLE packs;
        ALTER TABLE packs_v6 RENAME TO packs;

        DROP TABLE runs;
        {{RepositorySchema.WorkerRunsView}}
        """;

    /// <summary>
    /// Upgrades a schema 5 repository in one transaction. Returns false when another opener upgraded
    /// it first. Any failure leaves schema 5 unchanged.
    /// </summary>
    public static async Task<bool> UpgradeFrom5Async(string repositoryPath, CancellationToken cancellationToken)
    {
        // A private connection: repository connections share one cache per process, where a second
        // opener would fail at once on the upgrade's locks instead of waiting for it like another process.
        // References are checked once, before commit, because tables that others refer to are rebuilt.
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = Path.Combine(repositoryPath, RepositoryDatabase.DatabaseFileName),
            Mode = SqliteOpenMode.ReadWrite,
            Cache = SqliteCacheMode.Private,
            Pooling = false,
            ForeignKeys = false,
        }.ToString());
        await connection.OpenAsync(cancellationToken);
        await ExecuteAsync(connection, null, "PRAGMA busy_timeout = 30000;", cancellationToken);

        // No copy is kept: the transaction is the safety. A copy would cost as much disk as the
        // catalog, which grows with every save file and backup, and would go stale with the next one.
        using var transaction = connection.BeginTransaction(deferred: false);
        if (await ReadSchemaVersionAsync(connection, transaction, cancellationToken) != RepositorySchema.UpgradableVersion)
            return false;
        await ExecuteAsync(connection, transaction, Upgrade, cancellationToken);
        await using (var check = connection.CreateCommand())
        {
            check.Transaction = transaction;
            check.CommandText = "PRAGMA foreign_key_check;";
            await using var reader = await check.ExecuteReaderAsync(cancellationToken);
            if (await reader.ReadAsync(cancellationToken))
                throw new InvalidDataException(
                    $"Repository upgrade left a broken reference in {reader.GetString(0)}; nothing was changed.");
        }
        await using (var mark = connection.CreateCommand())
        {
            mark.Transaction = transaction;
            mark.CommandText =
                """
                UPDATE repository_info SET schema_version = $version WHERE singleton = 1;
                INSERT INTO schema_migrations(version, name, applied_utc) VALUES ($version, $name, $appliedUtc);
                """;
            mark.Parameters.AddWithValue("$version", RepositorySchema.CurrentVersion);
            mark.Parameters.AddWithValue("$name", "single run history (upgraded from 5)");
            mark.Parameters.AddWithValue("$appliedUtc", DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture));
            await mark.ExecuteNonQueryAsync(cancellationToken);
        }
        transaction.Commit();
        return true;
    }

    private static async Task<int> ReadSchemaVersionAsync(
        SqliteConnection connection, SqliteTransaction transaction, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT schema_version FROM repository_info WHERE singleton = 1;";
        return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
    }

    private static async Task ExecuteAsync(
        SqliteConnection connection, SqliteTransaction? transaction, string sql, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
