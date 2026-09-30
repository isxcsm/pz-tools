using Microsoft.Data.Sqlite;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class BackupGameVersionTests
{
    [Fact]
    public async Task Revision_KeepsTheGameVersionItWasMadeWith()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "test", temp.GetPath("source"));
        await CommitAsync(repository, lease, source.SourceId, " 42.21 ");
        await CommitAsync(repository, lease, source.SourceId, null); // The game was not running.

        var revisions = Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions;
        Assert.Equal(new[] { null, "42.21" }, revisions.Select(item => item.GameVersion));
        var views = new RevisionedViewStore();
        await new BackupProjector(repository, views).ProjectOnceAsync();
        var projected = Assert.Single(views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0).Snapshot!.Sources);
        Assert.Equal(new[] { null, "42.21" }, projected.Revisions.Select(item => item.GameVersion));

        var run = await repository.StartRunAsync(lease, source.SourceId);
        await Assert.ThrowsAsync<ArgumentException>(() => repository.CommitRevisionAsync(lease,
            new RevisionCommitRequest(run.RunIndex, source.SourceId, null, [], [], [], GameVersion: new string('4', 81))));
    }

    [Fact]
    public async Task RepositoryMadeBeforeGameVersions_GainsTheColumnAndKeepsItsBackups()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            sourceId = (await repository.AddOrGetSourceAsync(lease, "test", temp.GetPath("source"))).SourceId;
            await CommitAsync(repository, lease, sourceId, null);
        }
        await ExecuteAsync(repository, "ALTER TABLE revisions DROP COLUMN game_version;");

        // Both ways of opening repair it, and the repository stays the version other builds accept.
        var reopened = await RepositoryDatabase.OpenExistingAsync(repository.RepositoryPath);
        Assert.Equal(repository.Identity.SchemaVersion, reopened.Identity.SchemaVersion);
        Assert.Null(Assert.Single(Assert.Single((await reopened.ReadCatalogIfChangedAsync(-1)).Sources).Revisions).GameVersion);
        await ExecuteAsync(repository, "ALTER TABLE revisions DROP COLUMN game_version;");
        reopened = await RepositoryDatabase.CreateOrOpenAsync(repository.RepositoryPath);
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
            await CommitAsync(reopened, lease, sourceId, "42.21");
        Assert.Equal("42.21", Assert.Single((await reopened.ReadCatalogIfChangedAsync(-1)).Sources).Revisions[0].GameVersion);
    }

    [Fact]
    public void GameVersion_IsTakenOnlyWhileTheGameHasThatSaveLoaded()
    {
        using var temp = new TempDirectory();
        var save = temp.GetPath("Sandbox", "Save");
        RuntimeObservation Observe(WorldPhase phase, string? path, string? version, RuntimeQuality quality = RuntimeQuality.Fresh) =>
            new RuntimeObservation(Id, quality, new RuntimeSnapshot(Id, Id, Id, 1, 1, 1, phase, GamePause.Running,
                RuntimeMode.LocalSinglePlayer, 1, 0, 0, path, version)).Validate();

        Assert.Equal("42.21", Observe(WorldPhase.Ready, save, "42.21").GameVersionFor(save + Path.DirectorySeparatorChar));
        Assert.Null(Observe(WorldPhase.Ready, temp.GetPath("Sandbox", "Other"), "42.21").GameVersionFor(save));
        Assert.Null(Observe(WorldPhase.Menu, null, "42.21").GameVersionFor(save));
        Assert.Null(Observe(WorldPhase.Ready, save, null).GameVersionFor(save));
        Assert.Null(Observe(WorldPhase.Ready, save, "42.21", RuntimeQuality.Stale).GameVersionFor(save));
        Assert.Null(RuntimeObservation.Unknown().GameVersionFor(save));
    }

    [Fact]
    public void UneditedBackupName_IsRecognisedInEveryLanguage()
    {
        foreach (var language in LanguageCatalog.All)
        {
            Assert.True(LanguageCatalog.IsDefaultBackupName($"{language.BackupName} 7", 7));
            Assert.True(LanguageCatalog.IsDefaultBackupName($"{language.ManualBackupName} 7", 7));
            Assert.True(LanguageCatalog.IsDefaultBackupName($"{language.AutomaticBackupName} 1234", 1234));
            // A cleared name saved by the app groups digits the way its language does.
            var grouped = 1234.ToString("N0", System.Globalization.CultureInfo.GetCultureInfo(language.Tag));
            Assert.True(LanguageCatalog.IsDefaultBackupName($"{language.ManualBackupName} {grouped}", 1234));
        }
        Assert.False(LanguageCatalog.IsDefaultBackupName("Backup 1,234", 1235));
        Assert.False(LanguageCatalog.IsDefaultBackupName("자동 백업 7", 8)); // Another backup's number: the user typed it.
        Assert.False(LanguageCatalog.IsDefaultBackupName("자동 백업 7 보스전", 7));
        Assert.False(LanguageCatalog.IsDefaultBackupName("My checkpoint", 7));
        Assert.False(LanguageCatalog.IsDefaultBackupName("7", 7));
        Assert.False(LanguageCatalog.IsDefaultBackupName("", 7));
        Assert.False(LanguageCatalog.IsDefaultBackupName(null, 7));
    }

    private static readonly string Id = new('a', 32);

    private static async Task CommitAsync(RepositoryDatabase repository, RepositoryWriterLease lease, long sourceId, string? gameVersion)
    {
        var run = await repository.StartRunAsync(lease, sourceId);
        await repository.CommitRevisionAsync(lease,
            new RevisionCommitRequest(run.RunIndex, sourceId, null, [], [], [], GameVersion: gameVersion));
    }

    private static async Task ExecuteAsync(RepositoryDatabase repository, string sql)
    {
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = repository.DatabasePath, Pooling = false }.ToString());
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync();
    }
}
