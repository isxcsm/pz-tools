using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task LiveDeathUsesMemory_NotDb_AndGuardsTheExactCharacterWhilePaused()
    {
        using var temp = new TempDirectory();
        await using var db = new SqliteConnection($"Data Source={temp.GetPath("players.db")};Pooling=False");
        await db.OpenAsync(); await using var q = db.CreateCommand();
        q.CommandText = "CREATE TABLE localPlayers(id INTEGER,isDead INTEGER);INSERT INTO localPlayers VALUES(1,0);";
        await q.ExecuteNonQueryAsync();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var alive = await watch.WaitAsync(s => s.CharacterLife == RuntimeCharacterLife.Alive);
        Assert.Null(alive.DeathId);
        await File.WriteAllTextAsync(temp.GetPath("pause-game"), "pause");
        await File.WriteAllTextAsync(temp.GetPath("die-player"), "die");
        var dead = await watch.WaitAsync(s => s.CharacterLife == RuntimeCharacterLife.Dead && s.Pause == GamePause.Paused);
        Assert.Equal(alive.CharacterSession, dead.CharacterSession); Assert.NotNull(dead.DeathId);
        q.CommandText = "SELECT isDead FROM localPlayers;"; Assert.Equal(0L, await q.ExecuteScalarAsync());
        var ticket = new RuntimeSaveTicket(dead.ProcessSession, dead.ObserverEpoch, dead.WorldSession, dead.ClockEpoch,
            dead.EligibilityEpoch, 0, 1, Guid.NewGuid().ToString("N"), dead.CharacterSession, dead.DeathId);
        var receipt = await new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: ticket)
            .RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
        Assert.Equal("pztools.standard-save", receipt.ProviderId);
        Assert.Equal("unknown-provider", receipt.FallbackReason);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        var report = await watch.WaitAsync(s => s.LastSave?.Outcome == RuntimeSaveOutcome.Succeeded);
        Assert.Equal(receipt.ProviderId, report.LastSave!.Provider);
        Assert.Equal(receipt.FallbackReason, report.LastSave.Reason);
        Assert.True(report.LastSave.ElapsedMilliseconds >= report.LastSave.GameThreadMilliseconds);
        var duplicate = await Assert.ThrowsAsync<GameSaveException>(() => new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: ticket).RequestAsync(game.Pid, temp.Path, true));
        Assert.Equal("runtime-deferred", duplicate.Code);
        await File.WriteAllTextAsync(temp.GetPath("respawn-player"), "respawn");
        var next = await watch.WaitAsync(s => s.CharacterLife == RuntimeCharacterLife.Alive && s.CharacterSession != dead.CharacterSession);
        Assert.Null(next.DeathId);
        var stale = await Assert.ThrowsAsync<GameSaveException>(() => new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: ticket with { CommandSequence = 2 }).RequestAsync(game.Pid, temp.Path, true));
        Assert.Equal("runtime-deferred", stale.Code); Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        await File.WriteAllTextAsync(temp.GetPath("fail-save"), "fail");
        // Ensure the game processed the signal before submitting another request.
        await watch.WaitAsync(s => s.Sequence > next.Sequence + 1);
        await Assert.ThrowsAsync<GameSaveException>(() => Client().RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save"));
        var failed = await watch.WaitAsync(s => s.LastSave?.Outcome == RuntimeSaveOutcome.Failed);
        Assert.NotEqual(report.LastSave.RequestId, failed.LastSave!.RequestId);
        q.CommandText = "SELECT isDead FROM localPlayers;"; Assert.Equal(0L, await q.ExecuteScalarAsync());
    }
    [BridgeFact]
    public async Task InitiallyDeadAndAmbiguousPlayersAreNotNewDeathEvents()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "dead-at-start");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var dead = await watch.WaitAsync(s => s.CharacterLife == RuntimeCharacterLife.Dead);
        Assert.Null(dead.DeathId);
        await File.WriteAllTextAsync(temp.GetPath("ambiguous-players"), "two");
        var ambiguous = await watch.WaitAsync(s => s.IsWorldReady && s.CharacterLife == RuntimeCharacterLife.Unknown);
        Assert.Null(ambiguous.CharacterSession); Assert.Null(ambiguous.DeathId);
        Assert.Equal(GamePause.Running, ambiguous.Pause);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }
}
