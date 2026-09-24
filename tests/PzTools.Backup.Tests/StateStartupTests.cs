using Microsoft.Data.Sqlite;
using PzTools.Projections;
using PzTools.Zomboid.State;
using PzTools.Scheduling;

namespace PzTools.Backup.Tests;

public sealed class StateStartupTests
{
    [Fact]
    public async Task BusyCharacterDatabaseDoesNotStallDiscoveryForDefaultThirtySeconds()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("players.db");
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        { DataSource = path, Pooling = false }.ToString());
        await connection.OpenAsync();
        var command = connection.CreateCommand();
        command.CommandText = "CREATE TABLE localPlayers(id INTEGER,isDead INTEGER); BEGIN EXCLUSIVE;";
        await command.ExecuteNonQueryAsync();
        try
        {
            var timer = System.Diagnostics.Stopwatch.StartNew();
            var result = await new CharacterStateLane().CollectAsync(path);
            Assert.Equal(LaneStatus.Failed, result.Status);
            Assert.True(timer.Elapsed < TimeSpan.FromSeconds(5), timer.Elapsed.ToString());
        }
        finally { command.CommandText = "ROLLBACK;"; await command.ExecuteNonQueryAsync(); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PublishedRunnerOnlyStartsRecoveryWhenPendingWorkExists(bool pending)
    {
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR");
        if (string.IsNullOrWhiteSpace(tools)) return;
        using var temp = new TempDirectory();
        var db = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var saves = temp.GetPath("Saves"); Directory.CreateDirectory(saves);
        if (pending)
            await db.WritePendingBatchAsync(new CollectionBatch(Guid.NewGuid().ToString("N"), 1,
                DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, 1, true, []));
        var result = await new PzTools.Process.Hosting.ChildProcessHost().RunAsync(
            Path.Combine(tools, "PzTools.State.Runner.exe"),
            ["--state-db", db.DatabasePath, "--saves-root", saves, "--run-index", "2", "--worker-directory", tools]);
        Assert.True(result.ExitCode == 0, result.StandardError + result.StandardOutput);
        var envelope = PzTools.Process.Contracts.ProcessResultJson.Deserialize<PzTools.Process.Hosting.RunnerExecutionResult>(result.StandardOutput);
        using var json = System.Text.Json.JsonDocument.Parse(envelope.Result!.WorkerOutput);
        Assert.Equal(pending ? System.Text.Json.JsonValueKind.String : System.Text.Json.JsonValueKind.Null,
            json.RootElement.GetProperty("recovery").ValueKind);
        Assert.False(await db.HasPendingBatchesAsync());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PreviousActiveSaveStaysHiddenUntilFreshConfirmation(bool newGame)
    {
        using var temp = new TempDirectory();
        var db = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var boundary = DateTimeOffset.UtcNow;
        var oldPath = temp.GetPath("old"); var newPath = temp.GetPath("new");
        await Apply(db, boundary.AddMinutes(-10), (oldPath, ActivityState.Active));
        await Apply(db, boundary.AddMinutes(-9), (oldPath, ActivityState.Active));
        var views = new RevisionedViewStore();
        var projector = new StateProjector(db, views, boundary);
        await projector.ProjectOnceAsync();
        Assert.Equal(ActivityState.Unknown, Assert.Single(Read(views).Saves).Activity);
        Assert.Equal(ViewFreshness.Stale, Assert.Single(Read(views).Saves).Freshness);
        for (var i = 0; i < 2; i++)
        {
            var observations = newGame
                ? new[] { (oldPath, ActivityState.Inactive), (newPath, ActivityState.Active) }
                : new[] { (oldPath, ActivityState.Inactive) };
            await Apply(db, boundary.AddSeconds(i + 1), observations);
            await projector.ProjectOnceAsync();
            Assert.DoesNotContain(Read(views).Saves, x => x.Name == "old" && x.Activity == ActivityState.Active);
            if (i == 0) Assert.DoesNotContain(Read(views).Saves, x => x.Activity == ActivityState.Active);
        }
        Assert.Equal(newGame ? GameState.Playing : GameState.NotPlaying, Read(views).Game);
        if (newGame) Assert.Equal("new", Assert.Single(Read(views).Saves, x => x.Activity == ActivityState.Active).Name);
    }

    [Fact]
    public async Task SameSaveRevalidationDoesNotRequireASemanticRevision()
    {
        using var temp = new TempDirectory();
        var db = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var boundary = DateTimeOffset.UtcNow;
        var path = temp.GetPath("save");
        await Apply(db, boundary.AddMinutes(-2), (path, ActivityState.Active));
        await Apply(db, boundary.AddMinutes(-1), (path, ActivityState.Active));
        var oldRevision = (await db.ReadCurrentStateIfChangedAsync(-1)).StateRevision;
        var views = new RevisionedViewStore();
        var projector = new StateProjector(db, views, boundary);
        await projector.ProjectOnceAsync();
        Assert.Equal(ActivityState.Unknown, Assert.Single(Read(views).Saves).Activity);
        await Apply(db, boundary.AddSeconds(1), (path, ActivityState.Active));
        Assert.Equal(oldRevision, (await db.ReadCurrentStateIfChangedAsync(-1)).StateRevision);
        await projector.ProjectOnceAsync();
        Assert.Equal(ActivityState.Active, Assert.Single(Read(views).Saves).Activity);
        Assert.Equal(ViewFreshness.Fresh, Assert.Single(Read(views).Saves).Freshness);
    }

    [Fact]
    public async Task FailedProbeDoesNotRevalidateAnOldActiveState()
    {
        using var temp = new TempDirectory();
        var db = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var boundary = DateTimeOffset.UtcNow;
        var path = temp.GetPath("save");
        await Apply(db, boundary.AddMinutes(-2), (path, ActivityState.Active));
        await Apply(db, boundary.AddMinutes(-1), (path, ActivityState.Active));
        await Apply(db, boundary.AddSeconds(1), (path, ActivityState.Unknown));
        var views = new RevisionedViewStore();
        await new StateProjector(db, views, boundary).ProjectOnceAsync();
        Assert.Equal(GameState.Unknown, Read(views).Game);
        Assert.Equal(ActivityState.Unknown, Assert.Single(Read(views).Saves).Activity);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PublishedSchedulerRevalidatesImmediatelyDespiteFutureDueTime(bool newGame)
    {
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR");
        if (string.IsNullOrWhiteSpace(tools)) return;
        using var temp = new TempDirectory();
        var saves = temp.GetPath("Saves");
        var oldSave = Path.Combine(saves, "Sandbox", "old");
        var newSave = Path.Combine(saves, "Sandbox", "new");
        foreach (var save in new[] { oldSave, newSave })
        {
            Directory.CreateDirectory(save);
            await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = Path.Combine(save, "players.db"), Pooling = false }.ToString());
            await connection.OpenAsync();
            var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER,isDead INTEGER); INSERT INTO localPlayers VALUES(1,0);";
            await command.ExecuteNonQueryAsync();
        }
        var db = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var now = DateTimeOffset.UtcNow;
        await Apply(db, now.AddMinutes(-2), (oldSave, ActivityState.Active));
        await Apply(db, now.AddMinutes(-1), (oldSave, ActivityState.Active));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await scheduler.PrepareStateTickAsync(TimeSpan.FromSeconds(60), now);
        await scheduler.AdvanceStateDueAsync(TimeSpan.FromSeconds(60), now);
        using var gameHandle = newGame
            ? File.Open(Path.Combine(newSave, "players.db"), FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite) : null;
        var start = new System.Diagnostics.ProcessStartInfo(Path.Combine(tools, "PzTools.State.Scheduler.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "--scheduler-db", scheduler.DatabasePath, "--state-db", db.DatabasePath,
            "--saves-root", saves, "--worker-directory", tools, "--interval-seconds", "60",
            "--control-db", temp.GetPath("control.db") }) start.ArgumentList.Add(arg);
        using var process = System.Diagnostics.Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        try
        {
            var timer = System.Diagnostics.Stopwatch.StartNew();
            CurrentStateSnapshot snapshot;
            do
            {
                await Task.Delay(200);
                snapshot = await db.ReadCurrentStateIfChangedAsync(-1);
                if (snapshot.Saves.Count == 2 && snapshot.Saves.All(x => x.ObservedUtc >= now && !x.Stale)
                    && snapshot.Game == (newGame ? GameState.Playing : GameState.NotPlaying)) break;
            } while (timer.Elapsed < TimeSpan.FromSeconds(12) && !process.HasExited);
            if (snapshot.Saves.Count != 2 || snapshot.Saves.Any(x => x.ObservedUtc < now))
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
                await process.WaitForExitAsync();
                Assert.Fail("Startup did not confirm both samples. " + await output + "\n" + await error);
            }
            Assert.Equal(2, snapshot.Saves.Count);
            Assert.All(snapshot.Saves, x => Assert.True(x.ObservedUtc >= now));
            Assert.Equal(newGame ? GameState.Playing : GameState.NotPlaying, snapshot.Game);
            Assert.DoesNotContain(snapshot.Saves, x => x.DisplayName == "old" && x.Activity == ActivityState.Active);
        }
        finally
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            await Task.WhenAll(output, error);
        }
    }

    private static SaveListView Read(RevisionedViewStore views) =>
        views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).Snapshot!;

    private static async Task Apply(StateDatabase db, DateTimeOffset time,
        params (string Path, ActivityState Activity)[] states)
    {
        var observations = states.Select(s => new SaveObservation(Path.GetFullPath(s.Path).ToUpperInvariant(),
            "Sandbox", Path.GetFileName(s.Path), true, false, s.Activity, CharacterState.Alive,
            s.Activity == ActivityState.Unknown ? LaneStatus.Failed : LaneStatus.Succeeded, LaneStatus.Succeeded)).ToArray();
        await db.WritePendingBatchAsync(new CollectionBatch(Guid.NewGuid().ToString("N"), 1, time, time, 1, true, observations));
        await new StateReactor().RunAsync(db);
    }
}
