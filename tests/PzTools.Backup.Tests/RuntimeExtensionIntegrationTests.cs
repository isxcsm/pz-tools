using PzTools.Process.Contracts.GameRuntime;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task RuntimeGuardAndVersionOverrideComposeWithoutBypassingPauseOrReplayingSave()
    {
        using var temp = new TempDirectory();
        var bridge = temp.GetPath("bridge");
        foreach (var source in Directory.EnumerateFiles(RuntimeBridgeDirectory(), "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(bridge, Path.GetRelativePath(RuntimeBridgeDirectory(), source));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(source, target);
        }
        InstallTestSaveProvider(bridge);
        var catalogue = Path.Combine(bridge, "extensions", "catalog.tsv");
        File.WriteAllText(catalogue, File.ReadAllText(catalogue).Replace("\tAll\t-\t-\t", "\tMajor\t43\t-\t"));
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid, bridge);
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        Assert.Equal("42.20", ready.GameVersion);
        var rejected = await new GameSaveClient(bridge, runtimeTicket: Ticket(ready, 1))
            .RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
        Assert.Equal("version-mismatch", rejected.FallbackReason);
        Assert.Equal(GameSaveCompletion.StandardCallReturned, rejected.Completion);
        Assert.False(File.Exists(temp.GetPath("extension-started")));
        var submitted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var delayed = new GameSaveClient(bridge, runtimeTicket: Ticket(ready, 2, 30_000),
            preparationAllowed: _ => { submitted.TrySetResult(); return Task.FromResult(true); })
            .RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save", forceVersion: true);
        await submitted.Task.WaitAsync(TimeSpan.FromSeconds(15));
        await File.WriteAllTextAsync(temp.GetPath("pause-game"), "pause");
        var paused = await watch.WaitAsync(s => s.Pause == GamePause.Paused);
        var blocked = await Assert.ThrowsAsync<GameSaveException>(() => delayed);
        Assert.Equal("runtime-deferred", blocked.Code);
        Assert.False(File.Exists(temp.GetPath("extension-started")));
        await File.WriteAllTextAsync(temp.GetPath("resume-game"), "resume");
        var resumed = await watch.WaitAsync(s => s.Pause == GamePause.Running && s.EligibilityEpoch >= paused.EligibilityEpoch);
        var ticket = Ticket(resumed, 3);
        var saving = new GameSaveClient(bridge, runtimeTicket: ticket)
            .RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save", forceVersion: true);
        try
        {
            await AwaitExtensionFileAsync(temp.GetPath("extension-started"));
            var during = await watch.WaitAsync(s => s.Sequence > resumed.Sequence + 1);
            await File.WriteAllTextAsync(temp.GetPath("pause-game"), "pause" );
            await watch.WaitAsync(state => state.Pause == GamePause.Paused);
            Assert.False(saving.IsCompleted);
            Assert.Equal(during.ProcessSession + "|" + during.WorldSession, await File.ReadAllTextAsync(temp.GetPath("extension-identity")));
        }
        finally { await File.WriteAllTextAsync(temp.GetPath("release-extension"), "release"); }
        Assert.Equal(GameSaveCompletion.DetachedWritesCommitted, (await saving).Completion);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        var replay = await Assert.ThrowsAsync<GameSaveException>(() => new GameSaveClient(bridge, runtimeTicket: ticket)
            .RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save", forceVersion: true));
        Assert.Equal("runtime-deferred", replay.Code);
        await File.WriteAllTextAsync(temp.GetPath("resume-game"), "resume" );
        var latest = await watch.WaitAsync(s => s.Pause == GamePause.Running);
        var normal = await new GameSaveClient(bridge, runtimeTicket: Ticket(latest, 4))
            .RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
        Assert.Equal("version-mismatch", normal.FallbackReason); // Prior override does not alter cached support policy.
        Assert.Equal(2, File.ReadAllLines(temp.GetPath("calls.txt")).Length);
    }
    [BridgeFact]
    public async Task ForceVersionDoesNotRestoreARemovedSaveProvider()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var result = await Client().RequestProviderAsync(game.Pid, temp.Path, "pztools.seamless-save", forceVersion: true);
        Assert.Equal("unknown-provider", result.FallbackReason);
        Assert.Equal("pztools.standard-save", result.ProviderId);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
    }
}
