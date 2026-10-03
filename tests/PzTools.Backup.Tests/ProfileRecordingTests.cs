using System.IO.Compression;
using System.Text;
using PzTools.Profiling;

namespace PzTools.Backup.Tests;

public sealed class ProfileRecordingTests
{
    // Fields are separated by | here and by tabs in a real file. Two frames: a 10 ms one spent in the game's own update and a 40 ms one spent mostly in a mod's Lua.
    private const string Sample = """
        PZPROF|1
        I|mode|general
        M|0|zombie.GameWindow.logic
        M|1|zombie.iso.IsoCell.update
        M|2|se.krka.kahlua.vm.KahluaThread.luaMainloop
        M|3|java.util.HashMap.get
        M|4|org.lwjgl.opengl.GL11.glDrawArrays
        K|0|1 0
        K|1|2 0
        K|2|3 2 0
        K|3|4
        LM|0|slow|workshop/123/mods/SlowMod/42/media/lua/client/Slow.lua
        LM|1|OnTick|media/lua/client/ISUI/ISGame.lua
        LM|2|helper|somewhere/odd.lua
        LK|0|0:12 1:80
        LK|1|1:81
        LK|2|2:5 0:13 1:80
        F|1010000|40000
        F|1000000|10000
        S|1005000|7|0|J
        S|1015000|7|1|J
        S|1025000|7|2|J
        S|1035000|7|1|J
        S|1045000|7|1|J
        S|1020000|9|3|N
        L|1015000|0
        L|1025000|2
        L|1035000|0
        L|1045000|1
        LH|1050000|5|4|10000
        G|1030000|2500|ZGC Minor|Allocation Rate
        P|1031000|1500|GCPhasePause|-1|Pause Mark Start
        T|7|main
        T|9|Render
        I|gameThread|7
        I|javaPeriodMicros|10000
        I|nativePeriodMicros|20000
        I|startEpochMillis|1790000000000
        """;

