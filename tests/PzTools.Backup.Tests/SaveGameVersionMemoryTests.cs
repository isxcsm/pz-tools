using PzTools.App.Core;

namespace PzTools.Backup.Tests;

public sealed class SaveGameVersionMemoryTests
{
    [Fact]
    public void RemembersTheLastVersionSeenPerSave_AcrossRestarts()
    {
        using var temp = new TempDirectory();
        var save = temp.GetPath("Saves", "Sandbox", "World");
        var seen = new DateTimeOffset(2026, 9, 30, 12, 0, 0, TimeSpan.Zero);

        var memory = new SaveGameVersionMemory(temp.Path);
        Assert.Null(memory.Recall(save));
        memory.Remember(save, " 42.21 ", seen);
        memory.Remember(save + Path.DirectorySeparatorChar, "42.21", seen.AddHours(1)); // same save, same version

        var reopened = new SaveGameVersionMemory(temp.Path);
        Assert.Equal(new SaveGameVersion("42.21", SaveVersionBasis.LastSeen, seen), reopened.Recall(save.ToUpperInvariant()));

        // A game update is remembered as soon as the save is seen with it.
        reopened.Remember(save, "42.22", seen.AddDays(1));
        Assert.Equal("42.22", new SaveGameVersionMemory(temp.Path).Recall(save)!.Version);
        Assert.Null(reopened.Recall(temp.GetPath("Saves", "Sandbox", "Other")));
    }

    [Fact]
    public void IgnoresUnusableVersionsAndADamagedFile()
    {
        using var temp = new TempDirectory();
        var save = temp.GetPath("World");
        var memory = new SaveGameVersionMemory(temp.Path);
        memory.Remember(save, "", DateTimeOffset.UtcNow);
        memory.Remember(save, "42\n21", DateTimeOffset.UtcNow);
        memory.Remember(save, new string('4', 81), DateTimeOffset.UtcNow);
        Assert.Null(memory.Recall(save));

        File.WriteAllText(temp.GetPath("save-versions.json"), "{ not json");
        var damaged = new SaveGameVersionMemory(temp.Path);
        Assert.Null(damaged.Recall(save));
        damaged.Remember(save, "42.21", DateTimeOffset.UtcNow);
        Assert.Equal("42.21", new SaveGameVersionMemory(temp.Path).Recall(save)!.Version);
    }
}
