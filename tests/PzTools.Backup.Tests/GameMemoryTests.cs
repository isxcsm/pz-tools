using PzTools.App.Core;
using PzTools.Profiling;

namespace PzTools.Backup.Tests;

/// <summary>The game's memory is changed in its own launcher file, one option at a time, and found again after an update.</summary>
public sealed class GameMemoryTests
{
    [Theory]
    [InlineData(@"C:\Steam\steamapps\common\ProjectZomboid\ProjectZomboid64.json", true)]
    [InlineData(@"D:\Games\PZ\projectzomboid64.JSON", true)]
    // A remembered path is the player's to write; the app edits it as administrator, so only the launch file goes.
    [InlineData(@"C:\Windows\System32\drivers\etc\hosts", false)]
    [InlineData(@"C:\PZ\ProjectZomboid64.json:hidden", false)]
    [InlineData(@"ProjectZomboid64.json", false)]
    [InlineData(@"..\ProjectZomboid64.json", false)]
    [InlineData(@"\\server\share\ProjectZomboid64.json", false)]
    [InlineData(@"\\?\C:\PZ\ProjectZomboid64.json", false)]
    public void IsLaunchFile_TakesOnlyTheGamesLaunchFileByAFullPath(string path, bool expected) =>
        Assert.Equal(expected, GameMemory.IsLaunchFile(path));

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
        Assert.Equal(new GameMemoryState(GameMemoryStatus.Applied, file, 8192, 3072, 8192, 8192), memory.State);
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
    public async Task AnyRewriteOfTheHeapOptionsByAnotherTool_IsNoticedLikeAnUpdates_WhatSetsTheGamesOwnBackIncluded()
    {
        using var temp = new TempDirectory();
        var file = temp.GetPath(GameMemory.ConfigFileName);
        File.WriteAllText(file, Shipped);
        var record = temp.GetPath("data", "game-memory.json");
        var memory = new GameMemory(record, () => file, 64 * Gigabyte);
        await memory.ApplyAsync(16384);
        var applied = File.ReadAllText(file);
        Assert.Equal(new GameMemoryState(GameMemoryStatus.Applied, file, 16384, 3072, 16384, 16384), memory.State);

        // What PZ Optimize's heap setting did to a file with both options: the maximum lowered, the starting heap left.
        // The game never starts from it, and the state says so as well as that the choice is gone.
        var rewrites = new (string Name, string Text, (int, int?) Heap, bool TooLarge)[]
        {
            ("maximum only", applied.Replace("-Xmx16384m", "-Xmx4096m"), (4096, 16384), true),
            ("both options", applied.Replace("-Xmx16384m", "-Xmx4096m").Replace("-Xms16384m", "-Xms4096m"), (4096, 4096), false),
            ("starting heap only", applied.Replace("-Xms16384m", "-Xms8192m"), (16384, 8192), false),
            ("starting heap removed", applied.Replace("\t\t\"-Xms16384m\",\n", ""), (16384, null), false),
            ("units changed, same size", applied.Replace("-Xmx16384m", "-Xmx4g"), (4096, 16384), true),
        };
        foreach (var (name, text, heap, tooLarge) in rewrites)
        {
            File.WriteAllText(file, text);
            await memory.RefreshAsync();
            Assert.True(heap == (memory.State.MaximumMegabytes!.Value, memory.State.InitialMegabytes), name);
            Assert.Equal(GameMemoryStatus.Reverted, memory.State.Status);
            Assert.Equal(16384, memory.State.ChosenMegabytes);
            Assert.Equal(tooLarge, memory.State.StartsTooLarge);
            // The one press the card offers puts the choice back, whatever was done to the file.
            await memory.ApplyAsync(16384);
            Assert.Equal(GameMemoryStatus.Applied, memory.State.Status);
            Assert.False(memory.State.StartsTooLarge);
            Assert.Equal(applied, File.ReadAllText(file));
        }
        // Nothing wrong with the file, nothing to say.
        await memory.RefreshAsync();
        Assert.False(memory.State.StartsTooLarge);
    }