    [Fact]
    public void Read_RebasesAndOrdersRecords_WhateverOrderTheRecorderWroteThem()
    {
        var recording = Load(Sample);
        Assert.Equal(["main", "Render"], recording.Threads);
        Assert.Equal(0, recording.GameThread);
        Assert.Equal([new ProfileFrame(0, 10_000), new ProfileFrame(10_000, 40_000)], recording.Frames);
        Assert.Equal(5_000, recording.Samples[0].Time);
        Assert.True(recording.Samples.Zip(recording.Samples.Skip(1)).All(pair => pair.First.Time <= pair.Second.Time));
        Assert.Equal(50_000, recording.Duration);
        Assert.Equal(10_000, recording.LuaPeriod);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1790000000000), recording.StartedUtc);
        Assert.Equal(-1, Assert.Single(recording.Pauses).Thread);
    }

    [Fact]
    public void LuaPeriod_IsTheSamplersOwn_WhenLuaRunsOnlyNowAndThen()
    {
        // Ten seconds of a 10 ms sampler finding Lua on one tick in three, as for scripts that run a few milliseconds
        // a frame: the gaps between Lua samples are 30 ms, but each still stands for 10 ms.
        var lines = new List<string> { "PZPROF|1", "LM|0|tick|media/lua/client/Tick.lua", "LK|0|0:1", "F|0|10000000" };
        for (var tick = 0; tick < 1000; tick += 3) lines.Add($"L|{tick * 10_000}|0");
        for (var second = 0; second <= 10; second++) lines.Add($"LH|{second * 1_000_000}|100|33|10000");
        var recording = Load(string.Join('\n', lines));
        Assert.Equal(10_000, recording.LuaPeriod);
        // And a third of the ten seconds is what the scripts took.
        var range = ProfileAnalysis.Analyze(recording, 0, recording.Duration, -1);
        Assert.InRange(range.LuaShare, 0.30, 0.37);
    }

    [Fact]
    public void Analyze_SplitsARangeByWhereTheCodeComesFrom()
    {
        var recording = Load(Sample);
        var slow = ProfileAnalysis.Analyze(recording, 10_000, 50_000, recording.GameThread);

        Assert.Equal(4, slow.Samples);
        Assert.Equal(new ProfileFrameStatistics(1, 40, 40, 40, 40), slow.Frames);
        // Three of the four samples were inside the Lua interpreter itself, one in a Java map lookup it made.
        var interpreter = slow.Methods.Single(row => row.Name.EndsWith("luaMainloop"));
        Assert.Equal(0.75, interpreter.Self, 3);
        Assert.Equal(1.0, interpreter.Total, 3);
        Assert.Equal(1.0, slow.Methods.Single(row => row.Name == "zombie.GameWindow.logic").Total, 3);
        Assert.Equal([ProfileAnalysis.LuaRuntime, ProfileAnalysis.JavaRuntime], slow.MethodGroups.Select(group => group.Key));
        Assert.Equal(0.75, slow.MethodGroups[0].Self, 3);
        // Within its group a method's total counts the group's own samples: the interpreter was under the map lookup
        // too, but that sample ended in Java's own code, so the group's row stops at the group's 75%.
        var inGroup = Assert.Single(slow.MethodGroups[0].Rows);
        Assert.Equal((0.75, 0.75), (Math.Round(inGroup.Self, 3), Math.Round(inGroup.Total, 3)));
        Assert.Equal(0.25, Assert.Single(slow.MethodGroups[1].Rows).Total, 3);
        // A method that only called into other groups (the game loop) has no row in any group.
        Assert.DoesNotContain(slow.MethodGroups.SelectMany(group => group.Rows), row => row.Name == "zombie.GameWindow.logic");

        // Every Lua sample is 10 ms of a 40 ms range. The mod ran three of the four, once through a file of unknown origin.
        Assert.Equal(4, slow.LuaSamples);
        Assert.Equal(1.0, slow.LuaShare, 3);
        Assert.Equal(["SlowMod", ProfileAnalysis.GameOwner, ProfileAnalysis.UnknownOwner], slow.LuaGroups.Select(group => group.Key));
        Assert.Equal(0.5, slow.LuaGroups[0].Self, 3);
        Assert.Equal(2, slow.LuaGroups[0].Samples);
        var slowFunction = Assert.Single(slow.LuaGroups[0].Rows);
        Assert.Equal(("slow", 0.5, 0.75), (slowFunction.Name, Math.Round(slowFunction.Self, 3), Math.Round(slowFunction.Total, 3)));
        Assert.Equal(0.75, slow.LuaOwners.Single(row => row.Name == "SlowMod").Total, 3);
        Assert.Equal(1.0, slow.LuaOwners.Single(row => row.Name == ProfileAnalysis.GameOwner).Total, 3);

        Assert.Equal(1, slow.Collections);
        Assert.Equal(2.5, slow.CollectionPauseMilliseconds, 3);
        Assert.Equal("GCPhasePause", Assert.Single(slow.LongestPauses).Kind);

        var quick = ProfileAnalysis.Analyze(recording, 0, 10_000, recording.GameThread);
        Assert.Equal(ProfileAnalysis.GameCode, Assert.Single(quick.MethodGroups).Key);
        Assert.Equal(0, quick.LuaSamples);
        Assert.Equal(0, quick.Collections);
    }

    [Fact]
    public void TimeBreakdown_SplitsTheGameThreadsRangeIntoScriptsGameCodeCollectionsAndWaiting()
    {
        var recording = Load(Sample);
        // The slow frame: the scripts ran all of it by their sampler, but the collector's 1.5 ms pause stopped the game
        // in it, and the scripts give way to it.
        var slow = ProfileAnalysis.TimeBreakdown(ProfileAnalysis.Analyze(recording, 10_000, 50_000, recording.GameThread))!;
        Assert.Equal((0.9625, 0.0, 0.0375, 0.0), (Math.Round(slow.Scripts, 4), Math.Round(slow.GameCode, 4),
            Math.Round(slow.Collections, 4), Math.Round(slow.Waiting, 4)));
        // The quick frame was the game's own code, all of it.
        var quick = ProfileAnalysis.TimeBreakdown(ProfileAnalysis.Analyze(recording, 0, 10_000, recording.GameThread))!;
        Assert.Equal((0.0, 1.0, 0.0, 0.0), (quick.Scripts, Math.Round(quick.GameCode, 4), quick.Collections, quick.Waiting));
        // All threads together overlap in time: no breakdown.
        Assert.Null(ProfileAnalysis.TimeBreakdown(ProfileAnalysis.Analyze(recording, 0, 50_000, -1)));

        // A thread running two 10 ms samples in a 100 ms frame waited the rest.
        var idle = Load(string.Join('\n', "PZPROF|1", "M|0|zombie.GameWindow.logic", "K|0|0", "F|0|100000",
            "S|0|7|0|J", "S|10000|7|0|J", "T|7|main", "I|gameThread|7", "I|javaPeriodMicros|10000"));
        var waited = ProfileAnalysis.TimeBreakdown(ProfileAnalysis.Analyze(idle, 0, 100_000, idle.GameThread))!;
        Assert.Equal((0.0, 0.2, 0.0, 0.8), (waited.Scripts, Math.Round(waited.GameCode, 4), waited.Collections, Math.Round(waited.Waiting, 4)));
        Assert.Equal(1.0, waited.Scripts + waited.GameCode + waited.Collections + waited.Waiting, 6);
    }

    [Fact]
    public void TimeBreakdown_FindsMemoryStopsWhereTheyHappened_AndTheGameThreadsWaitsForMemory()
    {
        // A collection whose cycle began in the first 20 ms frame and paused the game 4 ms in all, in the third: 1 ms
        // and 3 ms. In the third the game thread also waited 5 ms for memory, 2 ms of it during the second pause; the
        // render thread waited too, which is not the game thread's time.
        var recording = Load(string.Join('\n', "PZPROF|1", "M|0|zombie.GameWindow.logic", "K|0|0",
            "F|0|20000", "F|20000|20000", "F|40000|20000", "S|0|7|0|J", "S|59000|7|0|J",
            "G|1000|4000|ZGC Major|Allocation Rate",
            "P|42000|1000|GCPhasePause|-1|Pause Mark Start", "P|50000|3000|GCPhasePause|-1|Pause Relocate Start",
            "P|46000|6000|ZAllocationStall|7|", "P|44000|9000|ZAllocationStall|9|",
            "T|7|main", "T|9|Render", "I|gameThread|7", "I|javaPeriodMicros|10000"));
        double Stopped(long start, long end) =>
            Math.Round(ProfileAnalysis.TimeBreakdown(ProfileAnalysis.Analyze(recording, start, end, recording.GameThread))!.Collections, 4);
        // Not on the frame the cycle began in, where its total was written.
        Assert.Equal(0.0, Stopped(0, 20_000));
        // 1 ms pause, then 46-53 ms: the stall from 46 and the second pause to 53, once.
        Assert.Equal(Math.Round(8_000 / 20_000.0, 4), Stopped(40_000, 60_000));
        // A recording from before the collector's pauses were kept still has the collections' totals.
        var older = Load(string.Join('\n', "PZPROF|1", "M|0|zombie.GameWindow.logic", "K|0|0", "F|0|20000", "S|0|7|0|J",
            "G|1000|4000|ZGC Major|Allocation Rate", "T|7|main", "I|gameThread|7", "I|javaPeriodMicros|10000"));
        Assert.Equal(0.2, ProfileAnalysis.TimeBreakdown(ProfileAnalysis.Analyze(older, 0, 20_000, older.GameThread))!.Collections, 4);
    }

    [Fact]
    public void CallTrees_FollowEachOwnersSamplesFromTheOutermostFunctionDown()
    {
        var range = ProfileAnalysis.Analyze(Load(Sample), 10_000, 50_000, 0);
        // One tree for each owner in the list.
        Assert.Equal(range.LuaGroups.Select(group => group.Key).Order(StringComparer.Ordinal), range.LuaCallTrees.Keys.Order(StringComparer.Ordinal));

        // The mod's two samples both came from the game's OnTick, which called its function: the path, not just the function.
        var mod = range.LuaCallTrees["SlowMod"];
        Assert.Equal(2, mod.Samples);
        var onTick = Assert.Single(mod.Children);
        Assert.Equal(("OnTick", 2, 0, 0.5), (onTick.Name, onTick.Samples, onTick.SelfSamples, Math.Round(onTick.Total, 3)));
        var slow = Assert.Single(onTick.Children);
        Assert.Equal(("slow", 2, 2, 0.5), (slow.Name, slow.Samples, slow.SelfSamples, Math.Round(slow.Self, 3)));
        Assert.Empty(slow.Children);

        // The sample that ended in a helper of unknown origin keeps its whole path, three deep.
        var path = range.LuaCallTrees[ProfileAnalysis.UnknownOwner];
        Assert.Equal(["OnTick", "slow", "helper"], new[] { path.Children[0], path.Children[0].Children[0], path.Children[0].Children[0].Children[0] }
            .Select(node => node.Name));
        Assert.Equal(1, path.Children[0].Children[0].Children[0].SelfSamples);
        // The outermost functions add up to the owner's own samples, as its row in the list does.
        Assert.Equal(range.LuaGroups.Single(group => group.Key == ProfileAnalysis.GameOwner).Samples,
            range.LuaCallTrees[ProfileAnalysis.GameOwner].Children.Sum(node => node.Samples));
    }

    [Fact]
    public void FunctionsIn_AddsUpATreesPaths_CountingARecursiveCallOnce()
    {
        // A third sample of the mod: slow calling itself, under OnTick.
        var recording = Load(Sample + "\nLK|3|0:1 0:2 1:80\nL|1046000|3");
        var tree = ProfileAnalysis.Analyze(recording, 10_000, 50_000, 0).LuaCallTrees["SlowMod"];
        Assert.Equal(3, tree.Samples);

        var functions = ProfileAnalysis.FunctionsIn(tree);
        // slow ended all three samples; the recursive one passed through it twice but counts once.
        Assert.Equal([("slow", 3, 3), ("OnTick", 0, 3)], functions.Select(row => (row.Name, row.SelfSamples, row.Samples)));
        // So the list's parts of the owner match the tree's: its self samples add up to the owner.
        Assert.Equal(tree.Samples, functions.Sum(row => row.SelfSamples));
    }

    [Fact]
    public void Comparison_MatchesFunctionsAcrossRecordings_ByNameAndScriptPath()
    {
        var baseline = ProfileAnalysis.Analyze(Load(Sample), 0, 50_000, 0);
        // The same mod from a local copy instead of the workshop, and one more path: OnTick calling the helper itself.
        var current = ProfileAnalysis.Analyze(
            Load(Sample.Replace("workshop/123/mods/SlowMod/42/media", "mods/SlowMod/media") + "\nLK|3|2:7 1:80\nL|1047000|3"), 0, 50_000, 0);
        Assert.Equal(ProfileAnalysis.ScriptKey("slow", "workshop/123/mods/SlowMod/42/media/lua/client/Slow.lua"),
            ProfileAnalysis.ScriptKey("slow", "mods/SlowMod/media/lua/client/Slow.lua"));
        Assert.NotEqual(ProfileAnalysis.ScriptKey("slow", "a/media/lua/client/Slow.lua"), ProfileAnalysis.ScriptKey("slow", "a/media/lua/server/Slow.lua"));

        // Root, OnTick and slow: the whole path found again.
        var mod = current.LuaCallTrees["SlowMod"];
        var matched = ProfileAnalysis.MatchCallTrees(mod, baseline.LuaCallTrees["SlowMod"]);
        Assert.Equal(3, matched.Count);
        Assert.Equal("slow", matched[mod.Children[0].Children[0]].Name);
        // OnTick, slow, helper is in both; OnTick calling the helper only in the new one.
        var unknown = current.LuaCallTrees[ProfileAnalysis.UnknownOwner];
        var paths = ProfileAnalysis.MatchCallTrees(unknown, baseline.LuaCallTrees[ProfileAnalysis.UnknownOwner]);
        var onTick = Assert.Single(unknown.Children);
        Assert.True(paths.ContainsKey(onTick.Children.Single(node => node.Name == "slow").Children[0]));
        Assert.False(paths.ContainsKey(onTick.Children.Single(node => node.Name == "helper")));

        // As parts of the range: the mod's function the same in both, the helper twice as heavy in the new one.
        var slowKey = ProfileAnalysis.ScriptKey("slow", "mods/SlowMod/media/lua/client/Slow.lua");
        Assert.Equal(ProfileAnalysis.FunctionShares(baseline.LuaCallTrees["SlowMod"])[slowKey],
            ProfileAnalysis.FunctionShares(mod)[slowKey], 6);
        // A function's part is its total: OnTick ran nothing itself, but every one of the mod's samples passed through it.
        Assert.Equal(mod.Total, ProfileAnalysis.FunctionShares(mod)[ProfileAnalysis.ScriptKey("OnTick", "media/lua/client/ISUI/ISGame.lua")], 6);
        var helperKey = ProfileAnalysis.ScriptKey("helper", "somewhere/odd.lua");
        var before = ProfileAnalysis.FunctionShares(baseline.LuaCallTrees[ProfileAnalysis.UnknownOwner])[helperKey];
        Assert.True(before > 0);
        Assert.Equal(before * 2, ProfileAnalysis.FunctionShares(unknown)[helperKey], 6);
    }

    [Fact]
    public void Read_ShortensTopLevelCodeNamedAfterAFullPath_InRecordingsThatStillHaveIt()
    {
        // Recorded before the recorder shortened such names: the full path, user folder included.
        var recording = Load(Sample + @"
            LM|3|C:\Users\someone\Zomboid\mods\Other\media\lua\client\Other.lua|mods/Other/media/lua/client/Other.lua
            LM|4|C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid/media/lua/client/ISUI/ISButton.lua|media/lua/client/ISUI/ISButton.lua");
        Assert.Equal(("Other.lua", "mods/Other/media/lua/client/Other.lua"), (recording.LuaFunctions[3].Name, recording.LuaFunctions[3].File));
        Assert.Equal("ISButton.lua", recording.LuaFunctions[4].Name);
        Assert.Equal("slow", recording.LuaFunctions[0].Name);
    }

    [Fact]
    public void OwnerTime_IsTheOwnersPartOfEachBarsFrame()
    {
        var recording = Load(Sample);
        // Two slices: the first holds both frames and draws the 40 ms one; no frame begins in the second.
        Assert.Equal([40.0, 0], ProfileAnalysis.SlowestFramePerBucket(recording, 0, 50_000, 2));
        // Of that frame, the mod's functions ran in two 10 ms Lua samples; the game's scripts in one.
        Assert.Equal([20.0, 0], ProfileAnalysis.OwnerTimePerBucket(recording, 0, 50_000, 2, java: false, "SlowMod", recording.GameThread));
        Assert.Equal([10.0, 0], ProfileAnalysis.OwnerTimePerBucket(recording, 0, 50_000, 2, java: false, ProfileAnalysis.GameOwner, recording.GameThread));
        // The interpreter ran in three of the game thread's 10 ms Java samples inside it; the render thread's sample is not the game's.
        Assert.Equal([30.0, 0], ProfileAnalysis.OwnerTimePerBucket(recording, 0, 50_000, 2, java: true, ProfileAnalysis.LuaRuntime, recording.GameThread));
        Assert.Equal(0, ProfileAnalysis.OwnerTimeIn(recording, 10_000, 50_000, java: true, ProfileAnalysis.Libraries, recording.GameThread));
    }

    [Fact]
    public void Analyze_StopsWhenNobodyWaitsForItAnyMore()
    {
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() =>
            ProfileAnalysis.Analyze(Load(Sample), 0, 50_000, -1, cancellation: cancel.Token));
    }

    [Fact]
    public void Analyze_LeavesOutThreadsOnlyWaitingInANativeCall()
    {
        // Render also waits for a connection, and in a timer reached through a foreign function call.
        var recording = Load(Sample + """

            M|5|sun.nio.ch.Net.accept
            M|6|java.lang.invoke.LambdaForm$MH.0x1.invoke
            M|7|pztools.bridge.runtime.ProfileRecorder$PreciseWait.pause
            K|4|5
            K|5|6 7
            S|1030000|9|4|N
            S|1040000|9|5|N
            """);
        var all = ProfileAnalysis.Analyze(recording, 0, 50_000, -1);
        // The same six samples and shares as without the waits: drawing in native code still counts as work.
        Assert.Equal(6, all.Samples);
        Assert.Equal(2, all.WaitingSamples);
        Assert.Equal(20.0 / 70, all.Threads.Single(row => row.Name == "Render").Self, 3);
        Assert.DoesNotContain(all.Methods, row => row.Name.Contains("accept") || row.Name.Contains("PreciseWait"));
        // The game thread did not wait.
        Assert.Equal(0, ProfileAnalysis.Analyze(recording, 0, 50_000, recording.GameThread).WaitingSamples);
    }

    [Fact]
    public void Analyze_AllThreads_WeighsEachSampleByItsOwnPeriod()
    {
        var all = ProfileAnalysis.Analyze(Load(Sample), 0, 50_000, -1);
        Assert.Equal(6, all.Samples);
        // Five Java samples of 10 ms and one native sample of 20 ms.
        Assert.Equal(20.0 / 70, all.Threads.Single(row => row.Name == "Render").Self, 3);
        Assert.Equal(20.0 / 70, all.MethodGroups.Single(group => group.Key == ProfileAnalysis.Libraries).Self, 3);
    }

    [Fact]
    public void Chart_KeepsTheSlowestFrameOfEachSlice_AndFindsTheFrameUnderAPoint()
    {
        var recording = Load(Sample);
        Assert.Equal([10, 40, 0, 0, 0], ProfileAnalysis.SlowestFramePerBucket(recording, 0, 50_000, 5));
        Assert.Equal([40], ProfileAnalysis.SlowestFramePerBucket(recording, 0, 50_000, 1));
        Assert.Equal(new ProfileFrame(10_000, 40_000), ProfileAnalysis.FrameAt(recording, 30_000));
        Assert.Equal(new ProfileFrame(0, 10_000), ProfileAnalysis.FrameAt(recording, 9_999));
        Assert.Equal(2, ProfileAnalysis.FrameStatistics(recording, 0, 50_000).Count);
    }

    [Fact]
    public void Collections_OfAFrameOrRange_CountThePausesThatTouchIt()
    {
        // One collection at 30 ms pausing 2.5 ms: inside the second frame, outside the first.
        var recording = Load(Sample);
        Assert.Equal((1, 2.5), ProfileAnalysis.CollectionsIn(recording, 10_000, 50_000));
        Assert.Equal((0, 0.0), ProfileAnalysis.CollectionsIn(recording, 0, 10_000));
        // A pause that started before the range still counts while it runs into it.
        Assert.Equal((1, 2.5), ProfileAnalysis.CollectionsIn(recording, 31_000, 32_000));
        Assert.Equal((0, 0.0), ProfileAnalysis.CollectionsIn(recording, 33_000, 50_000));
    }

    [Theory]
    [InlineData("mods/ExampleMod/media/lua/client/A.lua", "ExampleMod")]
    [InlineData("workshop/2900000000/mods/Other Mod/42/media/lua/shared/B.lua", "Other Mod")]
    [InlineData("media/lua/client/ISUI/ISPanel.lua", ProfileAnalysis.GameOwner)]
    [InlineData("stdlib.lua", ProfileAnalysis.UnknownOwner)]
    [InlineData("?", ProfileAnalysis.UnknownOwner)]
    public void OwnerOf_NamesTheModOnlyWhenThePathSaysSo(string file, string owner) =>
        Assert.Equal(owner, ProfileAnalysis.OwnerOf(file));

    [Fact]
    public void Read_RejectsForeignAndInconsistentFiles()
    {
        Assert.Throws<InvalidDataException>(() => Load("SOMETHING\t9\n"));
        Assert.Throws<InvalidDataException>(() => Load("PZPROF\t1\nT\t1\tmain\nS\t0\t1\t5\tJ\n"));
        Assert.Throws<InvalidDataException>(() => Load("PZPROF\t1\nK\t0\t3\n"));
        Assert.Throws<InvalidDataException>(() => Load("PZPROF\t1\nF\tx\t1\n"));
        var empty = Load("PZPROF\t1\nFUTURE\tfield\n");
        Assert.Empty(empty.Samples);
        Assert.Equal(0, ProfileAnalysis.Analyze(empty, 0, 0, -1).Samples);
    }

    [Fact]
    public void ImportAndExport_CopyRecordingsInAndOut_AndRefuseWhatIsNotOne()
    {
        using var temp = new TempDirectory();
        var service = new PzTools.App.Core.ProfileRecordingService(temp.GetPath("profiles"), () => null);
        var outside = temp.GetPath("from-a-friend.pzprof");
        WriteRecording(outside, "PZPROF\t1\nFUTURE\tfield\n");
        var written = new DateTime(2026, 9, 1, 12, 0, 0, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(outside, written);

        var imported = service.Import(outside);
        Assert.Equal(temp.GetPath("profiles", "from-a-friend.pzprof"), imported);
        var listed = Assert.Single(service.List());
        Assert.Equal((imported, "from-a-friend"), (listed.Path, listed.Name));
        // The list shows when it was recorded, not when it was brought in.
        Assert.Equal(written, listed.CreatedUtc.UtcDateTime);
        // Importing the same name again keeps both; importing a listed file changes nothing.
        Assert.Equal(temp.GetPath("profiles", "from-a-friend-2.pzprof"), service.Import(outside));
        Assert.Equal(imported, service.Import(imported));

        var saved = temp.GetPath("elsewhere", "copy.pzprof");
        Directory.CreateDirectory(Path.GetDirectoryName(saved)!);
        service.Export(imported, saved);
        Assert.Equal(File.ReadAllBytes(imported), File.ReadAllBytes(saved));
        Assert.Throws<ArgumentException>(() => service.Export(saved, temp.GetPath("other.pzprof")));

        var broken = temp.GetPath("broken.pzprof");
        File.WriteAllText(broken, "not a recording");
        Assert.ThrowsAny<Exception>(() => service.Import(broken));
        Assert.Throws<InvalidDataException>(() => service.Import(temp.GetPath("notes.txt")));
        Assert.Equal(2, service.List().Count);
    }

    [Theory]
    [InlineData(0, "profile-game-not-running")]
    [InlineData(2, "profile-multiple-games")]
    public async Task Record_WithoutExactlyOneGame_StartsNoWorkerAndLeavesNoRun(int games, string error)
    {
        using var temp = new TempDirectory();
        // No coordinator: reaching it would throw, so a result proves no worker was asked for.
        var service = new PzTools.App.Core.ProfileRecordingService(temp.GetPath("profiles"), () => null, () => games);
        var (path, result) = await service.RecordAsync(detailed: false);
        Assert.Null(path);
        Assert.Equal((0L, error), (result.RunIndex, result.Error));
        Assert.Equal(PzTools.App.Core.ProfileSessionState.Idle, service.Session.State);
        Assert.Equal("ProfileError." + (games == 0 ? "GameNotRunning" : "MultipleGames"),
            PzTools.App.Core.ProfileRecordingService.ErrorKey(result));
    }

    [Fact]
    public async Task Recordings_AreListedByWhatTheyAre_ReadOnce_AndRenamedAsFiles()
    {
        using var temp = new TempDirectory();
        var service = new PzTools.App.Core.ProfileRecordingService(temp.GetPath("profiles"), () => null);
        Directory.CreateDirectory(service.Directory);
        var path = Path.Combine(service.Directory, "profile-20261002-154213.pzprof");
        await File.WriteAllBytesAsync(path, Compress(Sample + "\nI|endedBy|rolling\nI|durationMicros|120000000"));

        // Listed by its time until read; read once, in the background, and kept.
        var file = Assert.Single(service.List());
        Assert.Equal((false, (ProfileRecordingSummary?)null), (file.Named, file.Summary));
        Assert.True(await service.FillSummariesAsync());
        Assert.Equal(new ProfileRecordingSummary(true, false, 120_000_000), Assert.Single(service.List()).Summary);
        Assert.False(await service.FillSummariesAsync());
        var reopened = new PzTools.App.Core.ProfileRecordingService(temp.GetPath("profiles"), () => null);
        Assert.NotNull(Assert.Single(reopened.List()).Summary);

        // The name is the file's; what a file name cannot hold is replaced, and what it is goes along.
        var renamed = service.Rename(path, "  mod A: after?  ");
        Assert.Equal(Path.Combine(service.Directory, "mod A_ after_.pzprof"), renamed);
        file = Assert.Single(service.List());
        Assert.True(file.Named);
        Assert.Equal(new ProfileRecordingSummary(true, false, 120_000_000), file.Summary);
        // A name already taken gets a number.
        var other = Path.Combine(service.Directory, "other.pzprof");
        File.Copy(renamed, other);
        Assert.Equal(Path.Combine(service.Directory, "mod A_ after_ (2).pzprof"), service.Rename(other, "mod A: after?"));
        // Emptied, it takes back a saved name of its own time; only recordings in the folder are renamed.
        var back = service.Rename(renamed, "");
        Assert.True(PzTools.App.Core.ProfileRecordingService.IsAutomaticName(Path.GetFileNameWithoutExtension(back)));
        Assert.Equal(back, service.Rename(back, " "));
        Assert.Throws<ArgumentException>(() => service.Rename(temp.GetPath("elsewhere.pzprof"), "x"));
        Assert.False(PzTools.App.Core.ProfileRecordingService.IsAutomaticName("profile-2026"));
    }

    [Fact]
    public async Task Rolling_WithoutAGame_WaitsForOne_AndSavesNothing()
    {
        using var temp = new TempDirectory();
        var games = 0;
        // No coordinator: reaching it would throw, so a result proves no worker was asked for.
        var service = new PzTools.App.Core.ProfileRecordingService(temp.GetPath("profiles"), () => null, () => games);
        Assert.Null(await service.StartRollingAsync(detailed: true));
        Assert.Equal(new PzTools.App.Core.ProfileRolling(Wanted: true, Detailed: true), service.Rolling);
        service.ApplyRolling(enabled: true, detailed: false, minutes: 2);
        Assert.False(service.Rolling.Detailed);

        var (path, result) = await service.SaveRollingAsync();
        Assert.Null(path);
        Assert.Equal((0L, "profile-game-not-running"), (result.RunIndex, result.Error));
        Assert.False(service.Rolling.Saving);

        // Nothing was armed, so stopping asks the game nothing either.
        await service.StopRollingAsync();
        Assert.Equal(new PzTools.App.Core.ProfileRolling(), service.Rolling with { Detailed = false });
        Assert.Equal("ProfileError.NotRolling", PzTools.App.Core.ProfileRecordingService.ErrorKey("profile-not-rolling"));
        Assert.Equal("ProfileError.Busy", PzTools.App.Core.ProfileRecordingService.ErrorKey("profile-already-recording"));
    }

    [Theory]
    [InlineData("java.io.IOException: Restart the game to use the updated bridge; no save request was sent", "profile-restart-required", "ProfileError.Restart")]
    [InlineData("java.io.IOException: Bootstrap is incompatible; restart the game with matching app/workers", "profile-restart-required", "ProfileError.Restart")]
    [InlineData("com.sun.tools.attach.AttachNotSupportedException: Unable to open socket file", "profile-attach-failed", "ProfileError.Link")]
    public void AttachRefusals_SayRestartWhenTheGameRunsABootstrapThisBuildCannotUse(string helperOutput, string error, string key)
    {
        // What the recording worker reports for the attach helper's words, and what the card then says.
        var code = "profile-" + (PzTools.GameBridge.GameSaveException.NamesRestart(helperOutput) ? "restart-required" : "attach-failed");
        Assert.Equal(error, code);
        Assert.Equal(key, PzTools.App.Core.ProfileRecordingService.ErrorKey(code));
    }

    /// <summary>
    /// Twenty seconds of a recording whose samples came slower than asked (Java every 12 ms of a 10 ms request, the Lua
    /// sampler's ticks 12.5 ms apart), on times that start late, with memory, collections, pauses and allocations.
    /// </summary>
    private static string LongRecording()
    {
        const long raw = 5_000_000;
        var lines = new List<string>
        {
            "PZPROF|1", "I|mode|general", "I|endedBy|rolling", "I|durationMicros|20000000",
            "M|0|zombie.GameWindow.logic", "M|1|zombie.iso.IsoCell.update", "M|2|se.krka.kahlua.vm.KahluaThread.luaMainloop",
            "M|3|org.lwjgl.opengl.GL11.glDrawArrays", "M|4|org.lwjgl.opengl.GL11.glDrawElements", "K|0|1 0", "K|1|2 0", "K|2|3",
            "K|3|4", "LM|0|slow|workshop/123/mods/SlowMod/42/media/lua/client/Slow.lua", "LM|1|OnTick|media/lua/client/ISUI/ISGame.lua",
            "LM|2|early|media/lua/client/Early.lua", "LK|0|0:12 1:80", "LK|1|1:81", "LK|2|2:3 1:80",
        };
        for (long time = 0, index = 0; time < 20_000_000; time += 20_000, index++)
            lines.Add($"F|{raw + time}|{15_000 + index % 7 * 1_000}");
        // A third of the game thread's samples in Lua, the rest in the game's own update.
        for (long time = 0, index = 0; time < 20_000_000; time += 12_000, index++)
        {
            var stack = index % 3 == 0 ? 1 : 0;
            lines.Add($"S|{raw + time}|7|{stack}|J");
        }
        // The first second draws one way and runs a script of its own, the rest not: a range after it uses neither.
        for (long time = 3_000; time < 20_000_000; time += 25_000) lines.Add($"S|{raw + time}|9|{(time < 1_000_000 ? 2 : 3)}|N");
        for (long time = 1_000, index = 0; time < 20_000_000; time += 37_500, index++)
        {
            var stack = time < 1_000_000 && index % 2 == 0 ? 2 : index % 4 == 0 ? 1 : 0;
            lines.Add($"L|{raw + time}|{stack}");
            lines.Add($"LA|{raw + time}|{1_000 + index % 5 * 100}");
        }
        for (long second = 0; second <= 20; second++)
        {
            lines.Add($"LH|{raw + second * 1_000_000}|80|27|10000");
            lines.Add($"GA|{raw + second * 1_000_000}|{5_000_000 + second}");
        }
        for (long time = 0; time < 20_000_000; time += 250_000) lines.Add($"H|{raw + time}|{400_000_000 + time}|800000000|900000000");
        for (long time = 0; time < 20_000_000; time += 500_000) lines.Add($"V|{raw + time}|{100_000_000 + time}|5000");
        for (long time = 400_000; time < 20_000_000; time += 1_300_000)
        {
            lines.Add($"G|{raw + time}|{2_500 + time % 3_000}|ZGC Minor|Allocation Rate");
            lines.Add($"P|{raw + time + 700}|{1_500 + time % 900}|GCPhasePause|-1|Pause Mark Start");
        }
        lines.AddRange(["T|7|main", "T|9|Render", "I|gameThread|7", "I|javaPeriodMicros|10000", "I|nativePeriodMicros|20000",
            "I|startEpochMillis|1790000000000"]);
        return string.Join('\n', lines);
    }

    // What a range shows, in numbers: the analysis of either thread choice, the frames, collections and memory.
    private static string Figures(ProfileRecording recording, long start, long end)
    {
        static string Rows(IEnumerable<ProfileShare> rows) =>
            string.Join(";", rows.Select(row => $"{row.Name}={row.Self:0.000000}/{row.Total:0.000000}/{row.Samples}"));
        var text = new StringBuilder();
        foreach (var thread in new[] { recording.GameThread, -1 })
        {
            var range = ProfileAnalysis.Analyze(recording, start, end, thread);
            text.AppendLine($"{range.Frames} {range.Samples} {range.WaitingSamples} {range.RunningShare:0.000000} {range.LuaShare:0.000000} {range.LuaSamples}");
            text.AppendLine(Rows(range.Methods));
            text.AppendLine(string.Join("|", range.MethodGroups.Select(group => $"{group.Key}:{group.Self:0.000000}:{Rows(group.Rows)}")));
            text.AppendLine(Rows(range.Threads));
            text.AppendLine(Rows(range.LuaFunctions) + " " + Rows(range.LuaOwners));
            text.AppendLine(string.Join("|", range.LuaGroups.Select(group => $"{group.Key}:{group.Self:0.000000}:{Rows(group.Rows)}")));
            text.AppendLine($"{range.Collections} {range.CollectionPauseMilliseconds:0.000} {range.MemoryStopMilliseconds:0.000} {range.LuaAllocated} {range.GameThreadAllocated}");
            text.AppendLine(string.Join(";", range.LongestPauses.Select(pause => $"{pause.Time - start}/{pause.Duration}/{pause.Kind}")));
            text.AppendLine(string.Join("|", range.LuaAllocationGroups.Select(group => $"{group.Key}:{group.Self}:{group.Samples}")));
        }
        text.AppendLine(ProfileAnalysis.MemoryPeaksIn(recording, start, end).ToString());
        return text.ToString();
    }

    [Theory]
    [InlineData(2_000_000, 9_000_000)]
    // A third of a second: too short to measure what a sample stands for again.
    [InlineData(3_210_000, 3_530_000)]
    [InlineData(0, 20_000_000)]
    public void SavedRange_ShowsWhatTheRangeShowedInItsRecording(long start, long end)
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("whole.pzprof");
        File.WriteAllBytes(source, Compress(LongRecording()));
        var whole = ProfileRecording.Load(source);
        var target = temp.GetPath("part.pzprof");
        ProfileTrim.Save(whole, source, target, start, end);
        var part = ProfileRecording.Load(target);

        end = Math.Min(end, whole.Duration);
        Assert.Equal(end - start, part.Duration);
        Assert.Equal((whole.JavaPeriod, whole.NativePeriod, whole.LuaPeriod), (part.JavaPeriod, part.NativePeriod, part.LuaPeriod));
        // The figures are the range's, as its own recording.
        Assert.Equal(Figures(whole, start, end), Figures(part, 0, part.Duration));
        // And a range of the range is the same range of the whole.
        Assert.Equal(Figures(whole, start + 100_000, start + 200_000), Figures(part, 100_000, 200_000));
        // Listed as a recording of its length, not as the game's last minutes.
        var summary = ProfileRecording.ReadSummary(target);
        Assert.Equal(new ProfileRecordingSummary(false, false, end - start), summary);
        // What only the rest used is left out, the rest numbered again.
        var early = start < 1_000_000;
        Assert.Equal(early, part.Methods.Contains("org.lwjgl.opengl.GL11.glDrawArrays"));
        Assert.Equal(early, part.LuaFunctions.Any(function => function.Name == "early"));
        Assert.Equal(early ? 5 : 4, part.Methods.Count);
        Assert.Equal(early ? 4 : 3, part.Stacks.Count);
        Assert.Equal(whole.StartedUtc, part.StartedUtc);
        Assert.False(File.Exists(target + ".tmp"));
    }

    [Fact]
    public void SavedRange_IsMeasuredLikeAnyOtherRecording_ByAnOlderReader()
    {
        // A reader that predates saved ranges skips the lines that say what it is, and still reads the samples kept.
        using var temp = new TempDirectory();
        var source = temp.GetPath("whole.pzprof");
        File.WriteAllBytes(source, Compress(LongRecording()));
        var whole = ProfileRecording.Load(source);
        ProfileTrim.Save(whole, source, temp.GetPath("part.pzprof"), 2_000_000, 9_000_000);
        using var file = File.OpenRead(temp.GetPath("part.pzprof"));
        using var gzip = new GZipStream(file, CompressionMode.Decompress);
        var text = new StreamReader(gzip).ReadToEnd();
        var older = Load(string.Join('\n', text.Split('\n').Where(line => !line.Contains("rangeFromMicros") && !line.Contains("rangeToMicros")
            && !line.Contains("EffectiveMicros"))).Replace('\t', '|'));
        // Its span is then what it kept, within a frame of the range.
        Assert.InRange(older.Duration, 6_950_000, 7_050_000);
        Assert.Equal(ProfileAnalysis.Analyze(whole, 2_000_000, 9_000_000, 0).Samples, ProfileAnalysis.Analyze(older, 0, older.Duration + 1, 0).Samples);
    }

    [Fact]
    public async Task SavedRange_JoinsTheRecordings_UnderItsOwnName()
    {
        using var temp = new TempDirectory();
        var service = new PzTools.App.Core.ProfileRecordingService(temp.GetPath("profiles"), () => null);
        Directory.CreateDirectory(service.Directory);
        var path = Path.Combine(service.Directory, "mod A.pzprof");
        await File.WriteAllBytesAsync(path, Compress(LongRecording()));
        var whole = ProfileRecording.Load(path);

        var saved = service.SaveRange(path, whole, 1_000_000, 3_000_000, "mod A (1–3 s)");
        Assert.Equal(Path.Combine(service.Directory, "mod A (1–3 s).pzprof"), saved);
        Assert.Equal(Path.Combine(service.Directory, "mod A (1–3 s) (2).pzprof"),
            service.SaveRange(path, whole, 1_000_000, 3_000_000, "mod A (1–3 s)"));
        Assert.True(await service.FillSummariesAsync());
        Assert.Equal(2_000_000, service.List().Single(file => file.Path == saved).Summary!.DurationMicros);
        // A range of nothing, or of a recording outside the folder, is refused and leaves nothing behind.
        Assert.Throws<ArgumentException>(() => service.SaveRange(path, whole, 3_000_000, 3_000_000, "empty"));
        Assert.Throws<ArgumentException>(() => service.SaveRange(temp.GetPath("elsewhere.pzprof"), whole, 0, 1, "x"));
        Assert.Equal(3, Directory.GetFiles(service.Directory).Length);
    }

    private static void WriteRecording(string path, string text)
    {
        using var file = File.Create(path);
        using var gzip = new GZipStream(file, CompressionMode.Compress);
        gzip.Write(Encoding.UTF8.GetBytes(text));
    }

    [Fact]
    public void Memory_HeapFromTheGameAndVideoMemoryAddedAfterwards_ShareTheRecordingsTimeScale()
    {
        // Heap readings as the game writes them; video memory as the worker adds it once the file exists.
        var heapLines = "\nH|1005000|400000000|600000000|900000000\nH|1030000|700000000|800000000|900000000\nH|1900000|1|1|1";
        var path = Path.Combine(Path.GetTempPath(), $"pztools-memory-{Guid.NewGuid():N}{ProfileRecording.Extension}");
        try
        {
            File.WriteAllBytes(path, Compress(Sample + heapLines));
            var start = DateTimeOffset.FromUnixTimeMilliseconds(1790000000000);
            // The recording's first sample is 1.005 s after its first event, so these land at 15 ms and 45 ms.
            Assert.Equal(2, ProfileVideoMemory.Append(path, [
                new(start.AddMilliseconds(1015), 2_000_000_000, 40_000_000),
                new(start.AddMilliseconds(1045), 2_500_000_000, 41_000_000)]));
            var recording = ProfileRecording.Load(path);

            // The reading past the recording's end is left out rather than stretching it.
            Assert.Equal([(5_000L, 400_000_000L), (30_000L, 700_000_000L)], recording.Heap.Select(item => (item.Time, item.Used)));
            Assert.Equal([(15_000L, 2_000_000_000L), (45_000L, 2_500_000_000L)], recording.VideoMemory.Select(item => (item.Time, item.Dedicated)));
            Assert.Equal(50_000, recording.Duration);

            Assert.Equal((700_000_000L, 2_500_000_000L), ProfileAnalysis.MemoryPeaksIn(recording, 0, 50_000));
            Assert.Equal((400_000_000L, (long?)null), ProfileAnalysis.MemoryPeaksIn(recording, 0, 10_000));
            var (heap, video) = ProfileAnalysis.MemoryAt(recording, 40_000);
            Assert.Equal((700_000_000L, 2_000_000_000L), (heap!.Value.Used, video!.Value.Dedicated));
            Assert.Null(ProfileAnalysis.MemoryAt(recording, 10_000).VideoMemory);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Memory_IsAbsentFromRecordingsMadeBeforeIt()
    {
        var recording = Load(Sample);
        Assert.Empty(recording.Heap);
        Assert.Empty(recording.VideoMemory);
        Assert.Equal(((long?)null, (long?)null), ProfileAnalysis.MemoryPeaksIn(recording, 0, 50_000));
    }

    [Fact]
    public void Allocations_GoToTheFunctionsEachLuaSampleFound_AndTheirMods()
    {
        // What the game thread allocated before each Lua sample, and once for the whole thread.
        var recording = Load(Sample + "\nLA|1015000|1000\nLA|1025000|3000\nLA|1035000|5000\nLA|1045000|200\nGA|1050000|20000");
        Assert.True(recording.HasLuaAllocations);
        Assert.Equal([1000L, 3000, 5000, 200], recording.LuaSamples.Select(sample => sample.Allocated));

        var range = ProfileAnalysis.Analyze(recording, 10_000, 50_000, recording.GameThread);
        Assert.Equal(9200, range.LuaAllocated);
        // Each sample's bytes go to the innermost function's mod, as its time does.
        Assert.Equal([("SlowMod", 6000L, 2), (ProfileAnalysis.UnknownOwner, 3000L, 1), (ProfileAnalysis.GameOwner, 200L, 1)],
            range.LuaAllocationGroups.Select(group => (group.Key, group.Self, group.Samples)));
        var slow = Assert.Single(range.LuaAllocationGroups[0].Rows);
        Assert.Equal(("slow", 6000L, 9000L), (slow.Name, slow.Self, slow.Total));
        Assert.Equal(9200, range.LuaAllocationGroups[2].Rows.Single(row => row.Name == "OnTick").Total);
        // The thread's one reading covers the second before it, of which the range holds 40 ms.
        Assert.Equal(800, range.GameThreadAllocated);
        // In the call trees each path carries its samples' bytes down to the function they ended in.
        var unknown = range.LuaCallTrees[ProfileAnalysis.UnknownOwner];
        Assert.Equal((3000L, 0L), (unknown.Children[0].AllocatedTotal, unknown.Children[0].AllocatedSelf));
        Assert.Equal(3000, unknown.Children[0].Children[0].Children[0].AllocatedSelf);
        Assert.Equal(6000, range.LuaCallTrees["SlowMod"].Children[0].Children[0].AllocatedSelf);

        var before = ProfileAnalysis.Analyze(recording, 0, 20_000, recording.GameThread);
        Assert.Equal(1000, before.LuaAllocated);

        // Over time, in two slices of 25 ms: the mod's samples at 15 ms and 35 ms; the game's at 45 ms.
        Assert.Equal([1000L, 5000], ProfileAnalysis.OwnerAllocationPerBucket(recording, 0, 50_000, 2, "SlowMod"));
        Assert.Equal([0L, 200], ProfileAnalysis.OwnerAllocationPerBucket(recording, 0, 50_000, 2, ProfileAnalysis.GameOwner));
        Assert.Equal([0L, 0], ProfileAnalysis.OwnerAllocationPerBucket(Load(Sample), 0, 50_000, 2, "SlowMod"));
    }

    [Fact]
    public void LinesIn_SplitsAFunctionByItsLines_ForTheOwnersSamplesOnly()
    {
        // Two more samples, in recursions: slow at 12 called by slow at 14, and by slow at 12 itself.
        var recording = Load(Sample + "\nLK|3|0:12 0:14 1:80\nL|1048000|3\nLK|4|0:12 0:12 1:80\nL|1049000|4"
            + "\nLA|1015000|1000\nLA|1025000|3000\nLA|1035000|5000\nLA|1045000|200\nLA|1048000|700");
        // The mod's samples in slow: twice at 12 on their own, once at 12 under itself at 14, once under itself at 12.
        // Each line the sample passed counts it once, and the innermost runs it: 14 only called, and the lines' self
        // samples add up to slow's own.
        Assert.Equal([(12, 4, 4, 6700L, 6700L), (14, 0, 1, 0L, 700L)],
            LinesIn(recording, 0, 50_000, "SlowMod", 0)
                .Select(line => (line.Line, line.SelfSamples, line.Samples, line.AllocatedSelf, line.AllocatedTotal)));
        var range = ProfileAnalysis.Analyze(recording, 0, 50_000, recording.GameThread);
        Assert.Equal(range.LuaGroups.Single(group => group.Key == "SlowMod").Samples,
            LinesIn(recording, 0, 50_000, "SlowMod", 0).Sum(line => line.SelfSamples));
        // The analysis counts the same lines for every owner's functions as it goes.
        Assert.Equal(LinesIn(recording, 0, 50_000, "SlowMod", 0), range.LuaLines["SlowMod"][0]);
        Assert.Equal(LinesIn(recording, 0, 50_000, ProfileAnalysis.GameOwner, 1), range.LuaLines[ProfileAnalysis.GameOwner][1]);
        // In the tree each node has its own frame's lines, which add up to the node: OnTick at 80; slow at 12 (twice on
        // its own, once calling itself) and 14; the inner slow at 12.
        var onTick = Assert.Single(range.LuaCallTrees["SlowMod"].Children);
        Assert.Equal([(80, 0, 4)], onTick.Lines.Select(line => (line.Line, line.SelfSamples, line.Samples)));
        var slow = Assert.Single(onTick.Children);
        Assert.Equal([(12, 2, 3), (14, 0, 1)], slow.Lines.Select(line => (line.Line, line.SelfSamples, line.Samples)));
        Assert.Equal([(12, 2, 2)], Assert.Single(slow.Children).Lines.Select(line => (line.Line, line.SelfSamples, line.Samples)));
        Assert.Empty(range.LuaCallTrees["SlowMod"].Lines);
        // And where the function above called each: OnTick is outermost; slow was called at OnTick's 80; the inner slow
        // once at 14 and once at 12, the lower line first when they tie.
        Assert.Equal((0, 80, 12), (onTick.CalledFromLine, slow.CalledFromLine, Assert.Single(slow.Children).CalledFromLine));
        // slow called helper at 13, a sample the unknown owner's: counted there, as a total only.
        Assert.Equal([(13, 0, 1)], LinesIn(recording, 0, 50_000, ProfileAnalysis.UnknownOwner, 0)
            .Select(line => (line.Line, line.SelfSamples, line.Samples)));
        // OnTick in the game's samples only: at 81 on its own; its calls at 80 ended in other owners.
        Assert.Equal([(81, 1, 1)], LinesIn(recording, 0, 50_000, ProfileAnalysis.GameOwner, 1)
            .Select(line => (line.Line, line.SelfSamples, line.Samples)));
        // Only the range's samples.
        Assert.Equal(1, LinesIn(recording, 0, 20_000, "SlowMod", 0).Single().Samples);
    }

    [Fact]
    public void Allocations_AreAbsentFromRecordingsMadeBeforeThem()
    {
        var recording = Load(Sample);
        Assert.False(recording.HasLuaAllocations);
        Assert.All(recording.LuaSamples, sample => Assert.Equal(-1, sample.Allocated));
        var range = ProfileAnalysis.Analyze(recording, 0, 50_000, recording.GameThread);
        Assert.Empty(range.LuaAllocationGroups);
        Assert.Equal(0, range.LuaAllocated);
        Assert.Null(range.GameThreadAllocated);
    }

    private static byte[] Compress(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace('|', '\t').Split('\n').Select(line => line.TrimStart(' '));
        using var buffer = new MemoryStream();
        using (var gzip = new GZipStream(buffer, CompressionMode.Compress, leaveOpen: true))
            gzip.Write(Encoding.UTF8.GetBytes(string.Join('\n', lines)));
        return buffer.ToArray();
    }

    /// <summary>
    /// An owner's lines of one function counted sample by sample, apart from the analysis, to check its figures
    /// against: each line a function was at counts a sample once, a recursion passing it again included, and the
    /// innermost frame is the line being run.
    /// </summary>
    private static IReadOnlyList<ProfileLineTotal> LinesIn(ProfileRecording recording, long start, long end, string owner, int function)
    {
        var lines = new Dictionary<int, (int Self, int Samples, long AllocatedSelf, long AllocatedTotal)>();
        foreach (var sample in recording.LuaSamples.Where(sample => sample.Time >= start && sample.Time < end))
        {
            var stack = recording.LuaStacks[sample.Stack];
            if (stack.Length == 0 || !ProfileAnalysis.OwnerOf(recording.LuaFunctions[stack[0].Function].File)
                    .Equals(owner, StringComparison.OrdinalIgnoreCase)) continue;
            var seen = new HashSet<(int, int)>();
            var bytes = Math.Max(0, sample.Allocated);
            for (var depth = 0; depth < stack.Length; depth++)
            {
                var frame = stack[depth];
                if (!seen.Add((frame.Function, frame.Line)) || frame.Function != function) continue;
                var count = lines.GetValueOrDefault(frame.Line);
                lines[frame.Line] = (count.Self + (depth == 0 ? 1 : 0), count.Samples + 1,
                    count.AllocatedSelf + (depth == 0 ? bytes : 0), count.AllocatedTotal + bytes);
            }
        }
        return lines.Select(item => new ProfileLineTotal(item.Key, item.Value.Self, item.Value.Samples, item.Value.AllocatedSelf, item.Value.AllocatedTotal))
            .OrderByDescending(line => line.Samples).ThenByDescending(line => line.SelfSamples).ThenBy(line => line.Line).ToArray();
    }

    private static ProfileRecording Load(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace('|', '\t').Split('\n').Select(line => line.TrimStart(' '));
        using var buffer = new MemoryStream();
        using (var gzip = new GZipStream(buffer, CompressionMode.Compress, leaveOpen: true))
            gzip.Write(Encoding.UTF8.GetBytes(string.Join('\n', lines)));
        buffer.Position = 0;
        return ProfileRecording.Read(buffer);
    }
}
