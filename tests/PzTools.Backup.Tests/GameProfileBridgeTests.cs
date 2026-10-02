using System.IO.Compression;
using PzTools.Profiling;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task ProfileRecording_RunsBetweenCommands_KeepsSavingAvailable_AndConvertsWithoutUserFolders()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await File.WriteAllTextAsync(temp.GetPath("busy-game"), "busy");
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!);
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
        // The file's top-level code keeps its file name, not the folders of the full path it is named after.
        Assert.Equal(["Example.lua", "OnTick", "heavyWork"],
            new[] { range.LuaCallTrees["ExampleMod"].Children[0], range.LuaCallTrees["ExampleMod"].Children[0].Children[0],
                range.LuaCallTrees["ExampleMod"].Children[0].Children[0].Children[0] }.Select(node => node.Name));
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
    public async Task RollingRecording_KeepsGoingThroughASave_CutsItToItsWindow_AndRunsBesideARecording()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!);
        Assert.Equal("not-rolling",
            (await Assert.ThrowsAsync<GameSaveException>(() => client.SaveRollingAsync(game.Pid, temp.GetPath("none.jfr")))).Code);

        var started = await client.StartRollingAsync(game.Pid, detailed: false, 10);
        Assert.True(started.Rolling);
        Assert.Equal(("sampling", true), (started.Lua, started.HasFrames));
        await Task.Delay(3000);
        var raw = temp.GetPath("last.pzprof.jfr");
        var saved = await client.SaveRollingAsync(game.Pid, raw);
        Assert.True(saved.Rolling);
        Assert.True(saved.HasFrames);
        Assert.True((await client.StatusAsync(game.Pid)).Rolling);

        // Cut to its last second: the frames and the mod's Lua of that second, and no more.
        var output = temp.GetPath("last.pzprof");
        var exported = await client.ExportAsync(raw, output, new Dictionary<string, string> { ["mode"] = "general" }, keepLastSeconds: 1);
        Assert.InRange(exported.DurationMicroseconds, 500_000, 1_100_000);
        var recording = ProfileRecording.Load(output);
        Assert.True(recording.Frames.Length is > 5 and < 80, $"frames: {recording.Frames.Length}");
        Assert.Equal("ExampleMod", Assert.Single(ProfileAnalysis.Analyze(recording, 0, recording.Duration, recording.GameThread).LuaGroups).Key);

        // A recording asked for runs beside it, in another mode: a save still takes the rolling one, in its own mode,
        // and stopping either leaves the other.
        Assert.True((await client.StartAsync(game.Pid, temp.GetPath("asked.pzprof.jfr"), detailed: true, 60)).Recording);
        Assert.True((await client.StatusAsync(game.Pid)).Recording);
        var beside = await client.SaveRollingAsync(game.Pid, temp.GetPath("beside.pzprof.jfr"));
        Assert.Equal(("rolling", "general"), (beside.State, beside.Mode));
        Assert.True((await client.StopRollingAsync(game.Pid)).Rolling);
        Assert.True((await client.StatusAsync(game.Pid)).Recording);
        Assert.True((await client.StartRollingAsync(game.Pid, detailed: false, 10)).Rolling);
        Assert.True((await client.StopAsync(game.Pid)).Recording);
        Assert.True((await client.StatusAsync(game.Pid)).Rolling);
        Assert.True((await client.StartRollingAsync(game.Pid, detailed: true, 10)).Rolling);
        Assert.True((await client.StopRollingAsync(game.Pid)).Rolling);
        Assert.Equal("idle", (await client.StatusAsync(game.Pid)).State);
    }

    [BridgeFact]
    public async Task RollingRecording_EndsWhenTheAppThatAskedForItHasGone()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!);
        // A stand-in for the app: a process that waits until it is ended, as a crash or a kill would end the app.
        using var app = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c pause")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true })!;
        try
        {
            Assert.True((await client.StartRollingAsync(game.Pid, detailed: false, 10, ownerProcessId: app.Id)).Rolling);
            await Task.Delay(1500);
            Assert.True((await client.StatusAsync(game.Pid)).Rolling);
            app.Kill(entireProcessTree: true);
            await app.WaitForExitAsync();
            var stopped = false;
            for (var attempt = 0; attempt < 30 && !stopped; attempt++)
            {
                await Task.Delay(200);
                stopped = (await client.StatusAsync(game.Pid)).State == "idle";
            }
            Assert.True(stopped, "The game kept the rolling recording after the app had gone.");
        }
        finally { if (!app.HasExited) app.Kill(entireProcessTree: true); }
    }

    [BridgeFact]
    public async Task TheAppInAFolderNamedInKorean_StillAttaches()
    {
        using var temp = new TempDirectory();
        // Reported: the app unpacked under a Korean folder name could not attach ("... was not loaded"), as the game's
        // JVM misreads such a path for the files handed to it at attach.
        var bridge = Path.Combine(temp.Path, "한글 경로", "game-bridge");
        CopyDirectory(Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!, bridge);
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        Assert.Equal("idle", (await new GameProfileClient(bridge).StatusAsync(game.Pid)).State);
        await new GameSaveClient(bridge).RequestAsync(game.Pid, temp.Path, save: false);
    }

    private static void CopyDirectory(string source, string target)
    {
        foreach (var directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(target, Path.GetRelativePath(source, directory)));
        Directory.CreateDirectory(target);
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(target, Path.GetRelativePath(source, file)));
    }

    [BridgeFact]
    public async Task AGameWithAnOlderBootstrap_IsAskedToRestart_AndIsSentNothing()
    {
        using var temp = new TempDirectory();
        // What a bootstrap of API 10 (PZ Tools 0.2.1 and before) leaves in a game it was attached to: its endpoint and
        // its API. This build's payload cannot run under it.
        await using var game = await FakeGame.StartAsync(temp.Path, "normal", properties:
            ["pztools.bridge.control.v1=2:1:1:" + new string('0', 64), "pztools.bridge.bootstrap.api=10"]);
        var bridge = Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!;

        // A recording says restart, which the app shows as such.
        Assert.Equal("restart-required",
            (await Assert.ThrowsAsync<GameSaveException>(() => new GameProfileClient(bridge).StatusAsync(game.Pid))).Code);
        // A save falls back to the files on disk, and its reason still names the restart.
        var save = await Assert.ThrowsAsync<GameSaveException>(() => new GameSaveClient(bridge).RequestAsync(game.Pid, temp.Path, save: false));
        Assert.True(save.LinkUnavailable);
        Assert.True(GameSaveException.NamesRestart(save.Message), save.Message);
    }

    [BridgeFact]
    public async Task GameNotice_ShowsCatalogNotesOverThePlayer_OnTheGameThread_AndRefusesAnyOtherText()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!);

        Assert.True(await client.NotifyAsync(game.Pid, "ko-KR", ["saved-last:2", "next-backup:5"]));
        var notices = temp.GetPath("notices.txt");
        for (var attempt = 0; attempt < 50 && !File.Exists(notices); attempt++) await Task.Delay(100);
        var shown = Assert.Single(await File.ReadAllLinesAsync(notices)).Split('\t');
        Assert.Equal(("직전 2분 저장됨 · 다음 백업 5분 후", "Synthetic-game-thread"), (shown[1], shown[2]));

        // Only the game's own catalog: no other key, no number where a note has none, none missing where it has one.
        foreach (string[] items in new[] { new[] { "anything" }, ["backup-done:3"], ["saved-last"] })
            Assert.Equal("unsupported-protocol",
                (await Assert.ThrowsAsync<GameSaveException>(() => client.NotifyAsync(game.Pid, "en-US", items))).Code);
        Assert.Equal("unsupported-protocol",
            (await Assert.ThrowsAsync<GameSaveException>(() => client.NotifyAsync(game.Pid, "xx-XX", ["backup-done"]))).Code);
        await Assert.ThrowsAsync<ArgumentException>(() => client.NotifyAsync(game.Pid, "en-US", ["Free text\there"]));
        Assert.Single(await File.ReadAllLinesAsync(notices));
    }

    [BridgeFact]
    public async Task ProfileRecording_EndsByItselfAtItsLimit_AndIsCollectedAfterwards()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!);
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
        var client = new GameProfileClient(Environment.GetEnvironmentVariable("PZTOOLS_GAME_BRIDGE_DIR")!);
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
