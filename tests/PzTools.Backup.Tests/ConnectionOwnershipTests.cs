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
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
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
        // Check before the test's own disposal. A finalizer must not be needed to unlock it.
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
        GC.KeepAlive(connection);
    }

    [Theory]
    [InlineData(typeof(SchedulerDatabase))]
    [InlineData(typeof(StateDatabase))]
    [InlineData(typeof(ProcessTelemetryStore))]
    public async Task ConfigurationFailure_ReleasesConnectionWithoutChangingDatabase(Type owner)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("failure.db");
        await using (var seed = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            await seed.OpenAsync();
            await using var command = seed.CreateCommand();
            command.CommandText = "PRAGMA journal_mode=DELETE; CREATE TABLE durable(value INTEGER); INSERT INTO durable VALUES(42);";
            await command.ExecuteNonQueryAsync();
        }
        // Native open succeeds, but switching this read-only database to WAL fails.
        // Do not inject a raw BEGIN: the provider is not required to track that transaction.
        await using var connection = new SqliteConnection($"Data Source={path};Mode=ReadOnly;Pooling=False");
        var opened = false;
        connection.StateChange += (_, change) => opened |= change.CurrentState == ConnectionState.Open;
        var error = await Assert.ThrowsAsync<SqliteException>(
            () => OpenConfiguredAsync(owner, connection, default));
        Assert.True(opened);
        Assert.Equal(8, error.SqliteErrorCode);
        Assert.Equal(ConnectionState.Closed, connection.State);
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
        await using var check = new SqliteConnection($"Data Source={path};Pooling=False");
        await check.OpenAsync();
        await using var query = check.CreateCommand();
        query.CommandText = "SELECT value FROM durable;";
        Assert.Equal(42L, await query.ExecuteScalarAsync());
        GC.KeepAlive(connection);
    }

    [Theory]
    [InlineData(typeof(SchedulerDatabase))]
    [InlineData(typeof(StateDatabase))]
    [InlineData(typeof(ProcessTelemetryStore))]
    public async Task SuccessfulConfiguration_TransfersOpenConnectionToCaller(Type owner)
    {
        using var temp = new TempDirectory();
        await using var connection = new SqliteConnection($"Data Source={temp.GetPath("success.db")};Pooling=False");
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
