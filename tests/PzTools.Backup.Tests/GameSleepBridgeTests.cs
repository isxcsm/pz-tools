using PzTools.Process.Contracts.GameRuntime;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task RuntimeSleep_FreezesAcceleratedClock_RevokesQueuedSave_AndKeepsManualSaving()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var awake = await watch.WaitAsync(s => s.IsWorldReady && s.Sleep == RuntimeSleep.Awake);
        var submitted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(awake, 1, 30_000),
            preparationAllowed: _ => { submitted.TrySetResult(); return Task.FromResult(true); })
            .RequestAsync(game.Pid, temp.Path, true);
        await submitted.Task.WaitAsync(TimeSpan.FromSeconds(15));
        await File.WriteAllTextAsync(temp.GetPath("fast-game"), "fast");
        await File.WriteAllTextAsync(temp.GetPath("sleep-player"), "sleep");
        var asleep = await watch.WaitAsync(s => s.Sleep == RuntimeSleep.Asleep && s.SpeedLevel == 4);
        Assert.Equal(GamePause.Running, asleep.Pause); // Sleeping is a separate JVM fact.
        var later = await watch.WaitAsync(s => s.Sleep == RuntimeSleep.Asleep && s.Sequence > asleep.Sequence + 2);
        Assert.Equal(asleep.ActiveMilliseconds, later.ActiveMilliseconds);
        Assert.Equal(awake.WorldSession, asleep.WorldSession);
        Assert.True(asleep.EligibilityEpoch > awake.EligibilityEpoch);
        Assert.Equal("runtime-deferred", (await Assert.ThrowsAsync<GameSaveException>(() => queued)).Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        // Both a freshly forged periodic ticket and an already queued one are held.
        var held = await Assert.ThrowsAsync<GameSaveException>(() =>
            new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(later, 2)).RequestAsync(game.Pid, temp.Path, true));
        Assert.Equal("runtime-deferred", held.Code);
        await Client().RequestAsync(game.Pid, temp.Path, true);
        Assert.Equal("1", await File.ReadAllTextAsync(temp.GetPath("memory-only-state.txt")));
        await File.WriteAllTextAsync(temp.GetPath("wake-player"), "wake");
        var resumed = await watch.WaitAsync(s => s.Sleep == RuntimeSleep.Awake && s.ActiveMilliseconds > asleep.ActiveMilliseconds);
        Assert.Equal(asleep.ClockEpoch, resumed.ClockEpoch);
        await new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(resumed, 3)).RequestAsync(game.Pid, temp.Path, true);
        Assert.Equal("2", await File.ReadAllTextAsync(temp.GetPath("memory-only-state.txt")));
    }
}