using PzTools.App.Core;
using PzTools.Profiling;

namespace PzTools.Backup.Tests;

/// <summary>The game's memory is changed in its own launcher file, one option at a time, and found again after an update.</summary>
public sealed class GameMemoryTests
{
    // The launcher file of Build 42, as Steam installs it (tabs, LF).
    private const string Shipped = "{\n\t\"mainClass\": \"zombie/gameStates/MainScreenState\",\n\t\"classpath\": [\n\t\t\".\",\n\t\t\"projectzomboid.jar\"\n\t],\n"
        + "\t\"vmArgs\": [\n\t\t\"-Djava.awt.headless=true\",\n\t\t\"--enable-native-access=ALL-UNNAMED\",\n\t\t\"-Xmx3072m\",\n"
        + "\t\t\"-Dzomboid.steam=1\",\n\t\t\"-XX:-OmitStackTraceInFastThrow\"\n\t],\n"
        + "\t\"windows\": {\n\t\t\"10.0.17134\": {\n\t\t\t\"vmArgs\": [\n\t\t\t\t\"-XX:+UseZGC\"\n\t\t\t]\n\t\t}\n\t}\n}\n";

    private const long Gigabyte = 1024L * 1024 * 1024;

    [Fact]
    public void Rewrite_ChangesOnlyTheHeapOptions_AndPutsTheStartingOneUnderTheMaximum()
    {
        var applied = GameMemory.Rewrite(Shipped, 8192, 8192);
        Assert.Equal(Shipped.Replace("\t\t\"-Xmx3072m\",\n", "\t\t\"-Xmx8192m\",\n\t\t\"-Xms8192m\",\n"), applied);
        Assert.Equal((8192, 8192), GameMemory.ReadHeap(applied));
        // Changed again in place, then taken back out to the shipped file, character for character.
        Assert.Equal((6144, 6144), GameMemory.ReadHeap(GameMemory.Rewrite(applied, 6144, 6144)));
        Assert.Equal(Shipped, GameMemory.Rewrite(applied, 3072, null));
    }

    [Fact]
    public void Rewrite_KeepsTheFilesLineEndings_AndAListsLastItem()
    {
        var crlf = Shipped.Replace("\n", "\r\n");
        Assert.Equal(crlf.Replace("\"-Xmx3072m\",\r\n", "\"-Xmx4096m\",\r\n\t\t\"-Xms4096m\",\r\n"), GameMemory.Rewrite(crlf, 4096, 4096));
        // The maximum last in the list: the starting heap follows it, and leaves again with its comma.
        var last = "{\n  \"vmArgs\": [\n    \"-Dx=1\",\n    \"-Xmx3072m\"\n  ]\n}";
        var applied = GameMemory.Rewrite(last, 4096, 4096);
        Assert.Equal("{\n  \"vmArgs\": [\n    \"-Dx=1\",\n    \"-Xmx4096m\",\n    \"-Xms4096m\"\n  ]\n}", applied);
        Assert.Equal(last, GameMemory.Rewrite(applied, 3072, null));
    }

    [Theory]
    [InlineData("{\"vmArgs\": [\"-Dx=1\"]}")]                                   // no maximum
    [InlineData("{\"vmArgs\": [\"-Xmx3g\", \"-Xmx4g\"]}")]                       // two
    [InlineData("{\"classpath\": [\"-Xmx3g\"]}")]                               // not in the list the launcher takes
    [InlineData("{\"vmArgs\": [\"-Xmx3g\"], \"windows\": {\"10\": {\"vmArgs\": [\"-Xmx2g\"]}}}")] // another might win
    [InlineData("not json")]
    public void AFileNotAsExpected_IsLeftAlone(string json)
    {
        Assert.ThrowsAny<Exception>(() => GameMemory.Rewrite(json, 4096, 4096));
    }

    [Fact]
    public void ReadHeap_ReadsEveryUnit()
    {
        Assert.Equal((3072, (int?)null), GameMemory.ReadHeap("{\"vmArgs\": [\"-Xmx3g\"]}"));
        Assert.Equal((2048, 1024), GameMemory.ReadHeap("{\"vmArgs\": [\"-Xmx2097152k\", \"-Xms1024M\"]}"));
    }

    [Theory]
    [InlineData(8, new[] { 4096 }, 0)]
    [InlineData(16, new[] { 4096, 6144, 8192 }, 6144)]
    [InlineData(32, new[] { 4096, 6144, 8192, 12288, 16384 }, 8192)]
    [InlineData(64, new[] { 4096, 6144, 8192, 12288, 16384, 24576, 32768 }, 8192)]
    [InlineData(4, new int[0], 0)]
    public void Choices_AreUpToHalfThisPCsMemory(int gigabytes, int[] expected, int recommended)
    {
        // Windows reports a little under what is fitted.
        var choices = GameMemory.ChoicesFor(gigabytes * Gigabyte - 80 * 1024 * 1024);
        Assert.Equal(expected, choices.Select(choice => choice.Megabytes));
        Assert.Equal(recommended, choices.SingleOrDefault(choice => choice.Recommended)?.Megabytes ?? 0);
    }

