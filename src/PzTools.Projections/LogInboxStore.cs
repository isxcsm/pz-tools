using System.Globalization;
using Microsoft.Data.Sqlite;

namespace PzTools.Projections;

public sealed record LogPageQuery(LogLevel MinimumLevel, string ComponentCategory,
    string RunText, int PageIndex, int PageSize = 100, long SnapshotMaxLogIndex = 0);

public sealed record LogPageResult(IReadOnlyList<LogEntryView> Entries,
    int TotalGroups, long SnapshotMaxLogIndex);

/// <summary>
/// The durable log index. Telemetry entry keys make replay idempotent;
/// acknowledgment is stored per issue, while the badge is derived from these rows.
/// </summary>
public sealed class LogInboxStore
{
    private static string FilteredLogsSql(string extraPredicate = "1=1") => $$"""
        WITH filtered AS (
            SELECT logs.*, COALESCE(ack.acknowledged_through,0) AS acknowledged_through,
                   ack.acknowledged_at_utc,
                   CASE WHEN logs.level >= 2 AND logs.incident_key IS NOT NULL
                        THEN 'incident:' || logs.incident_key
                        ELSE 'entry:' || logs.entry_key END AS group_key
            FROM log_entries AS logs
            LEFT JOIN log_acknowledgments AS ack ON ack.incident_key=logs.incident_key
            WHERE ({{extraPredicate}}) AND logs.log_index <= $snapshot
              AND logs.level >= $minimum
              AND ($run='' OR instr(CAST(logs.run_index AS TEXT),$run)>0)
              AND ($category='All' OR (CASE
                    WHEN logs.component='backup-worker' THEN 'Backup'
                    WHEN logs.component='restore-worker' OR logs.component LIKE 'restore-%' THEN 'Restore'
                    WHEN logs.component='archive-worker' OR logs.component LIKE 'archive-%' THEN 'Archive'
                    WHEN logs.component IN ('state-runner','state-collector','state-reactor','state-scheduler') THEN 'State'
                    WHEN logs.component='backup-scheduler' THEN 'Schedule'
                    WHEN logs.component='maintenance-worker' OR logs.component LIKE 'maintenance-lane-%' THEN 'Maintenance'
                    ELSE 'Other' END)=$category)
        )
        """;
    private sealed record PageIndex(LogLevel Level, string Category, string RunText,
        long Snapshot, IReadOnlyList<string> GroupKeys);
    private readonly string connectionString;
    private readonly SemaphoreSlim gate = new(1, 1);
    private LogsView? cachedView;
    private LogProjectionOptions? cachedOptions;
    private PageIndex? cachedPageIndex;
    private LogLevel minimumStoredLevel = LogLevel.Information;
    private int maxEntries = 100000;

    private LogInboxStore(string databasePath)
    {
        DatabasePath = Path.GetFullPath(databasePath);
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString();
    }

    public string DatabasePath { get; }

