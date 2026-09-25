using System.Diagnostics;
using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts;

namespace PzTools.Process.Telemetry;

public sealed class ProcessTelemetryStore
{
    private readonly string connectionString;
    private readonly long startedTimestamp = Stopwatch.GetTimestamp();

    private ProcessTelemetryStore(string databasePath)
    {
        DatabasePath = databasePath;
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString();
    }

    public string DatabasePath { get; }

    public static async Task<ProcessTelemetryStore> CreateForIdentityAsync(
        string identity,
        string component,
        CancellationToken cancellationToken = default)
    {
        var directory = ComponentRuntimePaths.GetComponentDirectory(identity, component);
        Directory.CreateDirectory(directory);
        var store = new ProcessTelemetryStore(Path.Combine(directory, "telemetry.db"));
        await using var connection = await store.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            CREATE TABLE IF NOT EXISTS process_telemetry_info(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                schema_version INTEGER NOT NULL,
                telemetry_instance_id TEXT NULL,
                producer TEXT NULL,
                created_utc TEXT NULL
            ) STRICT;
            INSERT OR IGNORE INTO process_telemetry_info(singleton,schema_version)
            VALUES(1,3);

            CREATE TABLE IF NOT EXISTS telemetry_events(
                event_id INTEGER PRIMARY KEY,
                scope_id TEXT NOT NULL DEFAULT '',
                component TEXT NOT NULL,
                run_index INTEGER NOT NULL,
                event_sequence INTEGER NOT NULL DEFAULT 0,
                event_name TEXT NOT NULL,
                occurred_utc TEXT NOT NULL,
                elapsed_ticks INTEGER NOT NULL DEFAULT 0,
                payload_version INTEGER NOT NULL DEFAULT 1,
                payload_json TEXT NULL
            ) STRICT;
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
        await store.MigrateVersionOneAsync(connection, cancellationToken);
        await EnsureMetadataAsync(connection, component, cancellationToken);
        return store;
    }

