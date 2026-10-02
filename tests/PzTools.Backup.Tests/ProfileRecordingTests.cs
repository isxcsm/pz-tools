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

    private static void WriteRecording(string path, string text)
    {
        using var file = File.Create(path);
        using var gzip = new GZipStream(file, CompressionMode.Compress);
        gzip.Write(Encoding.UTF8.GetBytes(text));
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