    public async Task ConfigureStorageAsync(LogLevel minimumLevel, int maximumEntries,
        CancellationToken cancellationToken = default)
    {
        if (!Enum.IsDefined(minimumLevel)) throw new ArgumentOutOfRangeException(nameof(minimumLevel));
        if (maximumEntries is < 10000 or > 500000)
            throw new ArgumentOutOfRangeException(nameof(maximumEntries));
        await gate.WaitAsync(cancellationToken);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            using var transaction = connection.BeginTransaction();
            var changed = await TrimAsync(connection, transaction, maximumEntries, cancellationToken);
            transaction.Commit();
            minimumStoredLevel = minimumLevel;
            maxEntries = maximumEntries;
            if (changed)
            {
                cachedView = null;
                cachedPageIndex = null;
            }
        }
        finally { gate.Release(); }
    }

    public static async Task<LogInboxStore> CreateOrOpenAsync(
        string databasePath, CancellationToken cancellationToken = default)
    {
        var store = new LogInboxStore(databasePath);
        Directory.CreateDirectory(Path.GetDirectoryName(store.DatabasePath)!);
        await using var connection = await store.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS log_entries(
                log_index INTEGER PRIMARY KEY AUTOINCREMENT,
                entry_key TEXT NOT NULL UNIQUE,
                source_id TEXT NOT NULL,
                telemetry_instance_id TEXT NOT NULL,
                event_id INTEGER NOT NULL,
                occurred_utc TEXT NOT NULL,
                level INTEGER NOT NULL,
                component TEXT NOT NULL,
                run_index INTEGER NOT NULL,
                event_name TEXT NOT NULL,
                payload_json TEXT NULL,
                incident_key TEXT NULL
            ) STRICT;
            CREATE INDEX IF NOT EXISTS ix_log_entries_level_index
                ON log_entries(level, log_index DESC);
            CREATE INDEX IF NOT EXISTS ix_log_entries_occurred_index
                ON log_entries(occurred_utc DESC, log_index DESC);
            CREATE INDEX IF NOT EXISTS ix_log_entries_incident_index
                ON log_entries(incident_key, log_index DESC);
            CREATE TABLE IF NOT EXISTS log_acknowledgments(
                incident_key TEXT PRIMARY KEY,
                acknowledged_through INTEGER NOT NULL,
                acknowledged_at_utc TEXT NULL
            ) STRICT;
            CREATE TABLE IF NOT EXISTS imported_log_sources(
                source_id TEXT PRIMARY KEY
            ) STRICT;
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
        await using var columns = connection.CreateCommand();
        columns.CommandText = "PRAGMA table_info(log_acknowledgments);";
        await using var reader = await columns.ExecuteReaderAsync(cancellationToken);
        var hasAcknowledgedAt = false;
        while (await reader.ReadAsync(cancellationToken))
            hasAcknowledgedAt |= StringComparer.Ordinal.Equals(
                reader.GetString(1), "acknowledged_at_utc");
        await reader.DisposeAsync();
        if (!hasAcknowledgedAt)
        {
            await using var migration = connection.CreateCommand();
            migration.CommandText =
                "ALTER TABLE log_acknowledgments ADD COLUMN acknowledged_at_utc TEXT NULL;";
            await migration.ExecuteNonQueryAsync(cancellationToken);
        }
        await using var backfill = connection.CreateCommand();
        backfill.CommandText =
            """
            UPDATE log_acknowledgments
            SET acknowledged_at_utc = (
                SELECT occurred_utc FROM log_entries
                WHERE log_index = log_acknowledgments.acknowledged_through)
            WHERE acknowledged_at_utc IS NULL;
            """;
        await backfill.ExecuteNonQueryAsync(cancellationToken);
        return store;
    }

    public async Task AppendAsync(
        IReadOnlyCollection<LogEntryView> entries, CancellationToken cancellationToken = default)
    {
        if (entries.Count == 0) return;
        await gate.WaitAsync(cancellationToken);
        try
        {
            var candidates = entries.Where(entry => entry.Level >= minimumStoredLevel)
                .OrderBy(item => item.OccurredUtc).ThenBy(item => item.EventId).ToArray();
            if (candidates.Length == 0) return;
            await using var connection = await OpenAsync(cancellationToken);
            using var transaction = connection.BeginTransaction();
            var changed = false;
            var existingKeys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var batch in candidates.Chunk(500))
            {
                await using var lookup = connection.CreateCommand();
                lookup.Transaction = transaction;
                var names = batch.Select((_, index) => $"$key{index}").ToArray();
                lookup.CommandText = "SELECT entry_key FROM log_entries WHERE entry_key IN ("
                    + string.Join(',', names) + ");";
                for (var index = 0; index < batch.Length; index++)
                    lookup.Parameters.AddWithValue(names[index], batch[index].EntryId);
                await using var reader = await lookup.ExecuteReaderAsync(cancellationToken);
                while (await reader.ReadAsync(cancellationToken))
                    existingKeys.Add(reader.GetString(0));
            }
            foreach (var entry in candidates)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var existing = existingKeys.Contains(entry.EntryId);
                if (existing && (entry.EventName != "run.failed"
                    || LogDiagnostics.Parse(entry.PayloadJson)?.Path is null)) continue;
                var inserted = false;
                if (!existing)
                {
                    await using var command = connection.CreateCommand();
                    command.Transaction = transaction;
                    command.CommandText =
                        """
                        INSERT INTO log_entries(
                            entry_key,source_id,telemetry_instance_id,event_id,occurred_utc,
                            level,component,run_index,event_name,payload_json,incident_key)
                        VALUES($key,$source,$instance,$event,$occurred,$level,$component,
                               $run,$name,$payload,$incident)
                        ON CONFLICT(entry_key) DO NOTHING;
                        """;
                    command.Parameters.AddWithValue("$key", entry.EntryId);
                    command.Parameters.AddWithValue("$source", entry.SourceId);
                    command.Parameters.AddWithValue("$instance", entry.TelemetryInstanceId.ToString("D"));
                    command.Parameters.AddWithValue("$event", entry.EventId);
                    command.Parameters.AddWithValue("$occurred", entry.OccurredUtc.ToUniversalTime()
                        .ToString("O", CultureInfo.InvariantCulture));
                    command.Parameters.AddWithValue("$level", (int)entry.Level);
                    command.Parameters.AddWithValue("$component", entry.Component);
                    command.Parameters.AddWithValue("$run", entry.RunIndex);
                    command.Parameters.AddWithValue("$name", entry.EventName);
                    command.Parameters.AddWithValue("$payload", (object?)entry.PayloadJson ?? DBNull.Value);
                    command.Parameters.AddWithValue("$incident", (object?)IncidentKey(entry) ?? DBNull.Value);
                    inserted = await command.ExecuteNonQueryAsync(cancellationToken) > 0;
                    changed |= inserted;
                }
                if (inserted || entry.EventName != "run.failed"
                    || LogDiagnostics.Parse(entry.PayloadJson)?.Path is null) continue;
                await using var previous = connection.CreateCommand();
                previous.Transaction = transaction;
                previous.CommandText = "SELECT payload_json FROM log_entries WHERE entry_key=$key;";
                previous.Parameters.AddWithValue("$key", entry.EntryId);
                var oldPayload = await previous.ExecuteScalarAsync(cancellationToken) as string;
                if (LogDiagnostics.Parse(oldPayload)?.Path is not null) continue;
                await using var update = connection.CreateCommand();
                update.Transaction = transaction;
                update.CommandText =
                    "UPDATE log_entries SET payload_json=$payload WHERE entry_key=$key;";
                update.Parameters.AddWithValue("$key", entry.EntryId);
                update.Parameters.AddWithValue("$payload", entry.PayloadJson!);
                changed |= await update.ExecuteNonQueryAsync(cancellationToken) > 0;
            }
            var trimmed = changed
                && await TrimAsync(connection, transaction, maxEntries, cancellationToken);
            transaction.Commit();
            if (changed)
            {
                cachedView = null;
                if (trimmed) cachedPageIndex = null;
            }
        }
        finally { gate.Release(); }
    }

    private static async Task<bool> TrimAsync(SqliteConnection connection,
        SqliteTransaction transaction, int maximumEntries, CancellationToken cancellationToken)
    {
        await using var count = connection.CreateCommand();
        count.Transaction = transaction;
        count.CommandText = "SELECT COUNT(*) FROM log_entries;";
        var total = Convert.ToInt32(await count.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
        var excess = total - maximumEntries;
        var changed = false;
        if (excess > 0)
        {
            await using var delete = connection.CreateCommand();
            delete.Transaction = transaction;
            delete.CommandText = """
                DELETE FROM log_entries WHERE log_index IN (
                    SELECT log_index FROM log_entries
                    ORDER BY occurred_utc, log_index LIMIT $remove);
                """;
            delete.Parameters.AddWithValue("$remove", excess);
            changed = await delete.ExecuteNonQueryAsync(cancellationToken) > 0;
        }
        if (changed || total == 0)
        {
            await using var orphan = connection.CreateCommand();
            orphan.Transaction = transaction;
            orphan.CommandText = """
                DELETE FROM log_acknowledgments
                WHERE NOT EXISTS (SELECT 1 FROM log_entries
                    WHERE log_entries.incident_key = log_acknowledgments.incident_key);
                """;
            await orphan.ExecuteNonQueryAsync(cancellationToken);
        }
        return changed;
    }

    public async Task<LogsView> ReadViewAsync(
        LogProjectionOptions options, CancellationToken cancellationToken = default)
    {
        options.Validate();
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (cachedView is not null && cachedOptions == options) return cachedView;
            await using var connection = await OpenAsync(cancellationToken);
            await using var count = connection.CreateCommand();
            count.CommandText =
                """
                SELECT COUNT(DISTINCT logs.incident_key)
                FROM log_entries AS logs
                LEFT JOIN log_acknowledgments AS ack
                    ON ack.incident_key = logs.incident_key
                WHERE logs.level >= $warning AND logs.incident_key IS NOT NULL
                  AND (ack.incident_key IS NULL
                    OR (logs.log_index > ack.acknowledged_through
                      AND (ack.acknowledged_at_utc IS NULL
                        OR logs.occurred_utc > ack.acknowledged_at_utc)));
                """;
            count.Parameters.AddWithValue("$warning", (int)LogLevel.Warning);
            var unread = Convert.ToInt32(await count.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);

            await using var command = connection.CreateCommand();
            command.CommandText =
                """
                SELECT logs.log_index,logs.entry_key,logs.source_id,
                       logs.telemetry_instance_id,logs.event_id,logs.occurred_utc,
                       logs.level,logs.component,logs.run_index,logs.event_name,
                       logs.payload_json,logs.incident_key,
                       COALESCE(ack.acknowledged_through, 0),ack.acknowledged_at_utc
                FROM log_entries AS logs
                LEFT JOIN log_acknowledgments AS ack
                    ON ack.incident_key = logs.incident_key
                WHERE logs.level >= $minimum
                ORDER BY logs.occurred_utc DESC, logs.log_index DESC
                LIMIT $limit;
                """;
            command.Parameters.AddWithValue("$minimum", (int)options.MinimumLevel);
            command.Parameters.AddWithValue("$limit", options.DisplayLimit);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var entries = new List<LogEntryView>();
            while (await reader.ReadAsync(cancellationToken))
            {
                var logIndex = reader.GetInt64(0);
                var level = (LogLevel)reader.GetInt32(6);
                var incident = reader.IsDBNull(11) ? null : reader.GetString(11);
                var occurred = DateTimeOffset.Parse(reader.GetString(5), CultureInfo.InvariantCulture);
                DateTimeOffset? acknowledgedAt = reader.IsDBNull(13) ? null
                    : DateTimeOffset.Parse(reader.GetString(13), CultureInfo.InvariantCulture);
                entries.Add(new LogEntryView(
                    reader.GetString(1), reader.GetString(2), Guid.Parse(reader.GetString(3)),
                    reader.GetInt64(4), occurred,
                    level, reader.GetString(7), reader.GetInt64(8), reader.GetString(9),
                    reader.IsDBNull(10) ? null : reader.GetString(10),
                    logIndex, incident,
                    level < LogLevel.Warning || logIndex <= reader.GetInt64(12)
                        || acknowledgedAt is { } cutoff && occurred <= cutoff));
            }
            cachedOptions = options;
            cachedView = new LogsView(entries, unread);
            return cachedView;
        }
        finally { gate.Release(); }
    }

    public async Task<LogPageResult> ReadPageAsync(LogPageQuery query,
        CancellationToken cancellationToken = default)
    {
        if (!Enum.IsDefined(query.MinimumLevel)) throw new ArgumentOutOfRangeException(nameof(query));
        if (query.PageIndex < 0 || query.PageSize is < 1 or > 500)
            throw new ArgumentOutOfRangeException(nameof(query));
        await gate.WaitAsync(cancellationToken);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            var snapshot = query.SnapshotMaxLogIndex;
            if (snapshot <= 0)
            {
                await using var latest = connection.CreateCommand();
                latest.CommandText = "SELECT COALESCE(MAX(log_index),0) FROM log_entries;";
                snapshot = Convert.ToInt64(await latest.ExecuteScalarAsync(cancellationToken),
                    CultureInfo.InvariantCulture);
            }
            var pageIndex = cachedPageIndex;
            if (pageIndex is null || pageIndex.Level != query.MinimumLevel
                || pageIndex.Category != query.ComponentCategory
                || pageIndex.RunText != query.RunText || pageIndex.Snapshot != snapshot)
            {
                await using var indexCommand = connection.CreateCommand();
                indexCommand.CommandText = FilteredLogsSql() + """
                    SELECT group_key FROM filtered GROUP BY group_key
                    ORDER BY MAX(log_index) DESC;
                    """;
                AddPageParameters(indexCommand, query, snapshot);
                var keys = new List<string>();
                await using var indexReader = await indexCommand.ExecuteReaderAsync(cancellationToken);
                while (await indexReader.ReadAsync(cancellationToken))
                    keys.Add(indexReader.GetString(0));
                pageIndex = new PageIndex(query.MinimumLevel, query.ComponentCategory,
                    query.RunText, snapshot, keys);
                cachedPageIndex = pageIndex;
            }
            var total = pageIndex.GroupKeys.Count;
            var pageKeys = pageIndex.GroupKeys.Skip(checked(query.PageIndex * query.PageSize))
                .Take(query.PageSize).ToArray();
            if (pageKeys.Length == 0) return new LogPageResult([], total, snapshot);
            var incidents = pageKeys.Where(key => key.StartsWith("incident:", StringComparison.Ordinal))
                .Select(key => key["incident:".Length..]).ToArray();
            var singles = pageKeys.Where(key => key.StartsWith("entry:", StringComparison.Ordinal))
                .Select(key => key["entry:".Length..]).ToArray();
            var predicates = new List<string>();
            if (incidents.Length > 0)
                predicates.Add("(logs.level >= 2 AND logs.incident_key IN ("
                    + string.Join(',', incidents.Select((_, i) => $"$incident{i}")) + "))");
            if (singles.Length > 0)
                predicates.Add("logs.entry_key IN ("
                    + string.Join(',', singles.Select((_, i) => $"$entry{i}")) + ")");
            await using var command = connection.CreateCommand();
            command.CommandText = FilteredLogsSql(string.Join(" OR ", predicates)) + """
                SELECT f.log_index,f.entry_key,f.source_id,f.telemetry_instance_id,
                       f.event_id,f.occurred_utc,f.level,f.component,f.run_index,
                       f.event_name,f.payload_json,f.incident_key,
                       f.acknowledged_through,f.acknowledged_at_utc
                FROM filtered AS f;
                """;
            AddPageParameters(command, query, snapshot);
            for (var i = 0; i < incidents.Length; i++)
                command.Parameters.AddWithValue($"$incident{i}", incidents[i]);
            for (var i = 0; i < singles.Length; i++)
                command.Parameters.AddWithValue($"$entry{i}", singles[i]);
            var entries = new List<LogEntryView>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                var level = (LogLevel)reader.GetInt32(6);
                var index = reader.GetInt64(0);
                var occurred = DateTimeOffset.Parse(reader.GetString(5), CultureInfo.InvariantCulture);
                DateTimeOffset? acknowledgedAt = reader.IsDBNull(13) ? null
                    : DateTimeOffset.Parse(reader.GetString(13), CultureInfo.InvariantCulture);
                entries.Add(new LogEntryView(reader.GetString(1), reader.GetString(2),
                    Guid.Parse(reader.GetString(3)), reader.GetInt64(4), occurred,
                    level, reader.GetString(7), reader.GetInt64(8), reader.GetString(9),
                    reader.IsDBNull(10) ? null : reader.GetString(10), index,
                    reader.IsDBNull(11) ? null : reader.GetString(11),
                    level < LogLevel.Warning || index <= reader.GetInt64(12)
                        || acknowledgedAt is { } cutoff && occurred <= cutoff));
            }
            var positions = pageKeys.Select((key, position) => (key, position))
                .ToDictionary(item => item.key, item => item.position, StringComparer.Ordinal);
            return new LogPageResult(entries.OrderBy(item => positions[
                    item.Level >= LogLevel.Warning && item.IncidentKey is not null
                        ? $"incident:{item.IncidentKey}" : $"entry:{item.EntryId}"])
                .ThenByDescending(item => item.OccurredUtc)
                .ThenByDescending(item => item.LogIndex).ToArray(), total, snapshot);
        }
        finally { gate.Release(); }
    }

    private static void AddPageParameters(SqliteCommand command, LogPageQuery query, long snapshot)
    {
        command.Parameters.AddWithValue("$snapshot", snapshot);
        command.Parameters.AddWithValue("$minimum", (int)query.MinimumLevel);
        command.Parameters.AddWithValue("$category", query.ComponentCategory);
        command.Parameters.AddWithValue("$run", query.RunText);
    }

    public async Task AcknowledgeIssueAsync(
        string incidentKey, long throughLogIndex, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(incidentKey);
        if (throughLogIndex <= 0) throw new ArgumentOutOfRangeException(nameof(throughLogIndex));
        await gate.WaitAsync(cancellationToken);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText =
                """
                INSERT INTO log_acknowledgments(
                    incident_key,acknowledged_through,acknowledged_at_utc)
                SELECT incident_key, MAX(log_index),$now
                FROM log_entries
                WHERE incident_key = $incident AND level >= $warning AND log_index <= $through
                HAVING COUNT(*) > 0
                ON CONFLICT(incident_key) DO UPDATE SET
                    acknowledged_through = MAX(acknowledged_through,excluded.acknowledged_through),
                    acknowledged_at_utc = CASE
                        WHEN acknowledged_at_utc IS NULL
                          OR acknowledged_at_utc < excluded.acknowledged_at_utc
                        THEN excluded.acknowledged_at_utc
                        ELSE acknowledged_at_utc END;
                """;
            command.Parameters.AddWithValue("$incident", incidentKey);
            command.Parameters.AddWithValue("$warning", (int)LogLevel.Warning);
            command.Parameters.AddWithValue("$through", throughLogIndex);
            command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture));
            if (await command.ExecuteNonQueryAsync(cancellationToken) > 0)
                cachedView = null;
        }
        finally { gate.Release(); }
    }

    public async Task AcknowledgeAllAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText =
                """
                INSERT INTO log_acknowledgments(
                    incident_key,acknowledged_through,acknowledged_at_utc)
                SELECT incident_key,MAX(log_index),$now
                FROM log_entries
                WHERE level >= $warning AND incident_key IS NOT NULL
                GROUP BY incident_key
                ON CONFLICT(incident_key) DO UPDATE SET
                    acknowledged_through = MAX(acknowledged_through,excluded.acknowledged_through),
                    acknowledged_at_utc = CASE
                        WHEN acknowledged_at_utc IS NULL
                          OR acknowledged_at_utc < excluded.acknowledged_at_utc
                        THEN excluded.acknowledged_at_utc
                        ELSE acknowledged_at_utc END;
                """;
            command.Parameters.AddWithValue("$warning", (int)LogLevel.Warning);
            command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture));
            if (await command.ExecuteNonQueryAsync(cancellationToken) > 0)
                cachedView = null;
        }
        finally { gate.Release(); }
    }

    public async Task<IReadOnlySet<string>> ReadImportedSourcesAsync(
        CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT source_id FROM imported_log_sources;";
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            var sources = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            while (await reader.ReadAsync(cancellationToken)) sources.Add(reader.GetString(0));
            return sources;
        }
        finally { gate.Release(); }
    }

    public async Task MarkSourceImportedAsync(
        string sourceId, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceId);
        await gate.WaitAsync(cancellationToken);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText =
                "INSERT INTO imported_log_sources(source_id) VALUES($source) ON CONFLICT DO NOTHING;";
            command.Parameters.AddWithValue("$source", sourceId);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        finally { gate.Release(); }
    }

    public async Task ForgetImportedSourceAsync(string sourceId, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            await using var connection = await OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM imported_log_sources WHERE source_id=$source;";
            command.Parameters.AddWithValue("$source", sourceId);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        finally { gate.Release(); }
    }

    private async Task<SqliteConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqliteConnection(connectionString);
        try
        {
            await connection.OpenAsync(cancellationToken);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private static string? IncidentKey(LogEntryView entry) => entry.Level < LogLevel.Warning
        ? null
        : entry.RunIndex > 0
            ? $"run:{entry.RunIndex}"
            : $"source:{entry.SourceId}:{entry.EventName}";
}
