using Microsoft.Data.Sqlite;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class TelemetryStoreTests
{
    [Fact]
    public async Task RawMode_PersistsEveryEventInSequence()
    {
        using var temp = new TempDirectory();
        var store = await TelemetryStore.CreateOrOpenAsync(temp.GetPath("repository"));
        var options = CreateOptions(TelemetryMode.Raw, batchSize: 2);
        await using var session = await store.BeginRunAsync(
            runIndex: 7,
            sourceId: 3,
            DateTimeOffset.UtcNow,
            options);

        Assert.True(await session.EmitAsync(new TelemetryEvent(TelemetryEventScope.Run, "run.start")));
        Assert.True(await session.EmitAsync(new TelemetryEvent(TelemetryEventScope.Phase, "scan.start")));
        Assert.True(await session.EmitAsync(new TelemetryEvent(
            TelemetryEventScope.Raw,
            "file.discovered",
            "{\"path\":\"a.bin\"}")));
        Assert.True(await session.CompleteAsync(RunStatus.Succeeded));

        var events = await store.ReadEventsAsync(7);
        Assert.Equal([1L, 2L, 3L], events.Select(item => item.Sequence));
        Assert.Equal(
            ["run.start", "scan.start", "file.discovered"],
            events.Select(item => item.Name));
        Assert.All(events, item => Assert.True(item.ElapsedTicks >= 0));
        Assert.Equal("Succeeded", (await store.ReadRunAsync(7))!.Status);
    }

    [Theory]
    [InlineData(TelemetryMode.Run, 1)]
    [InlineData(TelemetryMode.Phase, 2)]
    [InlineData(TelemetryMode.Raw, 3)]
    public async Task Mode_FiltersOnlyByScope(TelemetryMode mode, int expectedCount)
    {
        using var temp = new TempDirectory();
        var store = await TelemetryStore.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var session = await store.BeginRunAsync(
            1,
            1,
            DateTimeOffset.UtcNow,
            CreateOptions(mode));

        await session.EmitAsync(new TelemetryEvent(TelemetryEventScope.Run, "run"));
        await session.EmitAsync(new TelemetryEvent(TelemetryEventScope.Phase, "phase"));
        await session.EmitAsync(new TelemetryEvent(TelemetryEventScope.Raw, "raw"));
        await session.CompleteAsync(RunStatus.Succeeded);

        Assert.Equal(expectedCount, (await store.ReadEventsAsync(1)).Count);
    }

    [Theory]
    [InlineData(TelemetryMode.Run)]
    [InlineData(TelemetryMode.Phase)]
    [InlineData(TelemetryMode.Raw)]
    public async Task Heartbeat_IsRecordedAtEveryLevel(TelemetryMode mode)
    {
        using var temp = new TempDirectory();
        var store = await TelemetryStore.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var session = await store.BeginRunAsync(1, 1, DateTimeOffset.UtcNow, CreateOptions(mode));
        // A long phase with no progress (comparing every file of an imported save) is alive only by its heartbeat.
        await using (PzTools.Backup.Engine.TelemetryHeartbeat.Start(session, TimeSpan.FromMilliseconds(10)))
            await Task.Delay(200);
        await session.CompleteAsync(RunStatus.Succeeded);

        Assert.Contains(await store.ReadEventsAsync(1), item => item.Name == "operation.heartbeat");
    }

    [Fact]
    public async Task RecoverAbandonedRuns_RequiresWriterLeaseAndDoesNotRunOnOpen()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var store = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var session = await store.BeginRunAsync(
            1,
            1,
            DateTimeOffset.UtcNow,
            CreateOptions(TelemetryMode.Raw));

        _ = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        Assert.Equal("Running", (await store.ReadRunAsync(1))!.Status);

        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        await store.RecoverAbandonedRunsAsync(lease);
        Assert.Equal("Abandoned", (await store.ReadRunAsync(1))!.Status);
    }

    [Fact]
    public async Task WriterFailure_IsReportedWithoutEscapingCompletion()
    {
        using var temp = new TempDirectory();
        var store = await TelemetryStore.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var session = await store.BeginRunAsync(
            1,
            1,
            DateTimeOffset.UtcNow,
            CreateOptions(TelemetryMode.Raw, batchSize: 1));

        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = store.DatabasePath,
            Pooling = false,
        }.ToString();
        await using (var connection = new SqliteConnection(connectionString))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "DROP TABLE telemetry_events;";
            await command.ExecuteNonQueryAsync();
        }

        await session.EmitAsync(new TelemetryEvent(TelemetryEventScope.Raw, "will.fail"));
        var completed = await session.CompleteAsync(RunStatus.Succeeded);

        Assert.False(completed);
        Assert.NotNull(session.Failure);
    }

    [Fact]
    public async Task Trim_RetainsNewestConfiguredRuns()
    {
        using var temp = new TempDirectory();
        var store = await TelemetryStore.CreateOrOpenAsync(temp.GetPath("repository"));
        for (var runIndex = 1; runIndex <= 4; runIndex++)
        {
            await using var session = await store.BeginRunAsync(
                runIndex,
                1,
                DateTimeOffset.UtcNow,
                CreateOptions(TelemetryMode.Run));
            await session.EmitAsync(new TelemetryEvent(TelemetryEventScope.Run, "run"));
            await session.CompleteAsync(RunStatus.Succeeded);
        }

        await store.TrimAsync(retainRuns: 2, maxDatabaseMib: 0);

        Assert.Null(await store.ReadRunAsync(1));
        Assert.Null(await store.ReadRunAsync(2));
        Assert.NotNull(await store.ReadRunAsync(3));
        Assert.NotNull(await store.ReadRunAsync(4));
    }

    private static TelemetryOptions CreateOptions(
        TelemetryMode mode,
        int batchSize = 8)
    {
        return new TelemetryOptions(
            mode,
            batchSize,
            FlushIntervalMilliseconds: 10,
            RetainRuns: 0,
            MaxDatabaseMib: 0);
    }
}
