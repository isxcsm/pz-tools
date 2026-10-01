using System.Globalization;
using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public const int CurrentFormatVersion = 2;
    public const string DatabaseFileName = "repository.db";

    private readonly string connectionString;

    private RepositoryDatabase(
        string repositoryPath,
        RepositoryIdentity identity,
        SqliteOpenMode openMode = SqliteOpenMode.ReadWriteCreate)
    {
        RepositoryPath = repositoryPath;
        DatabasePath = Path.Combine(repositoryPath, DatabaseFileName);
        Identity = identity;
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = openMode,
            Cache = SqliteCacheMode.Shared,
            Pooling = false,
        }.ToString();
    }

    public string RepositoryPath { get; }

    public string DatabasePath { get; }

    public RepositoryIdentity Identity { get; }

    public static async Task<RepositoryDatabase> CreateOrOpenAsync(
        string repositoryPath,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);
        var absolutePath = Path.GetFullPath(repositoryPath);
        var existingDatabase = Path.Combine(absolutePath, DatabaseFileName);
        if (File.Exists(existingDatabase) && new FileInfo(existingDatabase).Length > 0)
        {
            // Schema 5 is upgraded in place; anything older is rejected, never migrated or reset.
            return await OpenExistingAsync(absolutePath, cancellationToken);
        }
        Directory.CreateDirectory(absolutePath);
        Directory.CreateDirectory(Path.Combine(absolutePath, "packs"));
        Directory.CreateDirectory(Path.Combine(absolutePath, "staging"));

        var databasePath = Path.Combine(absolutePath, DatabaseFileName);
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
            Pooling = false,
        }.ToString();

        await using var connection = new SqliteConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await ConfigureConnectionAsync(connection, cancellationToken, enableWal: true);
        var schemaVersion = await RepositoryMigrationRunner.ApplyAsync(
            connection,
            RepositorySchema.Migrations,
            cancellationToken);

        var identity = await ReadOrCreateIdentityAsync(
            connection,
            schemaVersion,
            cancellationToken);
        return new RepositoryDatabase(absolutePath, identity);
    }

    public static async Task<RepositoryDatabase> OpenExistingAsync(
        string repositoryPath,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);
        var absolutePath = Path.GetFullPath(repositoryPath);
        var databasePath = Path.Combine(absolutePath, DatabaseFileName);
        if (!File.Exists(databasePath))
        {
            throw new DirectoryNotFoundException(
                $"Repository database '{databasePath}' does not exist.");
        }

        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWrite,
            Cache = SqliteCacheMode.Shared,
            Pooling = false,
        }.ToString();
        var initialized = await RepositoryConnectionInitialization.OpenAsync(
            () => new SqliteConnection(connectionString),
            async (connection, token) =>
            {
                // Validate before any PRAGMA that could write to an incompatible repository.
                var identity = await ReadExistingIdentityAsync(connection, token);
                await ConfigureConnectionAsync(connection, token, enableWal: false);
                // A read-only probe, so it may be replayed with the rest of the initialization
                // while Windows still holds a killed process's WAL-index mapping.
                return (Identity: identity, Complete: await HasGameVersionAsync(connection, token));
            }, cancellationToken);
        await using var connection = initialized.Connection;
        if (!initialized.Value.Complete) await AddOptionalColumnsAsync(connection, cancellationToken);
        var identity = initialized.Value.Identity;
        if (identity.SchemaVersion == RepositorySchema.UpgradableVersion)
        {
            // Another process may have upgraded it first; either way it is now the current schema.
            await RepositorySchemaUpgrade.UpgradeFrom5Async(absolutePath, cancellationToken);
            identity = identity with { SchemaVersion = RepositorySchema.CurrentVersion };
        }
        return new RepositoryDatabase(absolutePath, identity, SqliteOpenMode.ReadWrite);
    }

    // Optional nullable columns are added in place: builds that do not know them name their
    // columns explicitly, so the repository stays the same schema version and opens everywhere.
    private static async Task AddOptionalColumnsAsync(SqliteConnection connection, CancellationToken cancellationToken)
    {
        try
        {
            await using var add = connection.CreateCommand();
            add.CommandText = "ALTER TABLE revisions ADD COLUMN game_version TEXT NULL;";
            await add.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (SqliteException) when (connection.State == System.Data.ConnectionState.Open)
        {
            // Another process may have added it between the check and the change.
            if (!await HasGameVersionAsync(connection, cancellationToken)) throw;
        }
    }

    private static async Task<bool> HasGameVersionAsync(SqliteConnection connection, CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT 1 FROM pragma_table_info('revisions') WHERE name='game_version';";
        return await command.ExecuteScalarAsync(cancellationToken) is not null;
    }

    public async Task<RepositorySource> AddOrGetSourceAsync(
        RepositoryWriterLease lease,
        string sourceKey,
        string rootPath,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        var absoluteRoot = Path.GetFullPath(rootPath);

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();

        var existing = await ReadSourceByKeyAsync(
            connection,
            transaction,
            sourceKey,
            cancellationToken);
        if (existing is not null)
        {
            if (!StringComparer.OrdinalIgnoreCase.Equals(existing.RootPath, absoluteRoot))
            {
                throw new InvalidOperationException(
                    $"Source '{sourceKey}' is already registered at '{existing.RootPath}'.");
            }

            transaction.Commit();
            return existing;
        }

        var createdUtc = DateTimeOffset.UtcNow;
        await using var insert = connection.CreateCommand();
        insert.Transaction = transaction;
        insert.CommandText =
            """
            INSERT INTO sources(source_key, root_path, created_utc)
            VALUES ($key, $rootPath, $createdUtc);
            SELECT last_insert_rowid();
            """;
        insert.Parameters.AddWithValue("$key", sourceKey);
        insert.Parameters.AddWithValue("$rootPath", absoluteRoot);
        insert.Parameters.AddWithValue("$createdUtc", createdUtc.ToString("O"));
        var sourceId = Convert.ToInt64(
            await insert.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture);

        await using var state = connection.CreateCommand();
        state.Transaction = transaction;
        state.CommandText = "INSERT INTO source_state(source_id) VALUES ($sourceId);";
        state.Parameters.AddWithValue("$sourceId", sourceId);
        await state.ExecuteNonQueryAsync(cancellationToken);
        await IncrementRepositoryChangeRevisionAsync(
            connection, transaction, cancellationToken);
        transaction.Commit();

        return new RepositorySource(sourceId, sourceKey, absoluteRoot, createdUtc);
    }

    public async Task<RepositorySource> GetSourceAsync(
        string sourceKey,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceKey);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        var source = await ReadSourceByKeyAsync(
            connection,
            transaction,
            sourceKey,
            cancellationToken);
        transaction.Commit();
        return source ?? throw new KeyNotFoundException(
            $"Repository source '{sourceKey}' does not exist.");
    }

    public async Task<RepositorySource> GetSourceByIdAsync(
        long sourceId,
        CancellationToken cancellationToken = default)
    {
        if (sourceId <= 0) throw new ArgumentOutOfRangeException(nameof(sourceId));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT source_id,source_key,root_path,created_utc FROM sources WHERE source_id=$id;";
        command.Parameters.AddWithValue("$id", sourceId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            throw new KeyNotFoundException($"Repository source id '{sourceId}' does not exist.");
        return new RepositorySource(
            reader.GetInt64(0), reader.GetString(1), reader.GetString(2),
            DateTimeOffset.Parse(
                reader.GetString(3), System.Globalization.CultureInfo.InvariantCulture));
    }

    public async Task<StartedRun> StartRunAsync(
        RepositoryWriterLease lease,
        long sourceId,
        CancellationToken cancellationToken = default)
        => await StartRunCoreAsync(lease, sourceId, null, cancellationToken);

    public async Task<StartedRun> StartRunAsync(
        RepositoryWriterLease lease,
        long sourceId,
        long runIndex,
        CancellationToken cancellationToken = default)
        => await StartRunCoreAsync(lease, sourceId, runIndex, cancellationToken);

    private async Task<StartedRun> StartRunCoreAsync(
        RepositoryWriterLease lease,
        long sourceId,
        long? requestedRunIndex,
        CancellationToken cancellationToken)
    {
        EnsureLease(lease);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();

        long runIndex;
        var ownsWorkflow = requestedRunIndex is null;
        if (requestedRunIndex is null)
        {
            await using var allocate = connection.CreateCommand();
            allocate.Transaction = transaction;
            allocate.CommandText =
                """
                UPDATE repository_info
                SET next_run_index = next_run_index + 1
                WHERE singleton = 1
                RETURNING next_run_index - 1;
                """;
            runIndex = Convert.ToInt64(
                await allocate.ExecuteScalarAsync(cancellationToken),
                CultureInfo.InvariantCulture);
        }
        else
        {
            runIndex = requestedRunIndex.Value;
            await using var bind = connection.CreateCommand();
            bind.Transaction = transaction;
            bind.CommandText =
                """
                UPDATE workflow_runs
                SET source_id = COALESCE(source_id, $sourceId)
                WHERE run_index = $runIndex
                  AND status = 'Running'
                  AND (source_id = $sourceId OR source_id IS NULL)
                RETURNING 1;
                """;
            bind.Parameters.AddWithValue("$runIndex", runIndex);
            bind.Parameters.AddWithValue("$sourceId", sourceId);
            if (await bind.ExecuteScalarAsync(cancellationToken) is null)
            {
                throw new InvalidOperationException(
                    $"Workflow run {runIndex} is not a running workflow for source {sourceId}.");
            }
        }

        var startedUtc = DateTimeOffset.UtcNow;
        if (ownsWorkflow)
        {
            await using var workflow = connection.CreateCommand();
            workflow.Transaction = transaction;
            workflow.CommandText =
                """
                INSERT INTO workflow_runs(
                    run_index, pipeline, source_id, owner_component, status, started_utc)
                VALUES ($runIndex, 'backup', $sourceId, 'backup-worker', 'Running', $startedUtc);
                """;
            workflow.Parameters.AddWithValue("$runIndex", runIndex);
            workflow.Parameters.AddWithValue("$sourceId", sourceId);
            workflow.Parameters.AddWithValue("$startedUtc", startedUtc.ToString("O"));
            await workflow.ExecuteNonQueryAsync(cancellationToken);
            await StampWorkflowProcessAsync(connection, transaction, runIndex, null, cancellationToken);
        }

        await using (var stage = connection.CreateCommand())
        {
            stage.Transaction = transaction;
            stage.CommandText =
                """
                INSERT INTO workflow_stages(run_index, producer, status, started_utc)
                VALUES ($runIndex, 'backup-worker', 'Running', $startedUtc);
                """;
            stage.Parameters.AddWithValue("$runIndex", runIndex);
            stage.Parameters.AddWithValue("$startedUtc", startedUtc.ToString("O"));
            await stage.ExecuteNonQueryAsync(cancellationToken);
            await StampWorkflowProcessAsync(connection, transaction, runIndex, "backup-worker", cancellationToken);
        }

        transaction.Commit();
        return new StartedRun(runIndex, sourceId, startedUtc, ownsWorkflow);
    }

    public async Task CompleteRunAsync(
        RepositoryWriterLease lease,
        long runIndex,
        RunStatus status,
        string? failureCode = null,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        if (status == RunStatus.Running)
        {
            throw new ArgumentException("A completed run cannot remain Running.", nameof(status));
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await CompleteBackupStageInTransactionAsync(
                connection,
                transaction,
                runIndex,
                status == RunStatus.Succeeded ? WorkflowStatus.Succeeded : Enum.Parse<WorkflowStatus>(status.ToString()),
                failureCode,
                cancellationToken);
            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<SourceState> GetSourceStateAsync(
        long sourceId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT current_revision, volume_identity, journal_id, next_usn
            FROM source_state
            WHERE source_id = $sourceId;
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            throw new KeyNotFoundException($"Source {sourceId} does not exist.");
        }

        var checkpoint = reader.IsDBNull(1)
            ? null
            : new SourceCheckpoint(reader.GetString(1), reader.GetString(2), reader.GetInt64(3));
        return new SourceState(sourceId, reader.GetInt64(0), checkpoint);
    }

    /// <summary>
    /// When the run that made the source's newest revision started; null without a revision. The current
    /// catalog reflects every write to the source before that moment. Maintenance runs are worker runs
    /// too, so this is deliberately taken from the revision, not from the newest run.
    /// </summary>
    public async Task<DateTimeOffset?> ReadLatestRevisionRunStartAsync(
        long sourceId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT run.started_utc FROM revisions AS revision
            JOIN worker_runs AS run ON run.run_index = revision.run_index
            WHERE revision.source_id = $sourceId
            ORDER BY revision.revision DESC LIMIT 1;
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        return await command.ExecuteScalarAsync(cancellationToken) is string started
            && DateTimeOffset.TryParse(started, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.RoundtripKind, out var value)
            ? value : null;
    }

    public async Task<SqliteConnection> OpenConnectionAsync(
        CancellationToken cancellationToken = default)
    {
        var initialized = await RepositoryConnectionInitialization.OpenAsync(
            () => new SqliteConnection(connectionString),
            async (connection, token) =>
            {
                await ConfigureConnectionAsync(connection, token, enableWal: false);
                // Force WAL shared-memory initialization before handing this connection
                // to application code. Never replay a caller's transaction or writes.
                await using var probe = connection.CreateCommand();
                probe.CommandText = "PRAGMA schema_version;";
                await probe.ExecuteScalarAsync(token);
                return true;
            }, cancellationToken);
        return initialized.Connection;
    }

    private static async Task<RepositoryIdentity> ReadOrCreateIdentityAsync(
        SqliteConnection connection,
        int schemaVersion,
        CancellationToken cancellationToken)
    {
        using var transaction = connection.BeginTransaction();
        await using var select = connection.CreateCommand();
        select.Transaction = transaction;
        select.CommandText =
            """
            SELECT repository_id, format_version, schema_version, created_utc
            FROM repository_info
            WHERE singleton = 1;
            """;
        await using var reader = await select.ExecuteReaderAsync(cancellationToken);
        if (await reader.ReadAsync(cancellationToken))
        {
            var identity = ReadIdentity(reader);
            await reader.DisposeAsync();
            if (identity.FormatVersion != CurrentFormatVersion)
            {
                throw new InvalidDataException(
                    $"repository-reset-required: unsupported repository format {identity.FormatVersion}.");
            }

            if (identity.SchemaVersion != schemaVersion)
                throw new InvalidDataException("repository-reset-required: unsupported repository schema.");

            transaction.Commit();
            return identity;
        }

        await reader.DisposeAsync();
        var created = new RepositoryIdentity(
            Guid.NewGuid(),
            CurrentFormatVersion,
            schemaVersion,
            DateTimeOffset.UtcNow);
        await using var insert = connection.CreateCommand();
        insert.Transaction = transaction;
        insert.CommandText =
            """
            INSERT INTO repository_info(
                singleton, repository_id, format_version, schema_version,
                next_run_index, created_utc)
            VALUES (1, $repositoryId, $formatVersion, $schemaVersion, 1, $createdUtc);
            """;
        insert.Parameters.AddWithValue("$repositoryId", created.RepositoryId.ToByteArray());
        insert.Parameters.AddWithValue("$formatVersion", created.FormatVersion);
        insert.Parameters.AddWithValue("$schemaVersion", created.SchemaVersion);
        insert.Parameters.AddWithValue("$createdUtc", created.CreatedUtc.ToString("O"));
        await insert.ExecuteNonQueryAsync(cancellationToken);
        transaction.Commit();
        return created;
    }

    private static RepositoryIdentity ReadIdentity(SqliteDataReader reader)
    {
        return new RepositoryIdentity(
            reader.GetGuid(0),
            reader.GetInt32(1),
            reader.GetInt32(2),
            DateTimeOffset.Parse(reader.GetString(3), CultureInfo.InvariantCulture));
    }

    private static async Task<RepositoryIdentity> ReadExistingIdentityAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT repository_id, format_version, schema_version, created_utc
            FROM repository_info
            WHERE singleton = 1;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            throw new InvalidDataException("Repository identity is missing.");
        }

        var formatVersion = reader.GetInt32(1);
        var schemaVersion = reader.GetInt32(2);
        if (formatVersion != CurrentFormatVersion
            || schemaVersion is not (RepositorySchema.CurrentVersion or RepositorySchema.UpgradableVersion))
            throw new InvalidDataException(
                $"repository-reset-required: format/schema {formatVersion}/{schemaVersion} is incompatible with "
                + $"{CurrentFormatVersion}/{RepositorySchema.CurrentVersion}. Use a new backup repository; only schema "
                + $"{RepositorySchema.UpgradableVersion} is upgraded.");
        var identity = ReadIdentity(reader);
        await reader.DisposeAsync();
        if (await RepositoryMigrationRunner.GetVersionAsync(connection, cancellationToken) != schemaVersion)
            throw new InvalidDataException("repository-reset-required: inconsistent repository schema marker.");
        return identity;
    }

    private static async Task<RepositorySource?> ReadSourceByKeyAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string sourceKey,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT source_id, source_key, root_path, created_utc
            FROM sources
            WHERE source_key = $key COLLATE NOCASE;
            """;
        command.Parameters.AddWithValue("$key", sourceKey);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken)
            ? new RepositorySource(
                reader.GetInt64(0),
                reader.GetString(1),
                reader.GetString(2),
                DateTimeOffset.Parse(reader.GetString(3), CultureInfo.InvariantCulture))
            : null;
    }

    private static async Task ConfigureConnectionAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken,
        bool enableWal)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = enableWal
            ? "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL;"
            : "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;";
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private void EnsureLease(RepositoryWriterLease lease)
    {
        ArgumentNullException.ThrowIfNull(lease);
        lease.EnsureHeldFor(RepositoryPath);
    }

    private static async Task IncrementRepositoryChangeRevisionAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "UPDATE repository_info SET repository_change_revision="
            + "repository_change_revision+1 WHERE singleton=1;";
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
