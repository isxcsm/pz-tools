using System.Globalization;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task Bridge_SavingNoticeRenewsThroughCaptureAndCommit_IncludingFastForward()
    {
        using var temp = new TempDirectory();
        var bridge = CopyNoticeFixtureBridge(temp);
        await File.WriteAllTextAsync(temp.GetPath("block-preparation"), "wait before admission");
        await File.WriteAllTextAsync(temp.GetPath("cooperative-fixture"), "capture across frames");
        await File.WriteAllTextAsync(temp.GetPath("block-cooperative"), "hold capture");
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameSaveClient(bridge, notificationLanguage: "en",
            scheduledSaveUtc: DateTimeOffset.UtcNow.AddSeconds(-1));
        var request = client.RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
        try
        {
            await AwaitExtensionFileAsync(temp.GetPath("preparation-waiting"));
            Assert.False(File.Exists(temp.GetPath("notices.txt"))); // Readiness is not saving.
            File.Delete(temp.GetPath("block-preparation"));
            await AwaitExtensionFileAsync(temp.GetPath("cooperative-waiting"));
            Assert.False(File.Exists(temp.GetPath("extension-started")));
            await Task.Delay(TimeSpan.FromSeconds(3.5)); // Longer than an unrefreshed halo lifetime.
            await AssertSavingHaloAsync(temp);
            File.Delete(temp.GetPath("block-cooperative"));
            await AwaitExtensionFileAsync(temp.GetPath("extension-started"));
            await File.WriteAllTextAsync(temp.GetPath("fast-game"), "accelerate halo clock");
            await Task.Delay(TimeSpan.FromSeconds(3.5));
            await AssertSavingHaloAsync(temp);
            Assert.False(request.IsCompleted);
        }
        finally { await File.WriteAllTextAsync(temp.GetPath("release-extension"), "release"); }
        await request;
        var notices = (await File.ReadAllLinesAsync(temp.GetPath("notices.txt")))
            .Select(line => line.Split('\t')).ToArray();
        Assert.True(notices.Count(line => line[1] == "Saving") >= 10);
        Assert.Equal("Game save complete", notices[^1][1]);
        Assert.All(notices, line =>
        {
            Assert.Equal("Synthetic-game-thread", line[2]);
            Assert.Equal("current", line[5]);
        });
        var halo = await ReadNoticeHaloAsync(temp);
        Assert.Equal("Game save complete", halo[0]);
        Assert.Equal("0", halo[3]); // No progress note expired, even at accelerated game speed.
    }

    [BridgeFact]
    public async Task Bridge_SavingNoticeFailureReplacesProgress_AndNoticesOffStayOff()
    {
        using var temp = new TempDirectory();
        var bridge = CopyNoticeFixtureBridge(temp);
        foreach (var enabled in new[] { true, false })
        {
            using var world = new TempDirectory();
            await using var game = await FakeGame.StartAsync(world.Path, "normal");
            await File.WriteAllTextAsync(world.GetPath("fail-extension"), "fail commit");
            var client = new GameSaveClient(bridge, notificationLanguage: enabled ? "en" : null,
                scheduledSaveUtc: DateTimeOffset.UtcNow.AddSeconds(-1));
            var request = client.RequestProviderAsync(game.Pid, world.Path, "pztools.test-save");
            await AwaitExtensionFileAsync(world.GetPath("extension-started"));
            if (enabled) await AssertSavingHaloAsync(world);
            else Assert.False(File.Exists(world.GetPath("notices.txt")));
            await File.WriteAllTextAsync(world.GetPath("release-extension"), "release");
            Assert.Equal("extension-save-failed", (await Assert.ThrowsAsync<GameSaveException>(() => request)).Code);
            if (!enabled) Assert.False(File.Exists(world.GetPath("notices.txt")));
            else
            {
                var notices = await File.ReadAllLinesAsync(world.GetPath("notices.txt"));
                Assert.Contains("\tSaving\t", notices[0]);
                Assert.Contains("\tGame save failed\t", notices[^1]);
                Assert.DoesNotContain(notices, line => line.Contains("Game save complete", StringComparison.Ordinal));
                Assert.Equal("Game save failed", (await ReadNoticeHaloAsync(world))[0]);
            }
        }
    }

    [BridgeFact]
    public async Task Bridge_SavingNoticeNeverTargetsReplacedPlayer_OrExitedWorld()
    {
        using var temp = new TempDirectory();
        var bridge = CopyNoticeFixtureBridge(temp);
        foreach (var transition in new[] { "respawn-before-admission", "respawn-during-save", "leave-world" })
        {
            using var world = new TempDirectory();
            var beforeAdmission = transition == "respawn-before-admission";
            if (beforeAdmission) await File.WriteAllTextAsync(world.GetPath("block-preparation"), "wait");
            await using var game = await FakeGame.StartAsync(world.Path, "normal");
            var client = new GameSaveClient(bridge, notificationLanguage: "en",
                scheduledSaveUtc: DateTimeOffset.UtcNow.AddSeconds(-1));
            var request = client.RequestProviderAsync(game.Pid, world.Path, "pztools.test-save");
            await AwaitExtensionFileAsync(world.GetPath(beforeAdmission ? "preparation-waiting" : "extension-started"));
            var original = await ReadNoticeHaloAsync(world);
            await File.WriteAllTextAsync(world.GetPath(transition == "leave-world" ? "leave-world" : "respawn-player"), "change");
            if (transition != "leave-world")
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                while ((await ReadNoticeHaloAsync(world))[2] == original[2])
                    await Task.Delay(20, timeout.Token);
            }
            // Let the next frame observe the transition; leave-world is checked before its poll.
            await Task.Delay(700);
            var noticeCount = File.Exists(world.GetPath("notices.txt"))
                ? File.ReadAllLines(world.GetPath("notices.txt")).Length : 0;
            if (beforeAdmission)
            {
                Assert.Equal(0, noticeCount);
                File.Delete(world.GetPath("block-preparation"));
                await AwaitExtensionFileAsync(world.GetPath("extension-started"));
            }
            await File.WriteAllTextAsync(world.GetPath("release-extension"), "release");
            if (transition == "leave-world")
                Assert.Equal("save-world-changed", (await Assert.ThrowsAsync<GameSaveException>(() => request)).Code);
            else await request;
            var notices = File.Exists(world.GetPath("notices.txt"))
                ? File.ReadAllLines(world.GetPath("notices.txt")) : [];
            Assert.Equal(noticeCount, notices.Length);
            Assert.All(notices, line => Assert.Equal("current", line.Split('\t')[5]));
            Assert.DoesNotContain(notices, line => line.Contains("Game save complete", StringComparison.Ordinal)
                || line.Contains("Game save failed", StringComparison.Ordinal));
        }
    }

    [BridgeFact]
    public async Task Bridge_CancelledReadinessWaitDoesNotShowSaving()
    {
        using var temp = new TempDirectory();
        var bridge = CopyNoticeFixtureBridge(temp);
        await File.WriteAllTextAsync(temp.GetPath("block-preparation"), "hold admission");
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        using var cancel = new CancellationTokenSource();
        var request = new GameSaveClient(bridge, notificationLanguage: "en",
            scheduledSaveUtc: DateTimeOffset.UtcNow.AddSeconds(-1))
            .RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save", cancel.Token);
        await AwaitExtensionFileAsync(temp.GetPath("preparation-waiting"));
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => request);
        await Task.Delay(700);
        Assert.False(File.Exists(temp.GetPath("notices.txt")));
        Assert.False(File.Exists(temp.GetPath("extension-started")));
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }

    private static string CopyNoticeFixtureBridge(TempDirectory temp)
    {
        var bridge = temp.GetPath("bridge");
        var original = Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!;
        foreach (var source in Directory.EnumerateFiles(original, "*", SearchOption.AllDirectories))
        {
            var destination = Path.Combine(bridge, Path.GetRelativePath(original, source));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(source, destination);
        }
        InstallTestSaveProvider(bridge);
        return bridge;
    }

    private static async Task<string[]> ReadNoticeHaloAsync(TempDirectory temp)
    {
        File.Delete(temp.GetPath("halo-state.txt"));
        await File.WriteAllTextAsync(temp.GetPath("inspect-halo.tmp"), "inspect");
        File.Move(temp.GetPath("inspect-halo.tmp"), temp.GetPath("inspect-halo"));
        await AwaitExtensionFileAsync(temp.GetPath("halo-state.txt"));
        return await File.ReadAllLinesAsync(temp.GetPath("halo-state.txt"));
    }

    private static async Task AssertSavingHaloAsync(TempDirectory temp)
    {
        var halo = await ReadNoticeHaloAsync(temp);
        Assert.Equal("Saving", halo[0]);
        Assert.True(float.Parse(halo[1], CultureInfo.InvariantCulture) > 0);
        Assert.Equal("0", halo[3]);
    }
}
