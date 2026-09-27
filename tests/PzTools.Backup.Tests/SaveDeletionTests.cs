using PzTools.App.Core;

namespace PzTools.Backup.Tests;

public sealed class SaveDeletionTests
{
    [Fact]
    public void Deletion_KeepsPlayersDatabaseGuardedAfterValidation()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("Saves", "Sandbox", "Selected");
        Directory.CreateDirectory(Path.Combine(source, "nested"));
        var players = Path.Combine(source, "players.db");
        File.WriteAllText(players, "player");
        File.WriteAllText(Path.Combine(source, "a_chunk.bin"), "chunk");
        File.WriteAllText(Path.Combine(source, "nested", "map.bin"), "nested chunk");
        var attemptedDuringDeletion = false;
        var attemptedAfterValidation = false;
        var progress = new Recorder(value =>
        {
            var afterValidation = value.Phase == SaveDeletionPhase.Validating
                && value.CompletedItems == value.TotalItems;
            var deleting = value.Phase == SaveDeletionPhase.DeletingFiles;
            if ((!afterValidation && !deleting) || !File.Exists(players)) return;
            Assert.Throws<IOException>(() =>
            {
                using var game = new FileStream(players, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
            });
            attemptedAfterValidation |= afterValidation;
            attemptedDuringDeletion |= deleting;
        });

        SaveDeletionService.DeletePermanently(temp.GetPath("Saves"), "Sandbox/Selected",
            progress: progress, progressInterval: TimeSpan.Zero);

        Assert.True(attemptedAfterValidation);
        Assert.True(attemptedDuringDeletion);
        Assert.False(Directory.Exists(source));
    }

    [Fact]
    public void Deletion_CancellationAfterValidationReleasesGuardWithoutDeletingFiles()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("Saves", "Sandbox", "Selected");
        Directory.CreateDirectory(source);
        var players = Path.Combine(source, "players.db");
        File.WriteAllText(players, "player");
        File.WriteAllText(Path.Combine(source, "map.bin"), "chunk");
        using var cancellation = new CancellationTokenSource();
        var progress = new Recorder(value =>
        {
            if (value.Phase == SaveDeletionPhase.Validating && value.CompletedItems == value.TotalItems)
                cancellation.Cancel();
        });

        Assert.Throws<OperationCanceledException>(() => SaveDeletionService.DeletePermanently(
            temp.GetPath("Saves"), "Sandbox/Selected", cancellation.Token, progress));

        Assert.Equal("player", File.ReadAllText(players));
        Assert.Equal("chunk", File.ReadAllText(Path.Combine(source, "map.bin")));
        using var game = new FileStream(players, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
    }

