using System.Data;
using System.Reflection;
using Microsoft.Data.Sqlite;
using PzTools.Process.Telemetry;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class ConnectionOwnershipTests
{
    [Theory]
    [InlineData(typeof(SchedulerDatabase))]
    [InlineData(typeof(StateDatabase))]
    [InlineData(typeof(ProcessTelemetryStore))]
    public async Task CancellationAfterNativeOpen_ReleasesConnectionWithoutGarbageCollection(Type owner)
    {
        using var temp = new TempDirectory();
        using var cancellation = new CancellationTokenSource();
        var path = temp.GetPath("cancel.db");
        var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        var opened = false;
        connection.StateChange += (_, change) =>
        {
            if (change.CurrentState != ConnectionState.Open) return;
            opened = true;
            cancellation.Cancel();
        };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => OpenConfiguredAsync(owner, connection, cancellation.Token));
        Assert.True(opened);
        Assert.Equal(ConnectionState.Closed, connection.State);
        // Keep the managed connection reachable. A finalizer must not be needed to unlock it.
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
        GC.KeepAlive(connection);
    }

    [Theory]
    [InlineData(typeof(SchedulerDatabase))]
    [InlineData(typeof(StateDatabase))]
    [InlineData(typeof(ProcessTelemetryStore))]
    public async Task ConfigurationFailure_ReleasesConnectionAndRollsBack(Type owner)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("failure.db");
        var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        connection.StateChange += (_, change) =>
        {
            if (change.CurrentState != ConnectionState.Open) return;
            using var command = connection.CreateCommand();
            // SQLite cannot switch to WAL during a transaction. Fail after opening,
            // not before acquiring a native database handle.
            command.CommandText = "BEGIN IMMEDIATE; CREATE TABLE rollback_me(value INTEGER);";
            command.ExecuteNonQuery();
        };
        await Assert.ThrowsAsync<SqliteException>(() => OpenConfiguredAsync(owner, connection, default));
        Assert.Equal(ConnectionState.Closed, connection.State);
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
        await using var check = new SqliteConnection($"Data Source={path};Pooling=False");
        await check.OpenAsync();
        await using var query = check.CreateCommand();
        query.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name='rollback_me';";
        Assert.Equal(0L, await query.ExecuteScalarAsync());
        GC.KeepAlive(connection);
    }

    [Theory]
    [InlineData(typeof(SchedulerDatabase))]
    [InlineData(typeof(StateDatabase))]
    [InlineData(typeof(ProcessTelemetryStore))]
    public async Task SuccessfulConfiguration_TransfersOpenConnectionToCaller(Type owner)
    {
        using var temp = new TempDirectory();
        var connection = new SqliteConnection($"Data Source={temp.GetPath("success.db")};Pooling=False");
        await using var opened = await OpenConfiguredAsync(owner, connection, default);
        Assert.Same(connection, opened);
        Assert.Equal(ConnectionState.Open, opened.State);
        await using var command = opened.CreateCommand();
        command.CommandText = "PRAGMA journal_mode;";
        Assert.Equal("wal", await command.ExecuteScalarAsync());
    }

    private static Task<SqliteConnection> OpenConfiguredAsync(
        Type owner, SqliteConnection connection, CancellationToken token)
    {
        // Exercise the exact ownership boundary without a public test-only API.
        var method = owner.GetMethod("OpenConfiguredAsync", BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new InvalidOperationException($"Missing connection setup boundary for {owner.Name}.");
        return (Task<SqliteConnection>)method.Invoke(null, [connection, token])!;
    }
}
