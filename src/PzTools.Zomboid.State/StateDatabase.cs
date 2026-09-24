using System.Globalization;
using Microsoft.Data.Sqlite;

namespace PzTools.Zomboid.State;

public sealed class StateDatabase
{
    private const int CurrentSchemaVersion = 3;
    private readonly string connectionString;

    private StateDatabase(string path)
    {
        DatabasePath = path;
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString();
    }

    public string DatabasePath { get; }

    public static async Task<StateDatabase> CreateOrOpenAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        var absolute = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(absolute)!);
        var database = new StateDatabase(absolute);
        await using var connection = await database.OpenAsync(cancellationToken);
        await using var schema = connection.CreateCommand();
        schema.CommandText =
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='state_info';";
        var hasExistingSchema = Convert.ToInt32(
            await schema.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture) != 0;
        if (hasExistingSchema)
        {
            schema.CommandText = "SELECT schema_version FROM state_info WHERE singleton=1;";
            var existingVersion = Convert.ToInt32(
                await schema.ExecuteScalarAsync(cancellationToken),
                CultureInfo.InvariantCulture);
            if (existingVersion > CurrentSchemaVersion)
            {
                throw new InvalidDataException(
                    $"State schema {existingVersion} is newer than supported schema {CurrentSchemaVersion}.");
            }
        }
        schema.CommandText =
            """
            CREATE TABLE IF NOT EXISTS state_schema_migrations (
                version INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                applied_utc TEXT NOT NULL
            ) STRICT;
            INSERT OR IGNORE INTO state_schema_migrations
                VALUES(1,'initial state projection',$migrationUtc);

            CREATE TABLE IF NOT EXISTS state_info (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                schema_version INTEGER NOT NULL,
                state_revision INTEGER NOT NULL,
                initialized INTEGER NOT NULL CHECK(initialized IN (0,1)),
                next_run_index INTEGER NOT NULL
            ) STRICT;
            INSERT OR IGNORE INTO state_info VALUES(1, 2, 0, 0, 1);

            CREATE TABLE IF NOT EXISTS pending_batches (
                batch_id TEXT PRIMARY KEY,
                run_index INTEGER NOT NULL,
                started_utc TEXT NOT NULL,
                completed_utc TEXT NOT NULL,
                elapsed_ms INTEGER NOT NULL,
                discovery_complete INTEGER NOT NULL CHECK(discovery_complete IN (0,1)),
                created_utc TEXT NOT NULL
            ) STRICT;
            CREATE TABLE IF NOT EXISTS pending_save_observations (
                batch_id TEXT NOT NULL REFERENCES pending_batches(batch_id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                mode TEXT NOT NULL,
                display_name TEXT NOT NULL,
                has_players_db INTEGER NOT NULL,
                invalidated INTEGER NOT NULL,
                activity TEXT NOT NULL,
                character_state TEXT NOT NULL,
                activity_lane_status TEXT NOT NULL,
                character_lane_status TEXT NOT NULL,
                error_code TEXT NULL,
                last_played_utc TEXT NULL,
                PRIMARY KEY(batch_id, path)
            ) STRICT;
            CREATE TABLE IF NOT EXISTS save_observation_state (
                path TEXT PRIMARY KEY,
                confirmed_activity TEXT NOT NULL,
                candidate_activity TEXT NOT NULL,
                consecutive_count INTEGER NOT NULL
            ) STRICT;
            CREATE TABLE IF NOT EXISTS current_game_state (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                game_state TEXT NOT NULL,
                changed_revision INTEGER NOT NULL
            ) STRICT;
            CREATE TABLE IF NOT EXISTS current_save_state (
                path TEXT PRIMARY KEY,
                mode TEXT NOT NULL,
                display_name TEXT NOT NULL,
                activity TEXT NOT NULL,
                character_state TEXT NOT NULL,
                stale INTEGER NOT NULL CHECK(stale IN (0,1)),
                changed_revision INTEGER NOT NULL,
                observed_utc TEXT NOT NULL,
                last_played_utc TEXT NULL
            ) STRICT;
            CREATE TABLE IF NOT EXISTS state_transitions (
                transition_id TEXT PRIMARY KEY,
                batch_id TEXT NOT NULL,
                path TEXT NOT NULL,
                kind TEXT NOT NULL,
                previous_value TEXT NOT NULL,
                current_value TEXT NOT NULL,
                state_revision INTEGER NOT NULL,
                created_utc TEXT NOT NULL
            ) STRICT;
            CREATE TABLE IF NOT EXISTS scheduler_outbox (
                message_id TEXT PRIMARY KEY,
                idempotency_key TEXT NOT NULL UNIQUE,
                command TEXT NOT NULL,
                save_id TEXT NOT NULL,
                source_key TEXT NOT NULL,
                source_path TEXT NOT NULL,
                transition_id TEXT NOT NULL,
                state_run_index INTEGER NOT NULL,
                acknowledged_utc TEXT NULL,
                created_utc TEXT NOT NULL
            ) STRICT;
            """;
        schema.Parameters.AddWithValue("$migrationUtc", DateTimeOffset.UtcNow.ToString("O"));
        await schema.ExecuteNonQueryAsync(cancellationToken);
        schema.CommandText = "SELECT schema_version FROM state_info WHERE singleton=1;";
        var schemaVersion = Convert.ToInt32(
            await schema.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture);
        if (schemaVersion > CurrentSchemaVersion)
        {
            throw new InvalidDataException(
                $"State schema {schemaVersion} is newer than supported schema {CurrentSchemaVersion}.");
        }
        await database.MigrateOutboxToDynamicTargetsAsync(connection, cancellationToken);
        await database.MigrateLastPlayedUtcAsync(connection, cancellationToken);
        return database;
    }

    public async Task WritePendingBatchAsync(
        CollectionBatch batch,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(batch);
        await using var connection = await OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await using (var insert = connection.CreateCommand())
            {
                insert.Transaction = transaction;
                insert.CommandText =
                    """
                    INSERT INTO pending_batches(
                        batch_id, run_index, started_utc, completed_utc, elapsed_ms,
                        discovery_complete, created_utc)
                    VALUES($id,$run,$started,$completed,$elapsed,$complete,$created);
                    """;
                insert.Parameters.AddWithValue("$id", batch.BatchId);
                insert.Parameters.AddWithValue("$run", batch.RunIndex);
                insert.Parameters.AddWithValue("$started", batch.StartedUtc.ToString("O"));
                insert.Parameters.AddWithValue("$completed", batch.CompletedUtc.ToString("O"));
                insert.Parameters.AddWithValue("$elapsed", batch.ElapsedMilliseconds);
                insert.Parameters.AddWithValue("$complete", batch.DiscoveryComplete ? 1 : 0);
                insert.Parameters.AddWithValue("$created", DateTimeOffset.UtcNow.ToString("O"));
                await insert.ExecuteNonQueryAsync(cancellationToken);
            }

            foreach (var save in batch.Saves)
            {
                await using var insert = connection.CreateCommand();
                insert.Transaction = transaction;
                insert.CommandText =
                    """
                    INSERT INTO pending_save_observations(
                        batch_id,path,mode,display_name,has_players_db,invalidated,
                        activity,character_state,activity_lane_status,
                        character_lane_status,error_code,last_played_utc)
                    VALUES(
                        $batch,$path,$mode,$name,$hasDb,$invalidated,$activity,$character,
                        $activityStatus,$characterStatus,$error,$lastPlayed);
                    """;
                insert.Parameters.AddWithValue("$batch", batch.BatchId);
                insert.Parameters.AddWithValue("$path", save.NormalizedPath);
                insert.Parameters.AddWithValue("$mode", save.Mode);
                insert.Parameters.AddWithValue("$name", save.DisplayName);
                insert.Parameters.AddWithValue("$hasDb", save.HasPlayersDatabase ? 1 : 0);
                insert.Parameters.AddWithValue("$invalidated", save.Invalidated ? 1 : 0);
                insert.Parameters.AddWithValue("$activity", save.Activity.ToString());
                insert.Parameters.AddWithValue("$character", save.Character.ToString());
                insert.Parameters.AddWithValue("$activityStatus", save.ActivityLaneStatus.ToString());
                insert.Parameters.AddWithValue("$characterStatus", save.CharacterLaneStatus.ToString());
                insert.Parameters.AddWithValue("$error", (object?)save.ErrorCode ?? DBNull.Value);
                insert.Parameters.AddWithValue(
                    "$lastPlayed", (object?)save.LastPlayedUtc?.ToString("O") ?? DBNull.Value);
                await insert.ExecuteNonQueryAsync(cancellationToken);
            }

            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<bool> HasPendingBatchesAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT EXISTS(SELECT 1 FROM pending_batches);";
        return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) != 0;
    }

    public async Task<long> AllocateRunIndexAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE state_info SET next_run_index = next_run_index + 1
            WHERE singleton = 1 RETURNING next_run_index - 1;
            """;
        return Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
    }

    public async Task<IReadOnlyList<SchedulerOutboxMessage>> ReadPendingOutboxAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT message_id,idempotency_key,command,save_id,source_key,source_path,
                   transition_id,state_run_index
            FROM scheduler_outbox WHERE acknowledged_utc IS NULL ORDER BY created_utc,message_id;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var result = new List<SchedulerOutboxMessage>();
        while (await reader.ReadAsync(cancellationToken))
        {
            result.Add(new SchedulerOutboxMessage(
                reader.GetString(0), reader.GetString(1), reader.GetString(2),
                reader.GetString(3), reader.GetString(4), reader.GetString(5),
                reader.GetString(6), reader.GetInt64(7)));
        }
        return result;
    }

    public async Task AcknowledgeOutboxAsync(
        string messageId, CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            "UPDATE scheduler_outbox SET acknowledged_utc=$now WHERE message_id=$id AND acknowledged_utc IS NULL;";
        command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$id", messageId);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<CurrentStateSnapshot> ReadCurrentStateIfChangedAsync(
        long lastSeenRevision,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenAsync(cancellationToken);
        // A projection is a read snapshot, not a writer. IMMEDIATE transactions here
        // needlessly compete with the collector/reactor during startup and UI polling.
        using var transaction = connection.BeginTransaction(deferred: true);
        await using var revisionCommand = connection.CreateCommand();
        revisionCommand.Transaction = transaction;
        revisionCommand.CommandText = "SELECT state_revision FROM state_info WHERE singleton = 1;";
        var revision = Convert.ToInt64(await revisionCommand.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
        if (revision == lastSeenRevision)
        {
            transaction.Commit();
            return new CurrentStateSnapshot(false, revision, GameState.Unknown, []);
        }

        await using var gameCommand = connection.CreateCommand();
        gameCommand.Transaction = transaction;
        gameCommand.CommandText = "SELECT game_state FROM current_game_state WHERE singleton = 1;";
        var gameValue = await gameCommand.ExecuteScalarAsync(cancellationToken);
        var game = gameValue is null ? GameState.Unknown : Enum.Parse<GameState>((string)gameValue);
        await using var savesCommand = connection.CreateCommand();
        savesCommand.Transaction = transaction;
        savesCommand.CommandText =
            """
            SELECT path,mode,display_name,activity,character_state,stale,changed_revision,
                   last_played_utc,observed_utc
            FROM current_save_state ORDER BY path;
            """;
        await using var reader = await savesCommand.ExecuteReaderAsync(cancellationToken);
        var saves = new List<CurrentSaveState>();
        while (await reader.ReadAsync(cancellationToken))
        {
            saves.Add(new CurrentSaveState(
                reader.GetString(0), reader.GetString(1), reader.GetString(2),
                Enum.Parse<ActivityState>(reader.GetString(3)),
                Enum.Parse<CharacterState>(reader.GetString(4)),
                reader.GetInt64(5) != 0, reader.GetInt64(6),
                reader.IsDBNull(7) ? null : DateTimeOffset.Parse(
                    reader.GetString(7), CultureInfo.InvariantCulture),
                DateTimeOffset.Parse(reader.GetString(8), CultureInfo.InvariantCulture)));
        }

        transaction.Commit();
        return new CurrentStateSnapshot(true, revision, game, saves);
    }

    internal async Task<SqliteConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqliteConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=250; PRAGMA journal_mode=WAL;";
        await command.ExecuteNonQueryAsync(cancellationToken);
        return connection;
    }

    private static async Task<bool> HasColumnAsync(
        SqliteConnection connection,
        string table,
        string column,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = $"PRAGMA table_info({table});";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            if (StringComparer.OrdinalIgnoreCase.Equals(reader.GetString(1), column)) return true;
        }
        return false;
    }

    private async Task MigrateOutboxToDynamicTargetsAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        if (await HasColumnAsync(connection, "scheduler_outbox", "save_id", cancellationToken))
        {
            await using var version = connection.CreateCommand();
            version.CommandText = "UPDATE state_info SET schema_version=2 WHERE singleton=1 AND schema_version<2;";
            await version.ExecuteNonQueryAsync(cancellationToken);
            return;
        }

        using var transaction = connection.BeginTransaction();
        try
        {
            await using var migrate = connection.CreateCommand();
            migrate.Transaction = transaction;
            migrate.CommandText =
                """
                ALTER TABLE scheduler_outbox RENAME TO scheduler_outbox_legacy_v1;
                CREATE TABLE scheduler_outbox (
                    message_id TEXT PRIMARY KEY,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    command TEXT NOT NULL,
                    save_id TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    source_path TEXT NOT NULL,
                    transition_id TEXT NOT NULL,
                    state_run_index INTEGER NOT NULL,
                    acknowledged_utc TEXT NULL,
                    created_utc TEXT NOT NULL
                ) STRICT;
                INSERT OR IGNORE INTO state_schema_migrations
                    VALUES(2,'dynamic backup target outbox',$migrationUtc);
                UPDATE state_info SET schema_version=2 WHERE singleton=1;
                """;
            migrate.Parameters.AddWithValue("$migrationUtc", DateTimeOffset.UtcNow.ToString("O"));
            await migrate.ExecuteNonQueryAsync(cancellationToken);
            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    private async Task MigrateLastPlayedUtcAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        if (!await HasColumnAsync(
                connection, "pending_save_observations", "last_played_utc", cancellationToken))
        {
            await using var pending = connection.CreateCommand();
            pending.CommandText =
                "ALTER TABLE pending_save_observations ADD COLUMN last_played_utc TEXT NULL;";
            await pending.ExecuteNonQueryAsync(cancellationToken);
        }
        if (!await HasColumnAsync(
                connection, "current_save_state", "last_played_utc", cancellationToken))
        {
            await using var current = connection.CreateCommand();
            current.CommandText =
                "ALTER TABLE current_save_state ADD COLUMN last_played_utc TEXT NULL;";
            await current.ExecuteNonQueryAsync(cancellationToken);
        }
        await using var version = connection.CreateCommand();
        version.CommandText =
            """
            INSERT OR IGNORE INTO state_schema_migrations
                VALUES(3,'save last played timestamp',$migrationUtc);
            UPDATE state_info SET schema_version=3 WHERE singleton=1;
            """;
        version.Parameters.AddWithValue("$migrationUtc", DateTimeOffset.UtcNow.ToString("O"));
        await version.ExecuteNonQueryAsync(cancellationToken);
    }
}
