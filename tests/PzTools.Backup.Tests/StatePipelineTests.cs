using Microsoft.Data.Sqlite;
using PzTools.Process.Hosting;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class StatePipelineTests
{
    [RealZomboidSavesFact]
    public async Task RealSamples_AreReadOnlyAndContainAliveAndDeadFixtures()
    {
        var root = Environment.GetEnvironmentVariable("PZTOOLS_REAL_SAVES_ROOT")!;
        var discovery = new SaveDiscoveryLane().Collect(root);
        Assert.True(discovery.Complete);
        var lane = new CharacterStateLane();
        var states = new List<CharacterState>();
        foreach (var save in discovery.Saves.Where(item => item.HasPlayersDatabase))
        {
            states.Add((await lane.CollectAsync(save.PlayersDatabasePath)).State);
        }
        Assert.Contains(CharacterState.Alive, states);
        Assert.Contains(CharacterState.Dead, states);
    }

    [RealZomboidSavesFact]
    public async Task RealSamples_ReadCharacterSurvivalDurationWhenSupported()
    {
        var root = Environment.GetEnvironmentVariable("PZTOOLS_REAL_SAVES_ROOT")!;
        var saves = new SaveDiscoveryLane().Collect(root).Saves
            .Where(item => item.HasPlayersDatabase);
        var snapshots = new List<CharacterSnapshot>();
        foreach (var save in saves)
            snapshots.Add(await new CharacterNameReader().ReadSnapshotAsync(
                save.PlayersDatabasePath));
        Assert.Contains(snapshots, item => item.HoursSurvived is > 0 and < 100_000);
    }

    [Theory]
    [InlineData(0, CharacterState.Alive)]
    [InlineData(1, CharacterState.Dead)]
    public async Task CharacterStateLane_ReadsSupportedPlayerSchema(
        long isDead,
        CharacterState expected)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("players.db");
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Pooling = false,
        }.ToString();
        await using (var connection = new SqliteConnection(connectionString))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER,isDead INTEGER); INSERT INTO localPlayers VALUES(1,$dead);";
            command.Parameters.AddWithValue("$dead", isDead);
            await command.ExecuteNonQueryAsync();
        }

        var result = await new CharacterStateLane().CollectAsync(path);
        Assert.Equal(LaneStatus.Succeeded, result.Status);
        Assert.Equal(expected, result.State);
    }

    [Fact]
    public async Task CharacterNameReader_PrefersLivingLocalCharacter()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("players.db");
        await using (var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = """
                CREATE TABLE localPlayers(id INTEGER, name TEXT, isDead INTEGER);
                CREATE TABLE networkPlayers(id INTEGER, name TEXT, isDead INTEGER);
                INSERT INTO localPlayers VALUES(1, 'Past Character', 1);
                INSERT INTO localPlayers VALUES(2, 'Current Character', 0);
                INSERT INTO networkPlayers VALUES(3, 'Network Character', 0);
                """;
            await command.ExecuteNonQueryAsync();
        }

        var snapshot = await new CharacterNameReader().ReadSnapshotAsync(path);
        Assert.Equal("Current Character", snapshot.Name);
        Assert.Equal(CharacterState.Alive, snapshot.State);
    }

    [Fact]
    public async Task CharacterNameReader_UsesNetworkCharacterAndHandlesMissingNameSchema()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("players.db");
        await using (var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = """
                CREATE TABLE localPlayers(id INTEGER, isDead INTEGER);
                CREATE TABLE networkPlayers(id INTEGER, name TEXT, isDead INTEGER);
                INSERT INTO networkPlayers VALUES(1, 'Network Character', 0);
                """;
            await command.ExecuteNonQueryAsync();
        }

        Assert.Equal("Network Character", await new CharacterNameReader().ReadAsync(path));
        Assert.Null(await new CharacterNameReader().ReadAsync(temp.GetPath("missing.db")));
    }

    [Fact]
    public async Task CharacterNameReader_ReportsDeadSelectedCharacter()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("players.db");
        await using (var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER, name TEXT, isDead INTEGER); "
                + "INSERT INTO localPlayers VALUES(1, 'Last Survivor', 1);";
            await command.ExecuteNonQueryAsync();
        }

        var snapshot = await new CharacterNameReader().ReadSnapshotAsync(path);
        Assert.Equal("Last Survivor", snapshot.Name);
        Assert.Equal(CharacterState.Dead, snapshot.State);
    }

    [Fact]
    public async Task CharacterNameReader_IgnoresMalformedDurationBlob()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("players.db");
        await using (var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER, name TEXT, isDead INTEGER, "
                + "worldversion INTEGER, data BLOB); "
                + "INSERT INTO localPlayers VALUES(1, 'Survivor', 0, 249, $data);";
            command.Parameters.AddWithValue("$data", new byte[256]);
            await command.ExecuteNonQueryAsync();
        }

        var snapshot = await new CharacterNameReader().ReadSnapshotAsync(path);
        Assert.Equal("Survivor", snapshot.Name);
        Assert.Equal(CharacterState.Alive, snapshot.State);
        Assert.Null(snapshot.HoursSurvived);
    }

    [Fact]
    public async Task Reactor_DebouncesTransitionsAndOnlyAdvancesSemanticRevision()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = Path.GetFullPath(temp.GetPath("save")).ToUpperInvariant();
        var reactor = new StateReactor();

        await database.WritePendingBatchAsync(Batch(1, path, ActivityState.Inactive));
        var first = await reactor.RunAsync(database);
        Assert.Equal(1, first.AfterRevision);

        await database.WritePendingBatchAsync(Batch(2, path, ActivityState.Inactive));
        var second = await reactor.RunAsync(database);
        Assert.Equal(2, second.AfterRevision);
        Assert.Equal(ActivityState.Inactive,
            (await database.ReadCurrentStateIfChangedAsync(1)).Saves.Single().Activity);

        await database.WritePendingBatchAsync(Batch(3, path, ActivityState.Inactive));
        var identical = await reactor.RunAsync(database);
        Assert.Equal(2, identical.AfterRevision);
        Assert.False((await database.ReadCurrentStateIfChangedAsync(2)).Modified);

        await database.WritePendingBatchAsync(Batch(4, path, ActivityState.Active));
        await reactor.RunAsync(database);
        await database.WritePendingBatchAsync(Batch(5, path, ActivityState.Active));
        var active = await reactor.RunAsync(database);
        Assert.Equal(3, active.AfterRevision);
        Assert.Equal(1, active.Transitions);
        Assert.Equal(1, active.OutboxMessages);
        Assert.Equal(GameState.Playing,
            (await database.ReadCurrentStateIfChangedAsync(2)).Game);
    }

    [Fact]
    public async Task Reactor_IncompleteDiscoveryMarksStaleAndCompleteDiscoveryDeletes()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = Path.GetFullPath(temp.GetPath("save")).ToUpperInvariant();
        var reactor = new StateReactor();
        await database.WritePendingBatchAsync(Batch(1, path, ActivityState.Inactive));
        await reactor.RunAsync(database);

        await database.WritePendingBatchAsync(EmptyBatch(2, complete: false));
        await reactor.RunAsync(database);
        var stale = await database.ReadCurrentStateIfChangedAsync(0);
        Assert.True(stale.Saves.Single().Stale);

        await database.WritePendingBatchAsync(EmptyBatch(3, complete: true));
        await reactor.RunAsync(database);
        var deleted = await database.ReadCurrentStateIfChangedAsync(stale.StateRevision);
        Assert.True(deleted.Modified);
        Assert.Empty(deleted.Saves);
    }

    [Fact]
    public async Task Reactor_ActivityFailurePublishesUnknownUntilProbeRecovers()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = Path.GetFullPath(temp.GetPath("save")).ToUpperInvariant();
        var reactor = new StateReactor();

        await ApplyAsync(1, ActivityState.Active, LaneStatus.Succeeded);
        await ApplyAsync(2, ActivityState.Active, LaneStatus.Succeeded);
        Assert.Equal(GameState.Playing,
            (await database.ReadCurrentStateIfChangedAsync(0)).Game);

        await database.WritePendingBatchAsync(Batch(
            3, path, ActivityState.Unknown,
            activityStatus: LaneStatus.Failed));
        await reactor.RunAsync(database);
        var failed = await database.ReadCurrentStateIfChangedAsync(0);
        Assert.Equal(GameState.Unknown, failed.Game);
        Assert.True(failed.Saves.Single().Stale);

        await ApplyAsync(4, ActivityState.Inactive, LaneStatus.Succeeded);
        await ApplyAsync(5, ActivityState.Inactive, LaneStatus.Succeeded);
        var recovered = await database.ReadCurrentStateIfChangedAsync(0);
        Assert.Equal(GameState.NotPlaying, recovered.Game);
        Assert.False(recovered.Saves.Single().Stale);

        async Task ApplyAsync(long run, ActivityState activity, LaneStatus status)
        {
            await database.WritePendingBatchAsync(Batch(
                run, path, activity, activityStatus: status));
            await reactor.RunAsync(database);
        }
    }

    [Fact]
    public async Task Reactor_RecordsCharacterDeathAndQueuesDynamicActiveTarget()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = Path.GetFullPath(temp.GetPath("save")).ToUpperInvariant();
        var reactor = new StateReactor();

        await database.WritePendingBatchAsync(Batch(
            1, path, ActivityState.Inactive, character: CharacterState.Alive));
        await reactor.RunAsync(database);
        await database.WritePendingBatchAsync(Batch(
            2, path, ActivityState.Inactive, character: CharacterState.Dead));
        await reactor.RunAsync(database);
        await database.WritePendingBatchAsync(Batch(
            3, path, ActivityState.Active, character: CharacterState.Dead));
        await reactor.RunAsync(database);
        await database.WritePendingBatchAsync(Batch(
            4, path, ActivityState.Active, character: CharacterState.Dead));
        await reactor.RunAsync(database);

        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = database.DatabasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        }.ToString();
        await using var connection = new SqliteConnection(connectionString);
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT kind,previous_value,current_value FROM state_transitions ORDER BY created_utc;";
        await using var reader = await command.ExecuteReaderAsync();
        var transitions = new List<(string Kind, string Previous, string Current)>();
        while (await reader.ReadAsync())
            transitions.Add((reader.GetString(0), reader.GetString(1), reader.GetString(2)));

        Assert.Contains(("Character", "Alive", "Dead"), transitions);
        Assert.DoesNotContain(transitions, item => item.Kind == "UnmappedActiveSave");
        var outbox = await database.ReadPendingOutboxAsync();
        Assert.Contains(outbox, item =>
            item.Command == "ActivateTarget"
            && item.SaveId == "Sandbox/Save"
            && item.SourcePath == path);
    }

    [Fact]
    public async Task Reactor_PersistedDeathNeverQueuesALiveDeathBackup()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = Path.GetFullPath(temp.GetPath("save")).ToUpperInvariant();
        var reactor = new StateReactor();
        await database.WritePendingBatchAsync(Batch(
            1, path, ActivityState.Active, character: CharacterState.Alive));
        await reactor.RunAsync(database);
        await database.WritePendingBatchAsync(Batch(
            2, path, ActivityState.Active, character: CharacterState.Alive));
        await reactor.RunAsync(database);
        await database.WritePendingBatchAsync(Batch(
            3, path, ActivityState.Active, character: CharacterState.Dead));
        await reactor.RunAsync(database);

        Assert.DoesNotContain(await database.ReadPendingOutboxAsync(), item => item.Command == "RunOnceNow");
    }

    [Fact]
    public async Task GameActivityProbe_DetectsExclusiveLockWithoutWriting()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("players.db");
        await File.WriteAllBytesAsync(path, [1, 2, 3]);
        var original = await File.ReadAllBytesAsync(path);
        var lane = new GameActivityLane();

        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Assert.Equal(ActivityState.Active, lane.Probe(path).State);
        }

        Assert.Equal(ActivityState.Inactive, lane.Probe(path).State);
        Assert.Equal(original, await File.ReadAllBytesAsync(path));
    }

    [Fact]
    public async Task NamedMutexRunner_SkipsConcurrentAttempt()
    {
        var name = $"Local\\PzTools.Test.{Guid.NewGuid():N}";
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var first = NamedMutexRunner.TryRunAsync(name, async _ =>
        {
            entered.SetResult();
            await release.Task;
            return 1;
        });
        await entered.Task;
        var second = await NamedMutexRunner.TryRunAsync(name, _ => Task.FromResult(2));
        Assert.False(second.Acquired);
        release.SetResult();
        Assert.True((await first).Acquired);
    }

    [Fact]
    public async Task ChildProcessHost_CancellationTerminatesJob()
    {
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
        var host = new ChildProcessHost();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => host.RunAsync(
            Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"],
            cancellation.Token));
    }

    [Fact]
    public async Task ChildProcessHost_NormalizesLaunchFailure()
    {
        using var temp = new TempDirectory();

        var result = await new ChildProcessHost().RunAsync(
            temp.GetPath("missing-worker.exe"), []);

        Assert.False(result.Started);
        Assert.Null(result.ExitCode);
        Assert.Equal("launch-failed", result.FailureCode);
    }

    private static CollectionBatch Batch(
        long runIndex,
        string path,
        ActivityState activity,
        CharacterState character = CharacterState.Alive,
        LaneStatus activityStatus = LaneStatus.Succeeded,
        LaneStatus characterStatus = LaneStatus.Succeeded)
    {
        var now = DateTimeOffset.UtcNow;
        return new CollectionBatch(Guid.NewGuid().ToString("D"), runIndex, now, now, 1, true,
        [
            new SaveObservation(path, "Sandbox", "Save", true, false, activity,
                character, activityStatus, characterStatus),
        ]);
    }

    private static CollectionBatch EmptyBatch(long runIndex, bool complete)
    {
        var now = DateTimeOffset.UtcNow;
        return new CollectionBatch(Guid.NewGuid().ToString("D"), runIndex, now, now, 1, complete, []);
    }

    private sealed class RealZomboidSavesFactAttribute : FactAttribute
    {
        public RealZomboidSavesFactAttribute()
        {
            var root = Environment.GetEnvironmentVariable("PZTOOLS_REAL_SAVES_ROOT");
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
            {
                Skip = "Set PZTOOLS_REAL_SAVES_ROOT to a read-only Project Zomboid Saves root.";
            }
        }
    }
}