    [Fact]
    public async Task AStartingHeapAboveTheMaximum_IsFlaggedWithoutAChoice_AndFixedWithoutOneBeingMade()
    {
        using var temp = new TempDirectory();
        var file = temp.GetPath(GameMemory.ConfigFileName);
        // A file the player set by hand and another tool half rewrote: the game's own heap is what it holds.
        var broken = GameMemory.Rewrite(Shipped, 4096, 16384);
        File.WriteAllText(file, broken);
        var memory = new GameMemory(temp.GetPath("data", "game-memory.json"), () => file, 64 * Gigabyte);
        await memory.RefreshAsync();
        Assert.Equal(new GameMemoryState(GameMemoryStatus.Default, file, 4096, 4096, null, 16384), memory.State);
        Assert.True(memory.State.StartsTooLarge);
        // The game's own heap is the fix offered (the starting heap becomes the maximum); no choice is recorded.
        await memory.ApplyAsync(null);
        Assert.Equal(new GameMemoryState(GameMemoryStatus.Default, file, 4096, 4096, null, 4096), memory.State);
        Assert.Equal((4096, 4096), GameMemory.ReadHeap(File.ReadAllText(file)));
        // A file that is fine is left as it is, as always.
        var fine = File.ReadAllText(file);
        await memory.ApplyAsync(null);
        Assert.Equal(fine, File.ReadAllText(file));

        // With a choice made earlier, letting it go does not leave the broken file behind either.
        File.WriteAllText(file, Shipped);
        await memory.ApplyAsync(16384);
        File.WriteAllText(file, broken);
        await memory.RefreshAsync();
        Assert.Equal(GameMemoryStatus.Reverted, memory.State.Status);
        Assert.True(memory.State.StartsTooLarge);
        await memory.ApplyAsync(null);
        Assert.Equal(GameMemoryStatus.Default, memory.State.Status);
        Assert.Null(memory.State.ChosenMegabytes);
        Assert.Equal((4096, 4096), GameMemory.ReadHeap(File.ReadAllText(file)));
    }

    // The settings file of a mod that sets the game's heap itself (PZ Optimize): other keys, comments and layout of its own.
    private const string OptimizerSettings = "# my settings\r\ndarknessFloorPct=20\r\n\r\n  gcHeapFixed=false\r\nupscaler=fsr\r\n! last\r\n";

    // The launcher file after such a mod has been at it: its own heap, and the entry that remembers the options it replaced.
    private static readonly string Optimized = Shipped.Replace("\t\t\"-Xmx3072m\",\n", "\t\t\"-Xmx4096m\",\n\t\t\"-Xms4096m\",\n")
        .Replace("\"-XX:-OmitStackTraceInFastThrow\"\n", "\"-XX:-OmitStackTraceInFastThrow\",\n\t\t\"-Dpzopt.heap=3072m,none,0\"\n");

    [Fact]
    public async Task AModThatSetsTheHeapItself_IsToldTheChoice_ItsOwnSettingsKept_AndLetGoWithTheGamesOwnHeap()
    {
        using var temp = new TempDirectory();
        var game = temp.GetPath("ProjectZomboid");
        Directory.CreateDirectory(Path.Combine(game, "pzopt"));
        var file = Path.Combine(game, GameMemory.ConfigFileName);
        var settings = Path.Combine(game, "pzopt.properties");
        File.WriteAllText(file, Optimized);
        File.WriteAllText(settings, OptimizerSettings);
        var memory = new GameMemory(temp.GetPath("data", "game-memory.json"), () => file, 64 * Gigabyte);

        await memory.ApplyAsync(16384);
        // The mod's heap is the choice, its starting heap follows, and the entry it restores the options from holds the
        // choice too (it would put the earlier options back over it at the next start); the rest of its file is as it was.
        Assert.Equal("# my settings\r\ndarknessFloorPct=20\r\n\r\n  gcHeapFixed=true\r\nupscaler=fsr\r\n! last\r\ngcHeap=16384\r\n", File.ReadAllText(settings));
        var applied = File.ReadAllText(file);
        Assert.Contains("\"-Dpzopt.heap=16384m,16384m,0\"", applied);
        Assert.Equal((16384, 16384), GameMemory.ReadHeap(applied));
        Assert.Equal(GameMemoryStatus.Applied, memory.State.Status);

        await memory.ApplyAsync(8192);
        Assert.Equal("# my settings\r\ndarknessFloorPct=20\r\n\r\n  gcHeapFixed=true\r\nupscaler=fsr\r\n! last\r\ngcHeap=8192\r\n", File.ReadAllText(settings));
        Assert.Contains("\"-Dpzopt.heap=8192m,8192m,0\"", File.ReadAllText(file));

        // Back to the game's own: the mod's settings are what they were, and its entry holds the game's options again.
        File.WriteAllText(file, Optimized);
        await memory.RefreshAsync();
        Assert.Equal(GameMemoryStatus.Reverted, memory.State.Status);
        await memory.ApplyAsync(null);
        Assert.Equal(OptimizerSettings, File.ReadAllText(settings));
        Assert.Equal(GameMemoryStatus.Default, memory.State.Status);
    }