    public async Task<ProcessTelemetryInfo> ReadInfoAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT schema_version,telemetry_instance_id,producer,created_utc
            FROM process_telemetry_info WHERE singleton=1;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
            throw new InvalidDataException("Process telemetry metadata is missing.");
        return new ProcessTelemetryInfo(
            reader.GetInt32(0),
            Guid.Parse(reader.GetString(1)),
            reader.GetString(2),
            DateTimeOffset.Parse(
                reader.GetString(3), System.Globalization.CultureInfo.InvariantCulture));
    }

    public async Task<IReadOnlyList<ProcessTelemetryEvent>> ReadEventsAfterAsync(
        long afterEventId,
        int limit = 512,
        CancellationToken cancellationToken = default)
    {
        if (afterEventId < 0) throw new ArgumentOutOfRangeException(nameof(afterEventId));
        if (limit <= 0) throw new ArgumentOutOfRangeException(nameof(limit));
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT event_id,scope_id,component,run_index,event_sequence,event_name,
                   occurred_utc,elapsed_ticks,payload_version,payload_json
            FROM telemetry_events WHERE event_id>$after ORDER BY event_id LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$after", afterEventId);
        command.Parameters.AddWithValue("$limit", limit);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var events = new List<ProcessTelemetryEvent>();
        while (await reader.ReadAsync(cancellationToken))
        {
            events.Add(new ProcessTelemetryEvent(
                reader.GetInt64(0), reader.GetString(1), reader.GetString(2),
                reader.GetInt64(3), reader.GetInt64(4), reader.GetString(5),
                DateTimeOffset.Parse(reader.GetString(6),
                    System.Globalization.CultureInfo.InvariantCulture),
                reader.GetInt64(7), reader.GetInt32(8),
                reader.IsDBNull(9) ? null : reader.GetString(9)));
        }
        return events;
    }

    public async Task RecordAsync(
        string component,
        long runIndex,
        string eventName,
        string? payloadJson = null,
        string? scopeId = null,
        int payloadVersion = 1,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(component);
        ArgumentException.ThrowIfNullOrWhiteSpace(eventName);
        if (runIndex <= 0) throw new ArgumentOutOfRangeException(nameof(runIndex));
        if (payloadVersion <= 0) throw new ArgumentOutOfRangeException(nameof(payloadVersion));
        scopeId = string.IsNullOrWhiteSpace(scopeId) ? component : scopeId;
        await using var connection = await OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO telemetry_events(
                scope_id,component,run_index,event_sequence,event_name,occurred_utc,
                elapsed_ticks,payload_version,payload_json)
            SELECT $scope,$component,$run,
                   COALESCE(MAX(event_sequence),0)+1,$event,$utc,$elapsed,$version,$payload
            FROM telemetry_events
            WHERE scope_id=$scope AND component=$component AND run_index=$run;
            """;
        command.Parameters.AddWithValue("$scope", scopeId);
        command.Parameters.AddWithValue("$component", component);
        command.Parameters.AddWithValue("$run", runIndex);
        command.Parameters.AddWithValue("$event", eventName);
        command.Parameters.AddWithValue("$utc", DateTimeOffset.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$elapsed", Stopwatch.GetTimestamp() - startedTimestamp);
        command.Parameters.AddWithValue("$version", payloadVersion);
        command.Parameters.AddWithValue("$payload", (object?)payloadJson ?? DBNull.Value);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task WriteBatchAsync(
        string component, long runIndex, IReadOnlyList<ProcessTelemetryWrite> events,
        CancellationToken cancellationToken = default)
    {
        if (events.Count == 0) return;
        await using var connection = await OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
        await using var sequence = connection.CreateCommand();
        sequence.Transaction = (SqliteTransaction)transaction;
        sequence.CommandText =
            "SELECT COALESCE(MAX(event_sequence),0) FROM telemetry_events "
            + "WHERE scope_id=$component AND component=$component AND run_index=$run;";
        sequence.Parameters.AddWithValue("$component", component);
        sequence.Parameters.AddWithValue("$run", runIndex);
        var next = Convert.ToInt64(await sequence.ExecuteScalarAsync(cancellationToken)) + 1;
        await using var insert = connection.CreateCommand();
        insert.Transaction = (SqliteTransaction)transaction;
        insert.CommandText =
            """
            INSERT INTO telemetry_events(
                scope_id,component,run_index,event_sequence,event_name,occurred_utc,
                elapsed_ticks,payload_version,payload_json)
            VALUES($component,$component,$run,$sequence,$event,$utc,$elapsed,1,$payload);
            """;
        insert.Parameters.AddWithValue("$component", component);
        insert.Parameters.AddWithValue("$run", runIndex);
        var sequenceParameter = insert.Parameters.Add("$sequence", SqliteType.Integer);
        var eventParameter = insert.Parameters.Add("$event", SqliteType.Text);
        var utcParameter = insert.Parameters.Add("$utc", SqliteType.Text);
        var elapsedParameter = insert.Parameters.Add("$elapsed", SqliteType.Integer);
        var payloadParameter = insert.Parameters.Add("$payload", SqliteType.Text);
        foreach (var item in events)
        {
            sequenceParameter.Value = next++;
            eventParameter.Value = item.Name;
            utcParameter.Value = item.OccurredUtc.ToString("O");
            elapsedParameter.Value = Math.Max(0, item.Timestamp - startedTimestamp);
            payloadParameter.Value = (object?)item.PayloadJson ?? DBNull.Value;
            await insert.ExecuteNonQueryAsync(cancellationToken);
        }
        await transaction.CommitAsync(cancellationToken);
    }

    public async Task TrimAsync(
        string component,
        int retainRuns = 100,
        int maxDatabaseMib = 64,
        CancellationToken cancellationToken = default)
    {
        if (retainRuns < 0) throw new ArgumentOutOfRangeException(nameof(retainRuns));
        if (maxDatabaseMib < 0) throw new ArgumentOutOfRangeException(nameof(maxDatabaseMib));
        await using var connection = await OpenAsync(cancellationToken);
        if (retainRuns > 0)
        {
            await using var command = connection.CreateCommand();
            command.CommandText =
                """
                DELETE FROM telemetry_events
                WHERE component=$component AND run_index NOT IN(
                    SELECT DISTINCT run_index FROM telemetry_events
                    WHERE component=$component ORDER BY run_index DESC LIMIT $retain);
                """;
            command.Parameters.AddWithValue("$component", component);
            command.Parameters.AddWithValue("$retain", retainRuns);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }

        if (maxDatabaseMib > 0)
        {
            await TrimLogicalSizeAsync(
                connection,
                component,
                checked((long)maxDatabaseMib * 1024 * 1024),
                cancellationToken);
        }
    }

    private static async Task TrimLogicalSizeAsync(
        SqliteConnection connection,
        string component,
        long maximumBytes,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            await using var size = connection.CreateCommand();
            size.CommandText =
                "SELECT (SELECT page_size FROM pragma_page_size()) * "
                + "((SELECT page_count FROM pragma_page_count()) - "
                + "(SELECT freelist_count FROM pragma_freelist_count()));";
            var usedBytes = Convert.ToInt64(
                await size.ExecuteScalarAsync(cancellationToken),
                System.Globalization.CultureInfo.InvariantCulture);
            if (usedBytes <= maximumBytes) return;

            await using var delete = connection.CreateCommand();
            delete.CommandText =
                """
                DELETE FROM telemetry_events
                WHERE component=$component
                  AND run_index=(
                      SELECT MIN(run_index) FROM telemetry_events
                      WHERE component=$component)
                  AND (SELECT COUNT(DISTINCT run_index) FROM telemetry_events
                       WHERE component=$component) > 1;
                """;
            delete.Parameters.AddWithValue("$component", component);
            if (await delete.ExecuteNonQueryAsync(cancellationToken) == 0) return;
        }
    }

    private Task<SqliteConnection> OpenAsync(CancellationToken token) =>
        OpenConfiguredAsync(new SqliteConnection(connectionString), token);

    // Own the native handle until every configuration statement succeeds.
    // The caller cannot dispose a connection that was never returned.
    private static async Task<SqliteConnection> OpenConfiguredAsync(
        SqliteConnection connection, CancellationToken token)
    {
        try
        {
            await connection.OpenAsync(token);
            await using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA busy_timeout=1000; PRAGMA journal_mode=WAL;";
            await command.ExecuteNonQueryAsync(token);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private async Task MigrateVersionOneAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using (var version = connection.CreateCommand())
        {
            version.CommandText =
                "SELECT schema_version FROM process_telemetry_info WHERE singleton=1;";
            var current = Convert.ToInt32(
                await version.ExecuteScalarAsync(cancellationToken),
                System.Globalization.CultureInfo.InvariantCulture);
            if (current > 3)
                throw new InvalidDataException(
                    $"Unsupported process telemetry schema version {current}.");
        }
        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using (var read = connection.CreateCommand())
        {
            read.CommandText = "SELECT name FROM pragma_table_info('telemetry_events');";
            await using var reader = await read.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken)) columns.Add(reader.GetString(0));
        }

        foreach (var (name, definition) in new[]
        {
            ("scope_id", "TEXT NOT NULL DEFAULT ''"),
            ("event_sequence", "INTEGER NOT NULL DEFAULT 0"),
            ("elapsed_ticks", "INTEGER NOT NULL DEFAULT 0"),
            ("payload_version", "INTEGER NOT NULL DEFAULT 1"),
        })
        {
            if (columns.Contains(name)) continue;
            await using var alter = connection.CreateCommand();
            alter.CommandText = $"ALTER TABLE telemetry_events ADD COLUMN {name} {definition};";
            await alter.ExecuteNonQueryAsync(cancellationToken);
        }

        await using var normalize = connection.CreateCommand();
        normalize.CommandText =
            """
            UPDATE telemetry_events
            SET scope_id=CASE WHEN scope_id='' THEN component ELSE scope_id END;
            WITH numbered AS (
                SELECT event_id,
                       ROW_NUMBER() OVER(
                           PARTITION BY scope_id,component,run_index ORDER BY event_id) AS sequence
                FROM telemetry_events
            )
            UPDATE telemetry_events
            SET event_sequence=(SELECT sequence FROM numbered WHERE numbered.event_id=telemetry_events.event_id)
            WHERE event_sequence=0;
            CREATE UNIQUE INDEX IF NOT EXISTS ux_process_telemetry_identity
                ON telemetry_events(scope_id,run_index,component,event_sequence);
            CREATE INDEX IF NOT EXISTS ix_telemetry_component_run
                ON telemetry_events(component,run_index,event_id);
            UPDATE process_telemetry_info SET schema_version=3 WHERE singleton=1;
            """;
        await normalize.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task EnsureMetadataAsync(
        SqliteConnection connection,
        string component,
        CancellationToken cancellationToken)
    {
        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using (var read = connection.CreateCommand())
        {
            read.CommandText = "SELECT name FROM pragma_table_info('process_telemetry_info');";
            await using var reader = await read.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken)) columns.Add(reader.GetString(0));
        }
        foreach (var (name, definition) in new[]
        {
            ("telemetry_instance_id", "TEXT NULL"),
            ("producer", "TEXT NULL"),
            ("created_utc", "TEXT NULL"),
        })
        {
            if (columns.Contains(name)) continue;
            await using var alter = connection.CreateCommand();
            alter.CommandText = $"ALTER TABLE process_telemetry_info ADD COLUMN {name} {definition};";
            await alter.ExecuteNonQueryAsync(cancellationToken);
        }
        await using var update = connection.CreateCommand();
        update.CommandText =
            """
            UPDATE process_telemetry_info
            SET schema_version=3,
                telemetry_instance_id=COALESCE(telemetry_instance_id,$instance),
                producer=COALESCE(producer,$producer),
                created_utc=COALESCE(created_utc,$created)
            WHERE singleton=1;
            """;
        update.Parameters.AddWithValue("$instance", Guid.NewGuid().ToString("D"));
        update.Parameters.AddWithValue("$producer", component);
        update.Parameters.AddWithValue("$created", DateTimeOffset.UtcNow.ToString("O"));
        await update.ExecuteNonQueryAsync(cancellationToken);
    }
}

public sealed record ProcessTelemetryInfo(
    int SchemaVersion,
    Guid TelemetryInstanceId,
    string Producer,
    DateTimeOffset CreatedUtc);

public sealed record ProcessTelemetryEvent(
    long EventId,
    string ScopeId,
    string Component,
    long RunIndex,
    long EventSequence,
    string EventName,
    DateTimeOffset OccurredUtc,
    long ElapsedTicks,
    int PayloadVersion,
    string? PayloadJson);

public sealed record ProcessTelemetryWrite(
    string Name, string? PayloadJson, DateTimeOffset OccurredUtc, long Timestamp);

public static class BestEffortProcessTelemetry
{
    public static async Task TryRecordAsync(
        string identity,
        string component,
        long runIndex,
        string eventName,
        string? payloadJson = null,
        string? configurationPath = null,
        ProcessTelemetrySettings? effectiveSettings = null)
    {
        try
        {
            var settings = effectiveSettings ?? LoadSettings(
                identity, component, configurationPath);
            if (!settings.Enabled) return;
            var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, component);
            await store.RecordAsync(
                component,
                Math.Max(1, runIndex),
                eventName,
                payloadJson,
                cancellationToken: CancellationToken.None);
            await store.TrimAsync(
                component, settings.RetainRuns, settings.MaxDatabaseMib,
                CancellationToken.None);
        }
        catch (Exception)
        {
            // Telemetry is deliberately non-authoritative. Diagnostics must never
            // prevent or overturn the operation being observed.
        }
    }

    internal static ProcessTelemetrySettings LoadSettings(
        string identity,
        string component,
        string? configurationPath)
    {
        var configuration = ComponentConfiguration.Load(
            identity, component, configurationPath);
        var settings = TelemetryRuntimeOptions.Read(configuration);
        return new ProcessTelemetrySettings(settings.Enabled, settings.RetainRuns,
            settings.MaxDatabaseMib, settings.ProgressFlushIntervalMs, settings.HeartbeatIntervalMs);
    }
}

public sealed record ProcessTelemetrySettings(
    bool Enabled,
    int RetainRuns,
    int MaxDatabaseMib,
    int ProgressFlushIntervalMs = 100,
    int HeartbeatIntervalMs = 5000);

public sealed class ProcessTelemetryHeartbeat : IAsyncDisposable
{
    private readonly CancellationTokenSource cancellation = new();
    private readonly Task loop;

    private ProcessTelemetryHeartbeat(
        string identity,
        string component,
        long runIndex,
        string? configurationPath,
        TimeSpan interval)
    {
        loop = RunAsync(
            identity, component, runIndex, configurationPath, interval,
            cancellation.Token);
    }

    private ProcessTelemetryHeartbeat(ProcessTelemetrySession session, TimeSpan interval)
    {
        loop = RunSessionAsync(session, interval, cancellation.Token);
    }

    public static ProcessTelemetryHeartbeat Start(
        ProcessTelemetrySession session,
        TimeSpan? interval = null) =>
        new(session, interval ?? session.HeartbeatInterval);

    public static ProcessTelemetryHeartbeat Start(
        string identity,
        string component,
        long runIndex,
        string? configurationPath = null,
        TimeSpan? interval = null) =>
        new(
            identity,
            component,
            runIndex,
            configurationPath,
            interval ?? TimeSpan.FromMilliseconds(BestEffortProcessTelemetry.LoadSettings(
                identity, component, configurationPath).HeartbeatIntervalMs));

    public async ValueTask DisposeAsync()
    {
        cancellation.Cancel();
        try { await loop; }
        catch (OperationCanceledException) { }
        cancellation.Dispose();
    }

    private static async Task RunAsync(
        string identity,
        string component,
        long runIndex,
        string? configurationPath,
        TimeSpan interval,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            await Task.Delay(interval, cancellationToken);
            await BestEffortProcessTelemetry.TryRecordAsync(
                identity,
                component,
                runIndex,
                "operation.heartbeat",
                configurationPath: configurationPath);
        }
    }

    private static async Task RunSessionAsync(
        ProcessTelemetrySession session,
        TimeSpan interval,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            await Task.Delay(interval, cancellationToken);
            session.RecordEvent("operation.heartbeat");
        }
    }
}
