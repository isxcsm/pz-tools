using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Projections;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class GameplayBackgroundTests
{
    [Fact]
    public async Task OrphanDispatchDuringPlay_DoesNotStartWorkerOrCreateControlDatabase()
    {
        using var temp = new TempDirectory();
        var control = temp.GetPath("control.db");
        var dispatcher = new OrphanCleanupDispatcher(temp.GetPath("repo"), temp.GetPath("saves"),
            temp.GetPath("missing-workers"), control, shouldDefer: () => true);
        await dispatcher.TickAsync(DateTimeOffset.UtcNow);
        await dispatcher.TickAsync(DateTimeOffset.UtcNow.AddHours(1));
        Assert.False(File.Exists(control)); // A launch attempt would allocate a failure run here.
        Assert.False(Directory.Exists(temp.GetPath("repo")));
    }

    [Fact]
    public async Task OrphanDispatch_RunsAtOnceWhenTheGameExits_InsteadOfWaitingOutTheInterval()
    {
        using var temp = new TempDirectory();
        var playing = true;
        var launches = new List<IReadOnlyList<string>>();
        var dispatcher = new OrphanCleanupDispatcher(temp.GetPath("repo"), temp.GetPath("saves"),
            temp.GetPath("workers"), shouldDefer: () => playing,
            startDetached: (_, arguments, _) => launches.Add(arguments));
        var now = DateTimeOffset.UtcNow;

        await dispatcher.TickAsync(now);                 // Deferred during play; the interval restarts.
        playing = false;
        await dispatcher.TickAsync(now.AddSeconds(5));   // Still inside the interval.
        Assert.Empty(launches);

        dispatcher.RequestNow();                         // The game-exit signal.
        await dispatcher.TickAsync(now.AddSeconds(6));
        var launch = Assert.Single(launches);
        Assert.Contains("OrphanBackups", launch);
        await dispatcher.TickAsync(now.AddSeconds(7));   // One request is one dispatch.
        Assert.Single(launches);
    }

    [Fact]
    public async Task GameplayWatch_CancelsExistingMaintenanceWhenGameStarts()
    {
        using var cancellation = new CancellationTokenSource();
        var playing = 0;
        using var watch = GameplayWorkGate.WatchForGameplay(cancellation,
            () => Volatile.Read(ref playing) != 0, TimeSpan.FromMilliseconds(10));
        Assert.False(cancellation.IsCancellationRequested);
        Volatile.Write(ref playing, 1);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            Task.Delay(TimeSpan.FromSeconds(5), cancellation.Token));
        Assert.True(cancellation.IsCancellationRequested);
    }

    [Fact]
    public async Task CharacterDisplay_RetriesWithBackoff_AndPreservesLastGoodSnapshot()
    {
        var clock = new ManualClock();
        var calls = 0;
        var fail = false;
        var cache = new CharacterProjectionCache((_, _) =>
        {
            calls++;
            return Task.FromResult(fail
                ? new CharacterSnapshot(null, CharacterState.Unknown, ReadSucceeded: false)
                : new CharacterSnapshot("Survivor", CharacterState.Alive, calls));
        }, clock);
        var first = await cache.ReadAsync("players", "v1");
        Assert.Equal(first, await cache.ReadAsync("players", "v1"));
        Assert.Equal(1, calls);
        fail = true;
        Assert.Equal(first, await cache.ReadAsync("players", "v2"));
        Assert.Equal(2, calls);
        for (var index = 0; index < 100; index++)
            Assert.Equal(first, await cache.ReadAsync("players", "changed-again-" + index));
        Assert.Equal(2, calls);
        clock.Advance(TimeSpan.FromSeconds(1));
        await cache.ReadAsync("players", "v2");
        Assert.Equal(3, calls);
        clock.Advance(TimeSpan.FromSeconds(1));
        await cache.ReadAsync("players", "v2");
        Assert.Equal(3, calls);
        clock.Advance(TimeSpan.FromSeconds(1));
        fail = false;
        Assert.Equal(4, (await cache.ReadAsync("players", "v2")).HoursSurvived);
        Assert.Equal(4, calls);
        cache.RetainOnly([]);
        await cache.ReadAsync("players", "v2");
        Assert.Equal(5, calls);
    }

    [Fact]
    public async Task CharacterDisplay_CancellationDoesNotPoisonCachedVersion()
    {
        var calls = 0;
        var cache = new CharacterProjectionCache((_, _) =>
        {
            calls++;
            return Task.FromResult(new CharacterSnapshot("Name", CharacterState.Alive));
        });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cache.ReadAsync(
            "players", "v1", new CancellationToken(true)));
        Assert.Equal(0, calls);
        await cache.ReadAsync("players", "v1");
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task InProcessStateCheck_PreservesDebounceOutboxAndRecovery()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = temp.GetPath("saves/Sandbox/World");
        Directory.CreateDirectory(path);
        var players = Path.Combine(path, "players.db");
        await using (var connection = new SqliteConnection($"Data Source={players};Pooling=False"))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER,name TEXT,isDead INTEGER); INSERT INTO localPlayers VALUES(1,'Name',0);";
            await command.ExecuteNonQueryAsync();
        }
        var pipeline = new StateCheckPipeline();
        // Exclusive test handle simulates the existing activity signal; independent observations remain required.
        await using (var held = new FileStream(players, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            Assert.Equal(ProcessOutcome.Succeeded, (await pipeline.RunAsync(database, temp.GetPath("saves"), 1)).Outcome);
            Assert.DoesNotContain(await database.ReadPendingOutboxAsync(), message => message.Command == "ActivateTarget");
            Assert.Equal(ProcessOutcome.Succeeded, (await pipeline.RunAsync(database, temp.GetPath("saves"), 2)).Outcome);
            Assert.Contains(await database.ReadPendingOutboxAsync(), message => message.Command == "ActivateTarget");
        }
        await pipeline.RunAsync(database, temp.GetPath("saves"), 3);
        await pipeline.RunAsync(database, temp.GetPath("saves"), 4);
        var messages = await database.ReadPendingOutboxAsync();
        Assert.Contains(messages, message => message.Command == "ClearTarget");
        Assert.DoesNotContain(messages, message => message.Command == "FinalizeTarget");
        Assert.False(await database.HasPendingBatchesAsync());
        Assert.Equal(GameState.NotPlaying, (await database.ReadCurrentStateIfChangedAsync(-1)).Game);
    }

    [Fact]
    public async Task InProcessStateCheck_RespectsExistingStateRunnerMutex()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        Directory.CreateDirectory(temp.GetPath("saves"));
        await NamedMutexRunner.TryRunAsync(NamedMutexRunner.CreateName("StateCollection", database.DatabasePath), async _ =>
        {
            var result = await new StateCheckPipeline().RunAsync(database, temp.GetPath("saves"), 1);
            Assert.False(result.Started);
            Assert.Equal(ProcessOutcome.Busy, result.Outcome);
            Assert.False(await database.HasPendingBatchesAsync());
            return true;
        });
    }

    [Fact]
    public async Task InProcessStateCheck_AppliesInterruptedBatchBeforeFreshCollection()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        Directory.CreateDirectory(temp.GetPath("saves"));
        var now = DateTimeOffset.UtcNow;
        await database.WritePendingBatchAsync(new CollectionBatch("interrupted", 1, now, now, 0, false, []));
        Assert.True(await database.HasPendingBatchesAsync());
        await new StateCheckPipeline().RunAsync(database, temp.GetPath("saves"), 2);
        Assert.False(await database.HasPendingBatchesAsync());
        Assert.True((await database.ReadCurrentStateIfChangedAsync(-1)).Modified);
    }

    [Fact]
    public void TelemetryExtremes_KeepResetBoundsWithoutFullTableScan()
    {
        using var db = new SqliteConnection("Data Source=:memory:");
        db.Open();
        using var sql = db.CreateCommand();
        sql.CommandText = "CREATE TABLE telemetry_events(event_id INTEGER PRIMARY KEY);"
            + "INSERT INTO telemetry_events VALUES(4),(9),(10000);";
        sql.ExecuteNonQuery();
        const string query = "SELECT COALESCE((SELECT MIN(event_id) FROM telemetry_events),0),"
            + "COALESCE((SELECT MAX(event_id) FROM telemetry_events),0);";
        sql.CommandText = query;
        using (var reader = sql.ExecuteReader()) { Assert.True(reader.Read()); Assert.Equal(4, reader.GetInt64(0)); Assert.Equal(10000, reader.GetInt64(1)); }
        sql.CommandText = "EXPLAIN QUERY PLAN " + query;
        using (var reader = sql.ExecuteReader())
            while (reader.Read()) Assert.DoesNotContain("SCAN telemetry_events", reader.GetString(3));
        sql.CommandText = "DELETE FROM telemetry_events;";
        sql.ExecuteNonQuery();
        sql.CommandText = query;
        using var empty = sql.ExecuteReader();
        Assert.True(empty.Read()); Assert.Equal(0, empty.GetInt64(0)); Assert.Equal(0, empty.GetInt64(1));
    }

    private sealed class ManualClock : TimeProvider
    {
        private DateTimeOffset now = new(2026, 9, 26, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan value) => now += value;
    }
}