    [Fact]
    public async Task TheGamesOwnHeap_IsWhatTheModsEntryHolds_NotTheModsHeapOverTheChoice()
    {
        using var temp = new TempDirectory();
        var game = temp.GetPath("ProjectZomboid");
        Directory.CreateDirectory(Path.Combine(game, "pzopt"));
        var file = Path.Combine(game, GameMemory.ConfigFileName);
        File.WriteAllText(file, Optimized);
        var memory = new GameMemory(temp.GetPath("data", "game-memory.json"), () => file, 64 * Gigabyte);

        // The mod's 4096 is in the options; the game's own 3072 (no starting heap) is in its entry.
        await memory.ApplyAsync(16384);
        // At its next start the mod put its own heap over the choice, its entry holding the choice: reverted.
        File.WriteAllText(file, File.ReadAllText(file).Replace("\"-Xmx16384m\"", "\"-Xmx4096m\"").Replace("\"-Xms16384m\"", "\"-Xms4096m\""));
        await memory.RefreshAsync();
        Assert.Equal(GameMemoryStatus.Reverted, memory.State.Status);
        // Applied again: the mod's 4096 is not taken for the game's own heap.
        await memory.ApplyAsync(16384);
        Assert.Equal(GameMemoryStatus.Applied, memory.State.Status);

        await memory.ApplyAsync(null);
        var back = File.ReadAllText(file);
        Assert.Equal((3072, null), GameMemory.ReadHeap(back));
        Assert.Contains("\"-Dpzopt.heap=3072m,none,0\"", back);
    }

    [Theory]
    [InlineData("\"-Dpzopt.heap=3072m,none,0\"", 3072, null)]
    [InlineData("\"-Dpzopt.heap=16g,16384m,0\"", 16384, 16384)]
    [InlineData("\"-Dpzopt.heap=lots,none,0\"", null, null)]
    public void TheModsEntry_IsReadInMegabytes(string entry, int? maximum, int? initial)
    {
        var heap = GameMemory.OptimizerHeap("{\"vmArgs\": [\"-Xmx4096m\", " + entry + "]}");
        if (maximum is null) Assert.Null(heap);
        else Assert.Equal((maximum.Value, initial), heap);
    }

    [Fact]
    public async Task AModsSettingsTheAppDidNotWrite_AreLeftWhenTheGamesOwnHeapIsBack()
    {
        using var temp = new TempDirectory();
        var game = temp.GetPath("ProjectZomboid");
        Directory.CreateDirectory(game);
        var file = Path.Combine(game, GameMemory.ConfigFileName);
        var settings = Path.Combine(game, "pzopt.properties");
        File.WriteAllText(file, Shipped);
        File.WriteAllText(settings, "gcHeap=auto\ngcHeapFixed=false\n");
        var memory = new GameMemory(temp.GetPath("data", "game-memory.json"), () => file, 64 * Gigabyte);
        await memory.ApplyAsync(12288);
        Assert.Equal("gcHeap=12288\ngcHeapFixed=true\n", File.ReadAllText(settings));
        // The player sets the mod's heap by hand afterwards: that is theirs.
        File.WriteAllText(settings, "gcHeap=6144\ngcHeapFixed=true\n");
        await memory.ApplyAsync(null);
        Assert.Equal("gcHeap=6144\ngcHeapFixed=false\n", File.ReadAllText(settings));
        // A settings file the app made is gone again with the choice; a game without the mod never gets one.
        var plain = temp.GetPath("Other");
        Directory.CreateDirectory(Path.Combine(plain, "pzopt"));
        var other = Path.Combine(plain, GameMemory.ConfigFileName);
        File.WriteAllText(other, Shipped);
        var second = new GameMemory(temp.GetPath("data2", "game-memory.json"), () => other, 64 * Gigabyte);
        await second.ApplyAsync(8192);
        Assert.Equal("gcHeap=8192\r\ngcHeapFixed=true\r\n", File.ReadAllText(Path.Combine(plain, "pzopt.properties")));
        await second.ApplyAsync(null);
        Assert.False(File.Exists(Path.Combine(plain, "pzopt.properties")));
        var without = temp.GetPath("Bare");
        Directory.CreateDirectory(without);
        var bare = Path.Combine(without, GameMemory.ConfigFileName);
        File.WriteAllText(bare, Shipped);
        await new GameMemory(temp.GetPath("data3", "game-memory.json"), () => bare, 64 * Gigabyte).ApplyAsync(8192);
        Assert.Equal(new[] { GameMemory.ConfigFileName }, Directory.GetFiles(without).Select(Path.GetFileName));
    }

