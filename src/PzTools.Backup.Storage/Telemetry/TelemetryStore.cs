using System.Globalization;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Storage.Telemetry;

public sealed class TelemetryStore
{
    public const int CurrentFormatVersion = 1;
    public const int CurrentSchemaVersion = 2;
    public const string DatabaseFileName = "telemetry.db";

    private readonly string connectionString;
    private readonly bool available;
    private Exception? failure;

    private TelemetryStore(
        string repositoryPath,
        string databasePath,
        bool available,
        Exception? failure = null)
    {
        RepositoryPath = repositoryPath;
        DatabasePath = databasePath;
        this.available = available;
        this.failure = failure;
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
            Pooling = false,
        }.ToString();
    }

    public string RepositoryPath { get; }

    public string DatabasePath { get; }

    public bool IsAvailable => available;

    public Exception? Failure => Volatile.Read(ref failure);

    public async Task<BackupTelemetryInfo> ReadInfoAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT format_version,schema_version,telemetry_instance_id,producer,created_utc
            FROM telemetry_info WHERE singleton=1;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            throw new InvalidDataException("Backup telemetry metadata is missing.");
        return new BackupTelemetryInfo(
            reader.GetInt32(0), reader.GetInt32(1), Guid.Parse(reader.GetString(2)),
            reader.GetString(3),
            DateTimeOffset.Parse(reader.GetString(4), CultureInfo.InvariantCulture));
    }

    public async Task<IReadOnlyList<BackupTelemetryEvent>> ReadEventsAfterAsync(
        long afterEventId,
        int limit = 512,
        CancellationToken cancellationToken = default)
    {
        if (afterEventId < 0) throw new ArgumentOutOfRangeException(nameof(afterEventId));
        if (limit <= 0) throw new ArgumentOutOfRangeException(nameof(limit));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT event_id,run_index,sequence,event_version,scope,name,
                   timestamp_utc,elapsed_ticks,payload_json
            FROM telemetry_events WHERE event_id>$after ORDER BY event_id LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$after", afterEventId);
        command.Parameters.AddWithValue("$limit", limit);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var events = new List<BackupTelemetryEvent>();
        while (await reader.ReadAsync(cancellationToken))
        {
            events.Add(new BackupTelemetryEvent(
                reader.GetInt64(0), reader.GetInt64(1), reader.GetInt64(2),
                reader.GetInt32(3), Enum.Parse<TelemetryEventScope>(reader.GetString(4)),
                reader.GetString(5),
                DateTimeOffset.Parse(reader.GetString(6), CultureInfo.InvariantCulture),
                reader.GetInt64(7), reader.IsDBNull(8) ? null : reader.GetString(8)));
        }
        return events;
    }

    public static async Task<TelemetryStore> CreateOrOpenAsync(
        string repositoryPath,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);
        var absoluteRepositoryPath = Path.GetFullPath(repositoryPath);
        Directory.CreateDirectory(absoluteRepositoryPath);
        var databasePath = Path.Combine(absoluteRepositoryPath, DatabaseFileName);
        var store = new TelemetryStore(absoluteRepositoryPath, databasePath, available: true);
        await using var connection = await store.OpenConnectionAsync(cancellationToken);
        await InitializeSchemaAsync(connection, cancellationToken);
        return store;
    }

    public static TelemetryStore CreateDisabled(string repositoryPath, Exception? failure = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);
        var absoluteRepositoryPath = Path.GetFullPath(repositoryPath);
        return new TelemetryStore(
            absoluteRepositoryPath,
            Path.Combine(absoluteRepositoryPath, DatabaseFileName),
            available: false,
            failure);
    }

    public async Task RecoverAbandonedRunsAsync(
        RepositoryWriterLease lease,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(lease);
        lease.EnsureHeldFor(RepositoryPath);

        await using var connection = await OpenConnectionAsync(cancellationToken);
        await MarkRunningAsAbandonedAsync(connection, cancellationToken);
    }

    public async Task ReconcileRunsAsync(
        RepositoryWriterLease lease,
        RepositoryDatabase repository,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(lease);
        ArgumentNullException.ThrowIfNull(repository);
        lease.EnsureHeldFor(RepositoryPath);
        lease.EnsureHeldFor(repository.RepositoryPath);

        await using var connection = await OpenConnectionAsync(cancellationToken);
        // Drive reconciliation from retained telemetry, not the unbounded repository history.
        // Only telemetry is written; the authority is read through its run-index primary key.
        await using (var attach = connection.CreateCommand())
        {
            attach.CommandText = "ATTACH DATABASE $path AS authority;";
            attach.Parameters.AddWithValue("$path", repository.DatabasePath);
            await attach.ExecuteNonQueryAsync(cancellationToken);
        }
        await using var command = connection.CreateCommand();
        command.CommandText = """
            UPDATE telemetry_runs AS target
            SET (status, completed_utc, failure_code) = (
                SELECT status, completed_utc, failure_code FROM authority.worker_runs
                WHERE run_index = target.run_index)
            WHERE EXISTS (
                SELECT 1 FROM authority.worker_runs AS source
                WHERE source.run_index = target.run_index
                  AND (source.status IS NOT target.status
                    OR source.completed_utc IS NOT target.completed_utc
                    OR source.failure_code IS NOT target.failure_code));
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<TelemetryRunSession> BeginRunAsync(
        long runIndex,
        long sourceId,
        DateTimeOffset startedUtc,
        TelemetryOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (options.Mode == TelemetryMode.Off || !available)
        {
            return TelemetryRunSession.CreateDisabled(runIndex, options.Mode, Failure);
        }

        try
        {
            await using var connection = await OpenConnectionAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText =
                """
                INSERT INTO telemetry_runs(run_index, source_id, status, started_utc)
                VALUES ($runIndex, $sourceId, 'Running', $startedUtc);
                """;
            command.Parameters.AddWithValue("$runIndex", runIndex);
            command.Parameters.AddWithValue("$sourceId", sourceId);
            command.Parameters.AddWithValue("$startedUtc", startedUtc.ToString("O"));
            await command.ExecuteNonQueryAsync(cancellationToken);
            return TelemetryRunSession.Create(this, runIndex, startedUtc, options);
        }
        catch (Exception exception) when (
            exception is SqliteException or IOException or UnauthorizedAccessException)
        {
            RecordFailure(exception);
            return TelemetryRunSession.CreateDisabled(runIndex, options.Mode, exception);
        }
    }

    internal void RecordFailure(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        Interlocked.CompareExchange(ref failure, exception, null);
    }

    public async Task<IReadOnlyList<StoredTelemetryEvent>> ReadEventsAsync(
        long runIndex,
        long afterSequence = 0,
        int limit = 1_000,
        CancellationToken cancellationToken = default)
    {
        if (limit <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(limit));
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT run_index, sequence, event_version, scope, name,
                   timestamp_utc, elapsed_ticks, payload_json
            FROM telemetry_events
            WHERE run_index = $runIndex AND sequence > $afterSequence
            ORDER BY sequence
            LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$runIndex", runIndex);
        command.Parameters.AddWithValue("$afterSequence", afterSequence);
        command.Parameters.AddWithValue("$limit", limit);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var events = new List<StoredTelemetryEvent>();
        while (await reader.ReadAsync(cancellationToken))
        {
            events.Add(new StoredTelemetryEvent(
                reader.GetInt64(0),
                reader.GetInt64(1),
                reader.GetInt32(2),
                Enum.Parse<TelemetryEventScope>(reader.GetString(3)),
                reader.GetString(4),
                DateTimeOffset.Parse(reader.GetString(5), CultureInfo.InvariantCulture),
                reader.GetInt64(6),
                reader.IsDBNull(7) ? null : reader.GetString(7)));
        }

        return events;
    }

    public async Task<TelemetryRunRecord?> ReadRunAsync(
        long runIndex,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT run_index, source_id, status, started_utc, completed_utc, failure_code
            FROM telemetry_runs
            WHERE run_index = $runIndex;
            """;
        command.Parameters.AddWithValue("$runIndex", runIndex);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new TelemetryRunRecord(
            reader.GetInt64(0),
            reader.GetInt64(1),
            reader.GetString(2),
            DateTimeOffset.Parse(reader.GetString(3), CultureInfo.InvariantCulture),
            reader.IsDBNull(4)
                ? null
                : DateTimeOffset.Parse(reader.GetString(4), CultureInfo.InvariantCulture),
            reader.IsDBNull(5) ? null : reader.GetString(5));
    }

    public async Task TrimAsync(
        int retainRuns,
        int maxDatabaseMib,
        CancellationToken cancellationToken = default)
    {
        if (retainRuns < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(retainRuns));
        }

        if (maxDatabaseMib < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxDatabaseMib));
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        if (retainRuns > 0)
        {
            await using var retain = connection.CreateCommand();
            retain.CommandText =
                """
                DELETE FROM telemetry_runs
                WHERE status <> 'Running'
                  AND run_index NOT IN (
                      SELECT run_index
                      FROM telemetry_runs
                      ORDER BY run_index DESC
                      LIMIT $retainRuns
                  );
                """;
            retain.Parameters.AddWithValue("$retainRuns", retainRuns);
            await retain.ExecuteNonQueryAsync(cancellationToken);
        }

        if (maxDatabaseMib > 0)
        {
            var maximumBytes = checked((long)maxDatabaseMib * 1024 * 1024);
            while (await GetLogicalBytesAsync(connection, cancellationToken) > maximumBytes)
            {
                await using var delete = connection.CreateCommand();
                delete.CommandText =
                    """
                    DELETE FROM telemetry_runs
                    WHERE run_index = (
                        SELECT run_index
                        FROM telemetry_runs
                        WHERE status <> 'Running'
                        ORDER BY run_index
                        LIMIT 1
                    );
                    """;
                if (await delete.ExecuteNonQueryAsync(cancellationToken) == 0)
                {
                    break;
                }
            }
        }

        await using var checkpoint = connection.CreateCommand();
        checkpoint.CommandText = "PRAGMA wal_checkpoint(PASSIVE);";
        await checkpoint.ExecuteNonQueryAsync(cancellationToken);
    }

    internal async Task WriteBatchAsync(
        IReadOnlyList<PendingTelemetryEvent> events,
        CancellationToken cancellationToken)
    {
        if (events.Count == 0)
        {
            return;
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        foreach (var item in events)
        {
            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                """
                INSERT INTO telemetry_events(
                    event_id,run_index, sequence, event_version, scope, name,
                    timestamp_utc, elapsed_ticks, payload_json)
                VALUES (
                    (SELECT COALESCE(MAX(event_id),0)+1 FROM telemetry_events),
                    $runIndex, $sequence, 1, $scope, $name,
                    $timestampUtc, $elapsedTicks, $payloadJson);
                """;
            command.Parameters.AddWithValue("$runIndex", item.RunIndex);
            command.Parameters.AddWithValue("$sequence", item.Sequence);
            command.Parameters.AddWithValue("$scope", item.Event.Scope.ToString());
            command.Parameters.AddWithValue("$name", item.Event.Name);
            command.Parameters.AddWithValue("$timestampUtc", item.TimestampUtc.ToString("O"));
            command.Parameters.AddWithValue("$elapsedTicks", item.ElapsedTicks);
            command.Parameters.AddWithValue(
                "$payloadJson",
                (object?)item.Event.PayloadJson ?? DBNull.Value);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }

        transaction.Commit();
    }

    internal async Task CompleteRunAsync(
        long runIndex,
        RunStatus status,
        string? failureCode,
        CancellationToken cancellationToken)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE telemetry_runs
            SET status = $status, completed_utc = $completedUtc, failure_code = $failureCode
            WHERE run_index = $runIndex AND status = 'Running';
            """;
        command.Parameters.AddWithValue("$status", status.ToString());
        command.Parameters.AddWithValue("$completedUtc", DateTimeOffset.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$failureCode", (object?)failureCode ?? DBNull.Value);
        command.Parameters.AddWithValue("$runIndex", runIndex);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private async Task<SqliteConnection> OpenConnectionAsync(CancellationToken cancellationToken)
    {
        var connection = new SqliteConnection(connectionString);
        try
        {
            await connection.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;";
            await command.ExecuteNonQueryAsync(cancellationToken);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private static async Task InitializeSchemaAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            PRAGMA journal_mode = WAL;

            CREATE TABLE IF NOT EXISTS telemetry_info (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
                format_version INTEGER NOT NULL,
                schema_version INTEGER NOT NULL,
                created_utc TEXT NOT NULL
            ) STRICT;

            INSERT OR IGNORE INTO telemetry_info(
                singleton, format_version, schema_version, created_utc)
            VALUES (1, 1, 1, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));

            CREATE TABLE IF NOT EXISTS telemetry_runs (
                run_index INTEGER NOT NULL PRIMARY KEY,
                source_id INTEGER NOT NULL,
                status TEXT NOT NULL CHECK (
                    status IN ('Running', 'Succeeded', 'Failed', 'Cancelled', 'Abandoned')
                ),
                started_utc TEXT NOT NULL,
                completed_utc TEXT NULL,
                failure_code TEXT NULL
            ) STRICT;

            CREATE TABLE IF NOT EXISTS telemetry_events (
                run_index INTEGER NOT NULL REFERENCES telemetry_runs(run_index) ON DELETE CASCADE,
                sequence INTEGER NOT NULL CHECK (sequence >= 1),
                event_version INTEGER NOT NULL,
                scope TEXT NOT NULL CHECK (scope IN ('Run', 'Phase', 'Raw')),
                name TEXT NOT NULL,
                timestamp_utc TEXT NOT NULL,
                elapsed_ticks INTEGER NOT NULL CHECK (elapsed_ticks >= 0),
                payload_json TEXT NULL,
                PRIMARY KEY (run_index, sequence)
            ) STRICT;

            CREATE INDEX IF NOT EXISTS ix_telemetry_runs_status
                ON telemetry_runs(status, run_index);
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);

        command.CommandText =
            "SELECT format_version,schema_version FROM telemetry_info WHERE singleton=1;";
        await using (var versionReader = await command.ExecuteReaderAsync(cancellationToken))
        {
            if (!await versionReader.ReadAsync(cancellationToken)
                || versionReader.GetInt32(0) != CurrentFormatVersion
                || versionReader.GetInt32(1) > CurrentSchemaVersion)
                throw new InvalidDataException("Unsupported telemetry database format.");
        }

        var infoColumns = await ReadColumnsAsync(
            connection, "telemetry_info", cancellationToken);
        foreach (var (name, definition) in new[]
        {
            ("telemetry_instance_id", "TEXT NULL"),
            ("producer", "TEXT NULL"),
        })
        {
            if (infoColumns.Contains(name)) continue;
            command.CommandText = $"ALTER TABLE telemetry_info ADD COLUMN {name} {definition};";
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        var eventColumns = await ReadColumnsAsync(
            connection, "telemetry_events", cancellationToken);
        if (!eventColumns.Contains("event_id"))
        {
            command.CommandText = "ALTER TABLE telemetry_events ADD COLUMN event_id INTEGER NULL;";
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        command.CommandText =
            """
            UPDATE telemetry_events SET event_id=rowid WHERE event_id IS NULL;
            CREATE UNIQUE INDEX IF NOT EXISTS ux_telemetry_event_id
                ON telemetry_events(event_id);
            UPDATE telemetry_info
            SET schema_version=2,
                telemetry_instance_id=COALESCE(telemetry_instance_id,$instance),
                producer=COALESCE(producer,'backup');
            """;
        command.Parameters.Clear();
        command.Parameters.AddWithValue("$instance", Guid.NewGuid().ToString("D"));
        await command.ExecuteNonQueryAsync(cancellationToken);

        command.CommandText =
            "SELECT format_version, schema_version FROM telemetry_info WHERE singleton = 1;";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)
            || reader.GetInt32(0) != CurrentFormatVersion
            || reader.GetInt32(1) != CurrentSchemaVersion)
        {
            throw new InvalidDataException("Unsupported telemetry database format.");
        }
    }

    private static async Task<HashSet<string>> ReadColumnsAsync(
        SqliteConnection connection,
        string table,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = $"SELECT name FROM pragma_table_info('{table}');";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (await reader.ReadAsync(cancellationToken)) columns.Add(reader.GetString(0));
        return columns;
    }

    private static async Task MarkRunningAsAbandonedAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE telemetry_runs
            SET status = 'Abandoned', completed_utc = $completedUtc,
                failure_code = 'process-interrupted'
            WHERE status = 'Running';
            """;
        command.Parameters.AddWithValue("$completedUtc", DateTimeOffset.UtcNow.ToString("O"));
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task<long> GetLogicalBytesAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        var pageCount = await ReadPragmaInt64Async(connection, "page_count", cancellationToken);
        var freePages = await ReadPragmaInt64Async(connection, "freelist_count", cancellationToken);
        var pageSize = await ReadPragmaInt64Async(connection, "page_size", cancellationToken);
        return checked((pageCount - freePages) * pageSize);
    }

    private static async Task<long> ReadPragmaInt64Async(
        SqliteConnection connection,
        string name,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = $"PRAGMA {name};";
        return Convert.ToInt64(
            await command.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture);
    }
}

internal sealed record PendingTelemetryEvent(
    long RunIndex,
    long Sequence,
    TelemetryEvent Event,
    DateTimeOffset TimestampUtc,
    long ElapsedTicks);
