using Microsoft.Data.Sqlite;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class SaveDiscoveryRestoreTests
{
    [Theory]
    [InlineData(".Save.pztools-staging-0123456789abcdef0123456789abcdef", false)]
    [InlineData(".Save.pztools-rollback-0123456789abcdef0123456789abcdef", false)]
    [InlineData(".Save.PZTOOLS-STAGING-0123456789ABCDEF0123456789ABCDEF", false)]
    [InlineData(".pztools-import-0123456789abcdef0123456789abcdef", false)]
    [InlineData(".My save", true)]
    [InlineData(".Save.pztools-staging-not-a-token", true)]
    [InlineData("Save.pztools-staging-0123456789abcdef0123456789abcdef", true)]
    [InlineData(".Save.pztools-rollback-0123456789abcdef0123456789abcdef-copy", true)]
    public void Discovery_ExcludesOnlyReservedOperationDirectories(string name, bool visible)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("Sandbox", name);
        Directory.CreateDirectory(path);
        File.WriteAllText(Path.Combine(path, "map_ver.bin"), "marker");
        var result = new SaveDiscoveryLane().Collect(temp.Path);
        Assert.True(result.Complete);
        Assert.Equal(visible ? 1 : 0, result.Saves.Count);
    }

    [Fact]
    public void Discovery_DoesNotTraverseImportStagingAsGameMode()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath($".pztools-import-{Guid.NewGuid():N}", "Save");
        Directory.CreateDirectory(path);
        File.WriteAllText(Path.Combine(path, "players.db"), "marker");
        var result = new SaveDiscoveryLane().Collect(temp.Path);
        Assert.True(result.Complete);
        Assert.Empty(result.Saves);
    }

    [Fact]
    public async Task Discovery_DoesNotReadPartiallyPublishedCharacterEdit()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Save");
        await CreateSaveAsync(save, 1);
        var pending = PzTools.Process.Hosting.SaveFileEditTransaction.DirectoryPath(save);
        Directory.CreateDirectory(pending);
        File.Copy(Path.Combine(save, "players.db"), Path.Combine(pending, "players.db"));
        var result = new SaveDiscoveryLane().Collect(root);
        Assert.False(result.Complete);
        Assert.Empty(result.Saves);
        Directory.Delete(pending, true);
        Assert.Single(new SaveDiscoveryLane().Collect(root).Saves);
    }

    [Fact]
    public async Task Collection_PreservesOriginalEntryAcrossExtractionSwapAndCleanup()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var target = Path.Combine(root, "Sandbox", "Save");
        var other = Path.Combine(root, "Sandbox", "Other");
        await CreateSaveAsync(target, 0);
        await CreateSaveAsync(other, 0);
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var collector = new StateCollector();
        var reactor = new StateReactor();
        await CollectAsync(true);
        await CollectAsync(true); // Confirm inactive before the operation.

        var token = Guid.NewGuid().ToString("N");
        var parent = Path.GetDirectoryName(target)!;
        var staging = Path.Combine(parent, $".Save.pztools-staging-{token}");
        var rollback = Path.Combine(parent, $".Save.pztools-rollback-{token}");
        var journal = Path.Combine(parent, ".Save.pztools-restore.json");
        // Discovery only needs the durable marker, not its contents or phase.
        await File.WriteAllTextAsync(journal, "{}");
        await CreateSaveAsync(staging, 1);
        await CollectAsync(false); // Full staging copy next to the original.
        Directory.Move(target, rollback);
        await CollectAsync(false); // Original target absent between renames.
        Directory.Move(staging, target);
        await CollectAsync(false); // New target and rollback coexist.
        Directory.Delete(rollback, recursive: true);
        File.Delete(journal);
        await CollectAsync(true);

        var final = await database.ReadCurrentStateIfChangedAsync(-1);
        Assert.Equal(CharacterState.Dead, final.Saves.Single(item => item.DisplayName == "Save").Character);
        Assert.All(final.Saves, item => Assert.False(item.Stale));
        Assert.DoesNotContain(await database.ReadPendingOutboxAsync(), item => item.Command == "ClearTarget");

        async Task CollectAsync(bool complete)
        {
            var result = await collector.RunAsync(database, root);
            Assert.Equal(complete, result.Batch.DiscoveryComplete);
            Assert.DoesNotContain(result.Batch.Saves, item => item.DisplayName.StartsWith('.'));
            if (!complete)
                Assert.Equal("Other", Assert.Single(result.Batch.Saves).DisplayName);
            await reactor.RunAsync(database);
            var snapshot = await database.ReadCurrentStateIfChangedAsync(-1);
            Assert.Equal(new[] { "Other", "Save" }, snapshot.Saves.Select(item => item.DisplayName).Order().ToArray());
            if (!complete)
                Assert.Equal(CharacterState.Alive, snapshot.Saves.Single(item => item.DisplayName == "Save").Character);
        }
    }

    private static async Task CreateSaveAsync(string directory, int dead)
    {
        Directory.CreateDirectory(directory);
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = Path.Combine(directory, "players.db"),
            Pooling = false,
        }.ToString());
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "CREATE TABLE localPlayers(isDead INTEGER); INSERT INTO localPlayers VALUES($dead);";
        command.Parameters.AddWithValue("$dead", dead);
        await command.ExecuteNonQueryAsync();
    }
}
