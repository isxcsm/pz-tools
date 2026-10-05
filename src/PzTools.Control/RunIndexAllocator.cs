using System.Globalization;
using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts;

namespace PzTools.Control;

/// <summary>Hands out the run_index shared by every process of one installation, atomically.</summary>
public sealed class RunIndexAllocator
{
    public const int CurrentSchemaVersion = 1;
    private readonly string connectionString;

    public RunIndexAllocator(string? databasePath = null)
    {
        DatabasePath = Path.GetFullPath(
            databasePath ?? PzToolsPathLayout.CreateDefault().ControlDatabasePath);
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
            Pooling = false,
        }.ToString();
    }

    public string DatabasePath { get; }

    public async Task<long> AllocateAsync(
        long minimumExclusive = 0,
        CancellationToken cancellationToken = default)
    {
        if (minimumExclusive < 0) throw new ArgumentOutOfRangeException(nameof(minimumExclusive));
        Directory.CreateDirectory(Path.GetDirectoryName(DatabasePath)!);
        await using var connection = new SqliteConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using (var configure = connection.CreateCommand())
        {
            configure.CommandText =
                "PRAGMA busy_timeout=10000; PRAGMA synchronous=FULL;";
            await configure.ExecuteNonQueryAsync(cancellationToken);
        }

        using var transaction = connection.BeginTransaction(deferred: false);
        await EnsureSchemaAsync(connection, transaction, cancellationToken);
        var timeFloor = checked(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 65_536L);
        await using var allocate = connection.CreateCommand();
        allocate.Transaction = transaction;
        allocate.CommandText =
            """
            UPDATE run_sequence
            SET last_value = MAX(last_value + 1, $timeFloor, $minimum)
            WHERE singleton = 1
            RETURNING last_value;
            """;
        allocate.Parameters.AddWithValue("$timeFloor", timeFloor);
        allocate.Parameters.AddWithValue("$minimum", checked(minimumExclusive + 1));
        var value = Convert.ToInt64(
            await allocate.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture);
        transaction.Commit();
        return value;
    }

    private static async Task EnsureSchemaAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using var detect = connection.CreateCommand();
        detect.Transaction = transaction;
        detect.CommandText =
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='control_info';";
        if (await detect.ExecuteScalarAsync(cancellationToken) is not null)
        {
            await using var version = connection.CreateCommand();
            version.Transaction = transaction;
            version.CommandText = "SELECT schema_version FROM control_info WHERE singleton=1;";
            var rawVersion = await version.ExecuteScalarAsync(cancellationToken)
                ?? throw new InvalidDataException("control.db has no metadata.");
            var stored = Convert.ToInt32(rawVersion, CultureInfo.InvariantCulture);
            if (stored > CurrentSchemaVersion)
                throw new InvalidDataException($"control.db schema version {stored} is not supported.");
            if (stored != CurrentSchemaVersion)
                throw new InvalidDataException($"control.db schema version {stored} cannot be migrated.");
            await using var sequence = connection.CreateCommand();
            sequence.Transaction = transaction;
            sequence.CommandText = "SELECT 1 FROM run_sequence WHERE singleton=1;";
            if (await sequence.ExecuteScalarAsync(cancellationToken) is null)
                throw new InvalidDataException("control.db has no run number sequence.");
            return;
        }

        await using var create = connection.CreateCommand();
        create.Transaction = transaction;
        create.CommandText =
            """
            CREATE TABLE control_info(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                schema_version INTEGER NOT NULL,
                installation_id TEXT NOT NULL,
                created_utc TEXT NOT NULL);
            CREATE TABLE run_sequence(
                singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                last_value INTEGER NOT NULL CHECK(last_value>=0));
            INSERT INTO control_info(singleton,schema_version,installation_id,created_utc)
            VALUES(1,$version,$installationId,$createdUtc);
            INSERT INTO run_sequence(singleton,last_value) VALUES(1,0);
            """;
        create.Parameters.AddWithValue("$version", CurrentSchemaVersion);
        create.Parameters.AddWithValue("$installationId", Guid.NewGuid().ToString("D"));
        create.Parameters.AddWithValue("$createdUtc", DateTimeOffset.UtcNow.ToString("O"));
        await create.ExecuteNonQueryAsync(cancellationToken);
    }
}