    [Theory]
    [InlineData("", "gcHeap", "9", "gcHeap=9\r\n")]
    [InlineData("a=1", "gcHeap", "9", "a=1\r\ngcHeap=9\r\n")]
    [InlineData("a=1\ngcHeap=auto\nb=2\n", "gcHeap", "9", "a=1\ngcHeap=9\nb=2\n")]
    [InlineData("# gcHeap=1\n  gcHeap : 2\ngcHeap 3\n", "gcHeap", "9", "# gcHeap=1\n  gcHeap : 2\ngcHeap=9\n")]
    [InlineData("a=1\ngcHeap=2\nb=2\ngcHeap=3\n", "gcHeap", null, "a=1\nb=2\n")]
    public void OptimizerSettings_AreEditedLineByLine(string text, string key, string? value, string expected) =>
        Assert.Equal(expected, GameMemoryOptimizer.Set(text, key, value));

    [Fact]
    public void OptimizerSettings_AreReadTheWayTheModReadsThem()
    {
        Assert.Equal("auto", GameMemoryOptimizer.Get("gcHeap = auto \n", "gcHeap"));
        Assert.Equal("3", GameMemoryOptimizer.Get("gcHeap=2\ngcHeap:3", "gcHeap"));
        Assert.Null(GameMemoryOptimizer.Get("# gcHeap=2\ngcHeapFixed=true", "gcHeap"));
    }

    [Fact]
    public async Task ARunningGameHoldingItsFile_StillHasItChanged_ForItsNextStart()
    {
        using var temp = new TempDirectory();
        var file = temp.GetPath(GameMemory.ConfigFileName);
        File.WriteAllText(file, Shipped);
        var memory = new GameMemory(temp.GetPath("data", "game-memory.json"), () => file, 32 * Gigabyte);
        // As the running game's launcher holds it: others may read and write it, not replace it.
        using (new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            await memory.ApplyAsync(8192);
            Assert.Equal(GameMemoryStatus.Applied, memory.State.Status);
            await memory.ApplyAsync(null);
        }
        Assert.Equal(Shipped, File.ReadAllText(file));
        Assert.Single(Directory.GetFiles(temp.Path));
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
    public async Task TheChoiceIsKeptBeforeTheGamesFileChanges_AndNotChangedWhenItCannotBe()
    {
        using var temp = new TempDirectory();
        var file = temp.GetPath(GameMemory.ConfigFileName);
        File.WriteAllText(file, Shipped);
        // Where the app keeps its record, something it cannot write over.
        var record = temp.GetPath("data", "game-memory.json");
        Directory.CreateDirectory(record);
        var memory = new GameMemory(record, () => file, 32 * Gigabyte);
        Assert.Equal("unwritable", (await Assert.ThrowsAsync<GameMemoryException>(() => memory.ApplyAsync(8192))).Code);
        // The game's own heap, kept nowhere, could not be given back: the file is left as the game wrote it.
        Assert.Equal(Shipped, File.ReadAllText(file));
        await memory.RefreshAsync();
        Assert.Equal(GameMemoryStatus.Default, memory.State.Status);
    }

    [Fact]
    public async Task AChoiceThisPCNoLongerOffers_IsStillAppliedAgain()
    {
        using var temp = new TempDirectory();
        var file = temp.GetPath(GameMemory.ConfigFileName);
        File.WriteAllText(file, Shipped);
        var record = temp.GetPath("data", "game-memory.json");
        await new GameMemory(record, () => file, 64 * Gigabyte).ApplyAsync(16384);
        // Memory taken out, and a game update put the game's own back.
        File.WriteAllText(file, Shipped);
        var smaller = new GameMemory(record, () => file, 16 * Gigabyte);
        await smaller.RefreshAsync();
        Assert.Equal(GameMemoryStatus.Reverted, smaller.State.Status);
        await smaller.ApplyAsync(16384);
        Assert.Equal(GameMemoryStatus.Applied, smaller.State.Status);
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => smaller.ApplyAsync(24576));
    }

    [Fact]
    public async Task TheRunningGamesFile_IsTheOneChanged_AndAFileHeldForAMomentChangesNothingShown()
    {
        using var temp = new TempDirectory();
        var installed = temp.GetPath("Steam", GameMemory.ConfigFileName);
        var copy = temp.GetPath("Copy", GameMemory.ConfigFileName);
        foreach (var path in new[] { installed, copy })
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, Shipped);
        }
        var record = temp.GetPath("data", "game-memory.json");
        await new GameMemory(record, () => installed, 32 * Gigabyte).RefreshAsync();
        // The one remembered is not the one the running game reads.
        var memory = new GameMemory(record, () => installed, 32 * Gigabyte, running: () => copy);
        await memory.ApplyAsync(8192);
        Assert.Equal((8192, 8192), GameMemory.ReadHeap(File.ReadAllText(copy)));
        Assert.Equal(Shipped, File.ReadAllText(installed));

        // Steam rewriting it, a scanner reading it: held without sharing, it is not "not as expected".
        using (new FileStream(copy, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            await memory.RefreshAsync();
            Assert.Equal(GameMemoryStatus.Applied, memory.State.Status);
        }
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