    [Fact]
    public void Deletion_ReportsRealCountsBeforeCompletion()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("Saves", "Sandbox", "Selected");
        Directory.CreateDirectory(Path.Combine(source, "nested"));
        File.WriteAllText(Path.Combine(source, "players.db"), "player");
        for (var i = 0; i < 20; i++) File.WriteAllText(Path.Combine(source, "nested", $"{i}.bin"), "map");
        var values = new List<SaveDeletionProgress>();
        var progress = new Recorder(value =>
        {
            values.Add(value);
            if (value.Phase == SaveDeletionPhase.Validating) Assert.True(File.Exists(Path.Combine(source, "players.db")));
            if (value.Phase == SaveDeletionPhase.DeletingFiles && value.CompletedItems == value.TotalItems)
                Assert.False(Directory.Exists(source));
        });
        SaveDeletionService.DeletePermanently(temp.GetPath("Saves"), "Sandbox/Selected",
            progress: progress, progressInterval: TimeSpan.Zero);
        var validation = values.Where(value => value.Phase == SaveDeletionPhase.Validating).ToArray();
        Assert.Equal(21, validation[^1].CompletedItems);
        Assert.Equal(21, validation[^1].TotalItems);
        var deleting = values.Where(value => value.Phase == SaveDeletionPhase.DeletingFiles).ToArray();
        Assert.Equal(Enumerable.Range(0, 24).Select(i => (long)i), deleting.Select(value => value.CompletedItems));
        Assert.All(deleting, value => Assert.Equal(23, value.TotalItems));
    }

    [Fact]
    public void Deletion_DoesNotRecursivelyDeleteFilesCreatedAfterValidation()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("Saves", "Sandbox", "Selected");
        Directory.CreateDirectory(source);
        File.WriteAllText(Path.Combine(source, "players.db"), "player");
        var progress = new Recorder(value =>
        {
            if (value.Phase == SaveDeletionPhase.DeletingFiles && value.CompletedItems == 0)
                File.WriteAllText(Path.Combine(source, "new.bin"), "new data");
        });
        Assert.Throws<IOException>(() => SaveDeletionService.DeletePermanently(temp.GetPath("Saves"),
            "Sandbox/Selected", progress: progress));
        Assert.Equal("new data", File.ReadAllText(Path.Combine(source, "new.bin")));
    }

    [Fact]
    public void Deletion_ThrottlesCallbacksButAlwaysReportsPhaseBoundaries()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("Saves", "Sandbox", "Selected");
        Directory.CreateDirectory(source);
        File.WriteAllText(Path.Combine(source, "players.db"), "player");
        for (var i = 0; i < 100; i++) File.WriteAllText(Path.Combine(source, $"{i}.bin"), "map");
        var values = new List<SaveDeletionProgress>();
        SaveDeletionService.DeletePermanently(temp.GetPath("Saves"), "Sandbox/Selected",
            progress: new Recorder(values.Add), progressInterval: TimeSpan.FromDays(1));
        Assert.Equal(5, values.Count);
        Assert.Equal(102, values[^1].CompletedItems);
        Assert.Equal(102, values[^1].TotalItems);
    }

    private sealed class Recorder(Action<SaveDeletionProgress> report) : IProgress<SaveDeletionProgress>
    {
        public void Report(SaveDeletionProgress value) => report(value);
    }

    [Fact]
    public void Deletion_PermanentlyDeletesOnlySelectedSave()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var source = Path.Combine(root, "Sandbox", "Selected");
        var other = Path.Combine(root, "Sandbox", "Other");
        Directory.CreateDirectory(Path.Combine(source, "nested"));
        Directory.CreateDirectory(other);
        File.WriteAllText(Path.Combine(source, "players.db"), "player");
        File.WriteAllText(Path.Combine(source, "nested", "map.bin"), "map");
        File.WriteAllText(Path.Combine(other, "players.db"), "other");
        var backups = temp.GetPath("Backups");
        Directory.CreateDirectory(backups);
        File.WriteAllText(Path.Combine(backups, "backup.bin"), "backup");

        var result = SaveDeletionService.DeletePermanently(root, "Sandbox/Selected");

        Assert.False(Directory.Exists(source));
        Assert.Equal(source, result.SourcePath);
        Assert.False(Directory.Exists(temp.GetPath(".Saves.pztools-trash")));
        Assert.Equal("other", File.ReadAllText(Path.Combine(other, "players.db")));
        Assert.Equal("backup", File.ReadAllText(Path.Combine(backups, "backup.bin")));
    }

    [Theory]
    [InlineData("../outside")]
    [InlineData("Sandbox/../../outside")]
    [InlineData("Sandbox")]
    [InlineData("Sandbox/..")]
    [InlineData("Sandbox/Save.")]
    public void Deletion_RejectsUnscopedTargets(string saveId)
    {
        using var temp = new TempDirectory();
        Assert.Throws<ArgumentException>(() => SaveDeletionService.DeletePermanently(temp.GetPath("Saves"), saveId));
    }

    [Fact]
    public void Deletion_RejectsInUseOrUnrecognizedSave()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var source = Path.Combine(root, "Sandbox", "Selected");
        Directory.CreateDirectory(source);
        Assert.Throws<InvalidDataException>(() => SaveDeletionService.DeletePermanently(root, "Sandbox/Selected"));
        var players = Path.Combine(source, "players.db");
        File.WriteAllText(players, "player");
        using var active = new FileStream(players, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
        Assert.Throws<IOException>(() => SaveDeletionService.DeletePermanently(root, "Sandbox/Selected"));
        Assert.True(File.Exists(players));
    }

    [Fact]
    public void Deletion_CancellationKeepsOriginal()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var source = Path.Combine(root, "Sandbox", "Selected");
        Directory.CreateDirectory(source);
        File.WriteAllText(Path.Combine(source, "players.db"), "player");
        Assert.Throws<OperationCanceledException>(() => SaveDeletionService.DeletePermanently(
            root, "Sandbox/Selected", new CancellationToken(true)));
        Assert.True(Directory.Exists(source));
    }

    [Fact]
    public void Deletion_LockedChildFilePreventsAnyDeletion()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var source = Path.Combine(root, "Sandbox", "Selected");
        Directory.CreateDirectory(Path.Combine(source, "nested"));
        var players = Path.Combine(source, "players.db");
        var map = Path.Combine(source, "nested", "map.bin");
        File.WriteAllText(players, "player");
        File.WriteAllText(map, "map");
        using var locked = new FileStream(map, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Assert.Throws<IOException>(() => SaveDeletionService.DeletePermanently(root, "Sandbox/Selected"));
        Assert.Equal("player", File.ReadAllText(players));
        Assert.True(File.Exists(map));
    }

    [Fact]
    public void Deletion_DoesNotCleanUpPreviouslyStoredSaves()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var source = Path.Combine(root, "Sandbox", "Selected");
        var stored = temp.GetPath(".Saves.pztools-trash", "previous", "Sandbox", "Selected");
        Directory.CreateDirectory(source);
        Directory.CreateDirectory(stored);
        File.WriteAllText(Path.Combine(source, "players.db"), "player");
        File.WriteAllText(Path.Combine(stored, "players.db"), "previous");
        SaveDeletionService.DeletePermanently(root, "Sandbox/Selected");
        Assert.False(Directory.Exists(source));
        Assert.Equal("previous", File.ReadAllText(Path.Combine(stored, "players.db")));
    }
}
