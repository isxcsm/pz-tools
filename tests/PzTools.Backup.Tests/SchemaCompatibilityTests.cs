using Microsoft.Data.Sqlite;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class SchemaCompatibilityTests
{
    [Fact]
    public async Task SchedulerDatabase_RejectsFutureSchemaWithoutDowngradingMarker()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("scheduler.db");
        await SchedulerDatabase.CreateOrOpenAsync(path);
        await SetVersionAsync(path, "scheduler_info", 999);

        await Assert.ThrowsAsync<InvalidDataException>(
            () => SchedulerDatabase.CreateOrOpenAsync(path));

        Assert.Equal(999, await ReadVersionAsync(path, "scheduler_info"));
    }

    [Fact]
    public async Task StateDatabase_RejectsFutureSchemaWithoutDowngradingMarker()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("state.db");
        await StateDatabase.CreateOrOpenAsync(path);
        await SetVersionAsync(path, "state_info", 999);

        await Assert.ThrowsAsync<InvalidDataException>(
            () => StateDatabase.CreateOrOpenAsync(path));

        Assert.Equal(999, await ReadVersionAsync(path, "state_info"));
    }

    private static async Task SetVersionAsync(string path, string table, int version)
    {
        await using var connection = await OpenAsync(path);
        await using var command = connection.CreateCommand();
        command.CommandText = $"UPDATE {table} SET schema_version=$version WHERE singleton=1;";
        command.Parameters.AddWithValue("$version", version);
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<int> ReadVersionAsync(string path, string table)
    {
        await using var connection = await OpenAsync(path);
        await using var command = connection.CreateCommand();
        command.CommandText = $"SELECT schema_version FROM {table} WHERE singleton=1;";
        return Convert.ToInt32(await command.ExecuteScalarAsync());
    }

    private static async Task<SqliteConnection> OpenAsync(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Pooling = false,
        }.ToString());
        await connection.OpenAsync();
        return connection;
    }
}
