using PzTools.Process.Contracts.GameRuntime;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task RuntimeSubscription_IdentifiesMainMenuOnLateAttachWithoutSaving()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "menu");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var menu = await watch.WaitAsync(s => s.Phase == WorldPhase.Menu);
        AssertNonPlaying(menu);
        Assert.Equal(0, menu.ActiveMilliseconds);
        var later = await watch.WaitAsync(s => s.Sequence > menu.Sequence);
        Assert.Equal(WorldPhase.Menu, later.Phase);
        Assert.Equal(menu.ActiveMilliseconds, later.ActiveMilliseconds);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        var manual = await Assert.ThrowsAsync<GameSaveException>(() => Client().RequestAsync(game.Pid, temp.Path, true));
        Assert.Equal("not-in-world", manual.Code);
        var guarded = await Assert.ThrowsAsync<GameSaveException>(() =>
            new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(later, 1))
                .RequestAsync(game.Pid, temp.Path, true));
        Assert.Equal("runtime-deferred", guarded.Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }

    [BridgeFact]
    public async Task RuntimeSubscription_DistinguishesMenuLoadingUnknownAndPausedAcrossWorldTransitions()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var previous = await watch.WaitAsync(s => s.IsWorldReady && s.ActiveMilliseconds > 0);
        var initialWorld = previous.WorldSession;
        long ordinal = 0;

        async Task<RuntimeSnapshot> TransitionAsync(string signal, WorldPhase expected)
        {
            var sequence = previous.Sequence;
            await File.WriteAllTextAsync(temp.GetPath(signal), signal);
            previous = await watch.WaitAsync(s => s.Sequence > sequence && s.Phase == expected);
            return previous;
        }

        foreach (var (signal, phase) in new[]
        {
            ("enter-menu", WorldPhase.Menu),
            ("unknown-state", WorldPhase.Unknown),
            ("begin-load", WorldPhase.Loading),
            ("empty-state", WorldPhase.Unknown),
            ("enter-menu", WorldPhase.Menu),
            ("unload-menu", WorldPhase.Unloading),
            ("enter-menu", WorldPhase.Menu),
            ("ingame-without-cell", WorldPhase.Loading),
        })
        {
            var idle = await TransitionAsync(signal, phase);
            AssertNonPlaying(idle);
            var guarded = await Assert.ThrowsAsync<GameSaveException>(() =>
                new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(idle, ++ordinal))
                    .RequestAsync(game.Pid, temp.Path, true));
            Assert.Equal("runtime-deferred", guarded.Code);
            Assert.False(File.Exists(temp.GetPath("calls.txt")));
        }

        var ready = await TransitionAsync("enter-world", WorldPhase.Ready);
        Assert.True(ready.IsWorldReady);
        Assert.NotEqual(initialWorld, ready.WorldSession);
        await File.WriteAllTextAsync(temp.GetPath("pause-game"), "pause");
        var paused = await watch.WaitAsync(s => s.Sequence > ready.Sequence && s.Pause == GamePause.Paused);
        Assert.Equal(WorldPhase.Ready, paused.Phase);
        Assert.True(paused.IsWorldReady);
        // A real paused world is still open; observing a main menu must not change this contract.
        await Client().RequestAsync(game.Pid, temp.Path, true);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
    }

    // Seen in the game: leaving for the main menu showed "Checking game status". The world is saved, unloaded and
    // the mods reloaded in one frame that starts after that frame's sample, so the last sample still says Ready.
    [BridgeFact]
    public async Task RuntimeSubscription_TellsAWorldBeingLeftFromAGameHungInIt()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);

        foreach (var hold in new[] { "hold-save", "hold-exit" })
        {
            var ready = await watch.WaitAsync(s => s.IsWorldReady && s.ActiveMilliseconds > 0);
            await File.WriteAllTextAsync(temp.GetPath(hold), hold);
            await File.WriteAllTextAsync(temp.GetPath("quit-to-menu"), "quit");
            var leaving = await watch.WaitAsync(s => s.Sequence > ready.Sequence && s.Phase == WorldPhase.Unloading);
            AssertNonPlaying(leaving);
            Assert.Equal(ready.WorldSession, leaving.WorldSession);
            Assert.True(leaving.ActiveMilliseconds >= ready.ActiveMilliseconds);
            Assert.True(leaving.SampleAgeMilliseconds >= 1000);

            File.Delete(temp.GetPath(hold));
            var menu = await watch.WaitAsync(s => s.Phase == WorldPhase.Menu);
            Assert.True(menu.Sequence > leaving.Sequence);
            await File.WriteAllTextAsync(temp.GetPath("enter-world"), "enter");
        }

        // A game thread stopped anywhere else in its world may be hung: it stays Ready, and the app treats it so.
        var world = await watch.WaitAsync(s => s.IsWorldReady && s.SampleAgeMilliseconds < 1000);
        await File.WriteAllTextAsync(temp.GetPath("hold-frame"), "hold");
        var hung = await watch.WaitAsync(s => s.SampleAgeMilliseconds > 3000);
        Assert.Equal(WorldPhase.Ready, hung.Phase);
        Assert.Equal(world.WorldSession, hung.WorldSession);
        File.Delete(temp.GetPath("hold-frame"));
    }

    private static void AssertNonPlaying(RuntimeSnapshot value)
    {
        Assert.False(value.IsWorldReady);
        Assert.Null(value.SavePath);
        Assert.Equal(GamePause.Unknown, value.Pause);
        Assert.Equal(-1, value.SpeedLevel);
        Assert.Equal(RuntimeCharacterLife.Unknown, value.CharacterLife);
        Assert.Equal(RuntimeSleep.Unknown, value.Sleep);
    }
}
