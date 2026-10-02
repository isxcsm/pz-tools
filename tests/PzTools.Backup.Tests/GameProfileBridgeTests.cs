using System.IO.Compression;
using PzTools.Profiling;
using PzTools.SaveBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task ProfileRecording_RunsBetweenCommands_KeepsSavingAvailable_AndConvertsWithoutUserFolders()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await File.WriteAllTextAsync(temp.GetPath("busy-game"), "busy");
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!);
        var raw = temp.GetPath("recording.pzprof.jfr");

        Assert.Equal("idle", (await client.StatusAsync(game.Pid)).State);
        Assert.Equal("not-recording", (await Assert.ThrowsAsync<GameSaveException>(() => client.StopAsync(game.Pid))).Code);
        var started = await client.StartAsync(game.Pid, raw, detailed: false, 60);
        Assert.True(started.Recording);
        Assert.True(started.HasFrames);
        Assert.Equal("sampling", started.Lua);
        Assert.Equal("already-recording",
            (await Assert.ThrowsAsync<GameSaveException>(() => client.StartAsync(game.Pid, raw, false, 60))).Code);

        // The recording holds no connection: an ordinary save goes through while it runs.
        await Client().RequestAsync(game.Pid, temp.Path, true);
        Assert.True(File.Exists(temp.GetPath("calls.txt")));
        await Task.Delay(2500);
        var running = await client.StatusAsync(game.Pid);
        Assert.True(running.Recording);
        Assert.True(running.Frames > 20);

        var stopped = await client.StopAsync(game.Pid);
        Assert.True(stopped.Frames >= running.Frames);
        Assert.Equal("idle", (await client.StatusAsync(game.Pid)).State);
        var output = temp.GetPath("recording.pzprof");
        var exported = await client.ExportAsync(raw, output, new Dictionary<string, string> { ["mode"] = "general" });
        Assert.True(exported.Frames > 20 && exported.Samples > 20 && exported.LuaSamples > 20);

        var recording = ProfileRecording.Load(output);
        Assert.False(recording.Detailed);
        Assert.Equal("Synthetic-game-thread", recording.Threads[recording.GameThread]);
        var range = ProfileAnalysis.Analyze(recording, 0, recording.Duration, recording.GameThread);
        // How large the shares are depends on how busy the machine is; that the work is found and attributed does not.
        Assert.Contains(range.Methods, row => row.Name == "zombie.GameWindow.simulateWork" && row.Samples > 0 && row.Total > 0.05);
        Assert.Contains(range.MethodGroups, group => group.Key == ProfileAnalysis.GameCode && group.Self > 0.05);
        Assert.Equal("ExampleMod", Assert.Single(range.LuaGroups).Key);
        Assert.Equal("heavyWork", range.LuaGroups[0].Rows[0].Name);
        Assert.True(range.Frames.Count > 20 && range.Frames.AverageMilliseconds is > 15 and < 80);
        // The heap is read four times a second while the recording runs.
        Assert.True(recording.Heap.Count >= 4, $"heap readings: {recording.Heap.Count}");
        Assert.All(recording.Heap, item => Assert.True(item.Used > 0 && item.Used <= item.Committed));
        // The game thread's garbage, read from its JVM counter: given to the mod function each Lua sample found running,
        // and counted for the whole thread once a second.
        Assert.True(recording.HasLuaAllocations);
        var allocations = Assert.Single(range.LuaAllocationGroups);
        Assert.Equal("ExampleMod", allocations.Key);
        Assert.True(allocations.Self > 1024 * 1024, $"allocated: {allocations.Self}");
        Assert.Equal("heavyWork", allocations.Rows[0].Name);
        Assert.Equal(range.LuaAllocated, allocations.Self);
        Assert.True(range.GameThreadAllocated > 1024 * 1024, $"game thread: {range.GameThreadAllocated}");

        // The shared file names the mod and the script, never the folders above them.
        using var text = new StreamReader(new GZipStream(File.OpenRead(output), CompressionMode.Decompress));
        var content = await text.ReadToEndAsync();
        Assert.Contains("mods/ExampleMod/media/lua/client/Example.lua", content);
        Assert.DoesNotContain("someone", content);
        Assert.DoesNotContain(temp.Path, content, StringComparison.OrdinalIgnoreCase);
    }

    [BridgeFact]
    public async Task ProfileRecording_EndsByItselfAtItsLimit_AndIsCollectedAfterwards()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!);
        var raw = temp.GetPath("limit.pzprof.jfr");
        await client.StartAsync(game.Pid, raw, detailed: true, 5);
        await Task.Delay(7000);
        Assert.Equal("finished", (await client.StatusAsync(game.Pid)).State);
        Assert.Equal("finished", (await client.StopAsync(game.Pid)).State);
        var output = temp.GetPath("limit.pzprof");
        await client.ExportAsync(raw, output, new Dictionary<string, string> { ["mode"] = "detailed" });
        var recording = ProfileRecording.Load(output);
        Assert.True(recording.Detailed);
        Assert.InRange(recording.Duration, 3_000_000, 8_000_000);
        // A second recording starts cleanly after the first ended on its own.
        Assert.True((await client.StartAsync(game.Pid, temp.GetPath("again.pzprof.jfr"), false, 60)).Recording);
        await client.StopAsync(game.Pid);
    }

    [BridgeFact]
    public async Task ProfileRecording_InStandardMode_StopsTouchingTheGameAtItsLimitWithoutAStopRequest()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!);
        await client.StartAsync(game.Pid, temp.GetPath("standard.pzprof.jfr"), detailed: false, 5);
        // As if the recording program had gone: nobody sends a stop.
        await Task.Delay(7000);
        var ended = await client.StatusAsync(game.Pid);
        Assert.Equal("finished", ended.State);
        await Task.Delay(1000);
        // Frames are no longer marked: the frame hook, the Lua sampler and the timer were released.
        Assert.Equal(ended.Frames, (await client.StatusAsync(game.Pid)).Frames);
        Assert.Equal("finished", (await client.StopAsync(game.Pid)).State);
    }
}