    [Fact]
    public async Task AChoice_IsApplied_NoticedWhenAnUpdatePutsTheGamesOwnBack_AndGivenBack()
    {
        using var temp = new TempDirectory();
        var game = temp.GetPath("ProjectZomboid");
        Directory.CreateDirectory(game);
        var file = Path.Combine(game, GameMemory.ConfigFileName);
        File.WriteAllText(file, Shipped);
        var memory = new GameMemory(temp.GetPath("data", "game-memory.json"), () => file, 32 * Gigabyte);
        int changes = 0;
        memory.Changed += () => changes++;

        await memory.RefreshAsync();
        Assert.Equal(new GameMemoryState(GameMemoryStatus.Default, file, 3072, 3072), memory.State);
        await memory.ApplyAsync(8192);
        Assert.Equal(new GameMemoryState(GameMemoryStatus.Applied, file, 8192, 3072, 8192), memory.State);
        Assert.Equal((8192, 8192), GameMemory.ReadHeap(File.ReadAllText(file)));
        // The shipped file is kept beside the app's state, once.
        Assert.Equal(Shipped, File.ReadAllText(temp.GetPath("data", "game-memory-original.json")));

        // A game update writes its own file back: the choice stands, and the file is told apart from it.
        File.WriteAllText(file, Shipped.Replace("-Xmx3072m", "-Xmx4096m"));
        var later = new GameMemory(temp.GetPath("data", "game-memory.json"), () => null, 32 * Gigabyte);
        await later.RefreshAsync();
        Assert.Equal(new GameMemoryState(GameMemoryStatus.Reverted, file, 4096, 4096, 8192), later.State);
        // Applied again; the game's own heap is now the updated one, given back as it is.
        await later.ApplyAsync(8192);
        Assert.Equal(GameMemoryStatus.Applied, later.State.Status);
        Assert.Equal(4096, later.State.DefaultMegabytes);
        await later.ApplyAsync(null);
        Assert.Equal(Shipped.Replace("-Xmx3072m", "-Xmx4096m"), File.ReadAllText(file));
        Assert.Equal(new GameMemoryState(GameMemoryStatus.Default, file, 4096, 4096), later.State);
        Assert.True(changes >= 2);
    }

    [Fact]
    public async Task NoGame_OrAHeapThisPCCannotGive_ChangesNothing()
    {
        using var temp = new TempDirectory();
        var memory = new GameMemory(temp.GetPath("game-memory.json"), () => null, 16 * Gigabyte);
        await memory.RefreshAsync();
        Assert.Equal(GameMemoryStatus.NotFound, memory.State.Status);
        Assert.Equal("not-found", (await Assert.ThrowsAsync<GameMemoryException>(() => memory.ApplyAsync(8192))).Code);
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => memory.ApplyAsync(32768));
    }

    [Fact]
    public void SteamLibraries_AreReadFromSteamsList()
    {
        using var temp = new TempDirectory();
        var steam = temp.GetPath("Steam");
        Directory.CreateDirectory(Path.Combine(steam, "steamapps"));
        File.WriteAllText(Path.Combine(steam, "steamapps", "libraryfolders.vdf"),
            "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"" + steam.Replace(@"\", @"\\") + "\"\n\t}\n\t\"1\"\n\t{\n\t\t\"path\"\t\t\"D:\\\\Games\\\\Steam\"\n\t}\n}\n");
        Assert.Equal([Path.GetFullPath(steam), @"D:\Games\Steam"], GameMemory.SteamLibraries(steam));
    }

    [Fact]
    public void MemoryPressure_IsStallsOrAHeapStandingFull()
    {
        ProfileRecording With(IReadOnlyList<ProfilePause> pauses, double fullShare)
        {
            var heap = Enumerable.Range(0, 20).Select(index => new ProfileHeapSample(index * 250_000,
                index < 20 * fullShare ? 2900L << 20 : 1000L << 20, 3000L << 20, 3072L << 20)).ToArray();
            return new ProfileRecording
            {
                Information = new Dictionary<string, string>(), Threads = [], GameThread = -1, Methods = [], Stacks = [],
                Samples = [], Frames = [], LuaFunctions = [], LuaStacks = [], LuaSamples = [], Collections = [],
                Pauses = pauses, Heap = heap, Duration = 5_000_000, JavaPeriod = 10_000, NativePeriod = 0, LuaPeriod = 0,
            };
        }
        var stall = new ProfilePause(1_000_000, 40_000, "ZAllocationStall", 1, "");
        var shortOf = ProfileAnalysis.MemoryPressure(With([stall, stall with { Time = 2_000_000 }], 0));
        Assert.Equal((2, 80_000L, true, 3072L << 20), (shortOf.Stalls, shortOf.StalledMicroseconds, shortOf.Short, shortOf.MaximumBytes));
        Assert.True(ProfileAnalysis.MemoryPressure(With([], 0.5)).Short);
        // A collection's own pause, or a heap only now and then near its top, is not a shortage.
        Assert.False(ProfileAnalysis.MemoryPressure(With([stall with { Kind = "GCPhasePause" }], 0.1)).Short);
    }
}
