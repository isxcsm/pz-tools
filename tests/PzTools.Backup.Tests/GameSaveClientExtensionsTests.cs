using PzTools.SaveBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [Fact]
    public void ProviderReceiptDistinguishesDrainedQueuesFromAnAtomicCheckpoint()
    {
        const string id = "pztools.seamless-save";
        var response = GameSaveClient.ParseResponse($"SAVED\t{id}\tGAME_SAVE_AND_DATABASE_QUEUES_DRAINED\t{Encode("completed")}\t-", id);
        Assert.Equal(GameSaveCompletion.GameSaveAndDatabaseQueuesDrained, response.Completion);
        Assert.Null(response.FallbackReason);
        var fileResponse = GameSaveClient.ParseResponse($"SAVED\t{id}\tGAME_SAVE_AND_PENDING_WRITES_DRAINED\t{Encode("completed")}\t-", id);
        Assert.Equal(GameSaveCompletion.GameSaveAndPendingWritesDrained, fileResponse.Completion);
        Assert.Throws<GameSaveException>(() => GameSaveClient.ParseResponse(
            $"SAVED\tpztools.standard-save\tGAME_SAVE_AND_PENDING_WRITES_DRAINED\t{Encode("returned")}\t-", id));
        Assert.Throws<GameSaveException>(() => GameSaveClient.ParseResponse($"OK\t{Encode("returned")}", id));
        Assert.Throws<GameSaveException>(() => GameSaveClient.ParseResponse($"SAVED\tpztools.standard-save\tDETACHED_WRITES_COMMITTED\t{Encode("returned")}\t-", id));
    }

    [BridgeFact]
    public async Task ProviderUnsupportedBuildFallsBackInTheSameSessionAndSavesExactlyOnce()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var result = await Client().RequestProviderAsync(game.Pid, temp.Path, "pztools.seamless-save");
        Assert.Equal("pztools.standard-save", result.ProviderId);
        Assert.Equal(GameSaveCompletion.StandardCallReturned, result.Completion);
        Assert.Equal("unsupported-game-build", result.FallbackReason);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        await AssertIdleAsync(temp);
    }
    [BridgeFact]
    public async Task ProviderWaitsWithoutBlockingGameLoop_AndNeverReplaysFailedOrDisconnectedWrites()
    {
        using var temp = new TempDirectory();
        var bridge = temp.GetPath("bridge");
        var original = Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!;
        foreach (var source in Directory.EnumerateFiles(original, "*", SearchOption.AllDirectories))
        {
            var destination = Path.Combine(bridge, Path.GetRelativePath(original, source));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(source, destination);
        }
        File.Copy(Environment.GetEnvironmentVariable("PZTOOLS_EXTENSION_FIXTURE_JAR")!,
            Path.Combine(bridge, "extensions", "pztools-seamless-save.jar"), true);
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameSaveClient(bridge);
        var first = client.RequestProviderAsync(game.Pid, temp.Path, "pztools.seamless-save");
        try
        {
            await AwaitExtensionFileAsync(temp.GetPath("extension-started"));
            await File.WriteAllTextAsync(temp.GetPath("inspect-hook"), "inspect");
            await AwaitExtensionFileAsync(temp.GetPath("hook-state.txt"));
            Assert.False(first.IsCompleted); // The game loop processed its signal while the write was still blocked.
        }
        finally { await File.WriteAllTextAsync(temp.GetPath("release-extension"), "release"); }
        var result = await first;
        Assert.Equal(GameSaveCompletion.DetachedWritesCommitted, result.Completion);
        Assert.Contains("fixtureCapture=complete", result.Detail);
        Assert.True(File.Exists(temp.GetPath("extension-written")));
        Assert.True(File.Exists(temp.GetPath("extension-closed")));
        Assert.False(File.Exists(temp.GetPath("calls.txt"))); // Fixture provider, not a replayed standard save.
        await File.WriteAllTextAsync(temp.GetPath("fail-extension"), "fail");
        var failed = await Assert.ThrowsAsync<GameSaveException>(() => client.RequestProviderAsync(game.Pid, temp.Path, "pztools.seamless-save"));
        Assert.Equal("extension-save-failed", failed.Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        File.Delete(temp.GetPath("fail-extension"));
        File.Delete(temp.GetPath("release-extension"));
        File.Delete(temp.GetPath("extension-started"));
        File.Delete(temp.GetPath("extension-closed"));
        using var cancellation = new CancellationTokenSource();
        var abandoned = client.RequestProviderAsync(game.Pid, temp.Path, "pztools.seamless-save", cancellation.Token);
        try
        {
            await AwaitExtensionFileAsync(temp.GetPath("extension-started"));
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => abandoned);
            var busy = await Assert.ThrowsAsync<GameSaveException>(() => client.RequestAsync(game.Pid, temp.Path, true));
            Assert.Equal("busy", busy.Code);
            Assert.False(File.Exists(temp.GetPath("calls.txt")));
        }
        finally { await File.WriteAllTextAsync(temp.GetPath("release-extension"), "release"); }
        await AwaitExtensionFileAsync(temp.GetPath("extension-closed"));
        // The writer's close marker precedes the next game-loop observation and callback release.
        // Wait for the actual idle condition, not a fixed delay or a weaker close-file proxy.
        using (var idleDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(10)))
        {
            while (true)
            {
                var state = await ReadHookAsync(temp);
                if (state.Contains("callbackActive=false") && !state.Contains("bridge-session-active")) break;
                await Task.Delay(20, idleDeadline.Token);
            }
        }
        await AssertIdleAsync(temp);
        await client.RequestAsync(game.Pid, temp.Path, true);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
    }
    private static async Task AwaitExtensionFileAsync(string path)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        while (!File.Exists(path)) await Task.Delay(10, timeout.Token);
    }
}
