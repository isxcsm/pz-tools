using Microsoft.Data.Sqlite;
using PzTools.App.Core;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Projections;
using PzTools.Zomboid.Backup;

namespace PzTools.Backup.Tests;

public sealed class AuditOptimizationTests
{
    [Fact]
    public async Task ExplicitProjectionDoesNotExecuteOnCallingUiContext()
    {
        await using var host = new ProjectionHost();
        SynchronizationContext? observed = new();
        host.AddLoop("read", _ =>
        {
            observed = SynchronizationContext.Current;
            return Task.CompletedTask;
        }, TimeSpan.FromSeconds(1));
        var original = SynchronizationContext.Current;
        Task pending;
        try
        {
            SynchronizationContext.SetSynchronizationContext(new SynchronizationContext());
            pending = host.ProjectNowAsync("read");
        }
        finally { SynchronizationContext.SetSynchronizationContext(original); }
        await pending;
        Assert.Null(observed);
    }

    [Fact]
    public void TelemetryZeroLimitsKeepTheirDocumentedUnlimitedMeaning()
    {
        var config = ComponentConfiguration.Parse("[telemetry]\nretain_runs=0\nmax_database_mib=0");
        ComponentOptions.Validate("restore-worker", config);
        var settings = TelemetryRuntimeOptions.Read(config);
        Assert.Equal(0, settings.RetainRuns);
        Assert.Equal(0, settings.MaxDatabaseMib);
    }

    [Theory]
    [InlineData("state-scheduler", "[scheduler]\nwake_interval_ms = 0")]
    [InlineData("state-scheduler", "[scheduler]\ninterval_seconds = -1")]
    [InlineData("state-scheduler", "[scheduler]\nconfirmation_delay_ms = 'fast'")]
    [InlineData("backup-scheduler", "[scheduler]\nwake_interval_ms = 999999")]
    [InlineData("maintenance-worker", "[maintenance]\nrevision_batch_size = 0")]
    [InlineData("maintenance-worker", "[maintenance]\nwriter_retry_delay_ms = 0")]
    [InlineData("archive-worker", "[preview]\nthumbnail_mib = 0")]
    [InlineData("archive-worker", "[archive]\nmaximum_single_file_bytes = -1")]
    [InlineData("archive-worker", "[archive]\nminimum_free_space_reserve_percent = 101")]
    [InlineData("state-reactor", "[state]\nbackup_on_death = 'yes'")]
    [InlineData("restore-worker", "[telemetry]\nretain_runs = -1")]
    [InlineData("character-recovery", "[telemetry]\nheartbeat_interval_ms = 0")]
    [InlineData("state-runner", "[telemetry]\nretain_run_typo = 1")]
    [InlineData("state-collector", "[typo]\nenabled = true")]
    public async Task PreflightAndWorkerRejectTheSameInvalidSettings(string component, string document)
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var path = ComponentRuntimePaths.GetIdentityDefaultPath(temp.Path, component, service.ConfigurationRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllTextAsync(path, document);
        Assert.Throws<InvalidDataException>(service.ValidateEditableConfiguration);
        Assert.Throws<InvalidDataException>(() => ComponentConfiguration.Load(temp.Path, component,
            configurationRoot: service.ConfigurationRoot));
    }

    [Fact]
    public async Task CapturedSummarySurvivesRestartAndProjectorDoesNotReadPacksOrTakeWriterLease()
    {
        using var temp = new TempDirectory();
        var options = await CreateOptionsAsync(temp);
        await new OneShotBackupService(new NoJournal(), collectMetadata: RevisionCharacterMetadataCollector.PopulateAsync)
            .RunAsync(options, "test");
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        var summary = Assert.Single(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        Assert.True(summary.CharacterMetadataRead);
        Assert.Equal("Captured character", summary.CharacterName);
        // The source and pack are unavailable; the stored summary must still be sufficient.
        File.Move(temp.GetPath("source/players.db"), temp.GetPath("players-unavailable.db"));
        foreach (var pack in await repository.ReadPacksAsync())
            File.Move(Path.Combine(options.RepositoryPath, pack.RelativePath), temp.GetPath(pack.PackId + ".unavailable"));
        await using var held = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var views = new RevisionedViewStore();
        await new BackupProjector(repository, views).ProjectOnceAsync();
        var revision = Assert.Single(Assert.Single(views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0)
            .Snapshot!.Sources).Revisions);
        Assert.Equal("Captured character", revision.CharacterName);
        Assert.False(revision.SurvivalPending);
    }

    [Fact]
    public async Task SummaryCollectorRetainsReadResultWhenWriterIsBusy()
    {
        using var temp = new TempDirectory();
        var options = await CreateOptionsAsync(temp);
        await new OneShotBackupService(new NoJournal()).RunAsync(options, "test");
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        var collector = new RevisionCharacterMetadataCollector(batchSize: 1);
        await using (var held = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            await collector.CollectOnceAsync(repository);
            Assert.False(Assert.Single(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources)
                .Revisions).CharacterMetadataRead);
            foreach (var pack in await repository.ReadPacksAsync())
                File.Move(Path.Combine(options.RepositoryPath, pack.RelativePath), temp.GetPath(pack.PackId + ".unavailable"));
        }
        await collector.CollectOnceAsync(repository);
        Assert.True(Assert.Single(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources)
            .Revisions).CharacterMetadataRead);
    }

    [Fact]
    public async Task PeriodicRecoveryDefersGarbageCollectionUntilOrphanCleanup()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var orphan = Path.Combine(repository.RepositoryPath, "packs", "unregistered.pzpack");
        await File.WriteAllTextAsync(orphan, "uncommitted");
        var saves = temp.GetPath("saves");
        Directory.CreateDirectory(saves);
        await new InterruptedOperationRecoveryService().RunUnderRepositoryLockAsync(repository, saves,
            collectGarbage: false);
        Assert.True(File.Exists(orphan));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        await new OrphanBackupCleanupService().RunAsync(repository, lease, saves);
        Assert.False(File.Exists(orphan));
    }

    [Fact]
    public async Task UnreadableSummaryCountsAgainstBatchAndDoesNotStarveFollowingRevision()
    {
        using var temp = new TempDirectory();
        var options = await CreateOptionsAsync(temp);
        var service = new OneShotBackupService(new NoJournal());
        await service.RunAsync(options, "test");
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = temp.GetPath("source/players.db"), Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "UPDATE localPlayers SET name='Second character';";
            await command.ExecuteNonQueryAsync();
        }
        await service.RunAsync(options, "test");
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        var source = await repository.GetSourceAsync("test");
        var first = (await repository.TryLocateRevisionFileAsync(source.SourceId, 1, "players.db"))!;
        File.Move(Path.Combine(repository.RepositoryPath, first.PackRelativePath), temp.GetPath("first.unavailable"));
        var collector = new RevisionCharacterMetadataCollector(batchSize: 1);
        await collector.CollectOnceAsync(repository);
        Assert.All(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions,
            item => Assert.False(item.CharacterMetadataRead));
        await collector.CollectOnceAsync(repository);
        var revisions = Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions;
        Assert.False(Assert.Single(revisions, item => item.Revision == 1).CharacterMetadataRead);
        Assert.True(Assert.Single(revisions, item => item.Revision == 2).CharacterMetadataRead);
        Assert.NotNull(Assert.Single(revisions, item => item.Revision == 1).CharacterMetadataError);
        var views = new RevisionedViewStore();
        await new BackupProjector(repository, views).ProjectOnceAsync();
        var failedView = views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0).Snapshot!
            .Sources.Single().Revisions.Single(item => item.Revision == 1);
        Assert.False(failedView.SurvivalPending);
        Assert.NotNull(failedView.CharacterMetadataError);
        File.Move(temp.GetPath("first.unavailable"), Path.Combine(repository.RepositoryPath, first.PackRelativePath));
        // A restart retries persisted failures and clears their diagnostic on success.
        await new RevisionCharacterMetadataCollector().CollectOnceAsync(repository);
        var repaired = Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources)
            .Revisions.Single(item => item.Revision == 1);
        Assert.True(repaired.CharacterMetadataRead);
        Assert.Null(repaired.CharacterMetadataError);
    }

    [Fact]
    public async Task ValidPackWithUnreadablePlayerDatabaseReportsSummaryFailureInsteadOfInfiniteLoading()
    {
        using var temp = new TempDirectory();
        var options = await CreateOptionsAsync(temp);
        await File.WriteAllTextAsync(temp.GetPath("source/players.db"), "not a SQLite database");
        await new OneShotBackupService(new NoJournal()).RunAsync(options, "test");
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        Assert.True((await new RepositoryVerifier().VerifyAsync(repository)).IsValid);
        await new RevisionCharacterMetadataCollector().CollectOnceAsync(repository);
        var views = new RevisionedViewStore();
        await new BackupProjector(repository, views).ProjectOnceAsync();
        var revision = Assert.Single(Assert.Single(views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0)
            .Snapshot!.Sources).Revisions);
        Assert.False(revision.SurvivalPending);
        Assert.Contains("SqliteException", revision.CharacterMetadataError);
    }

    [Fact]
    public async Task SurvivalDurationIsPersistedSeparatelyFromUnavailableDuration()
    {
        using var temp = new TempDirectory();
        var options = await CreateOptionsAsync(temp);
        await new OneShotBackupService(new NoJournal()).RunAsync(options, "test");
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        var source = await repository.GetSourceAsync("test");
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
            await repository.SetRevisionCharacterMetadataAsync(lease, source.SourceId, 1,
                "Captured character", "Alive", hoursSurvived: 17.25);
        var reopened = await RepositoryDatabase.OpenExistingAsync(repository.RepositoryPath);
        var summary = Assert.Single(Assert.Single((await reopened.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        Assert.True(summary.CharacterMetadataRead);
        Assert.Equal(17.25, summary.HoursSurvived);
    }

    private static async Task<BackupOptions> CreateOptionsAsync(TempDirectory temp)
    {
        Directory.CreateDirectory(temp.GetPath("source"));
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = temp.GetPath("source/players.db"), Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER, name TEXT, isDead INTEGER); "
                + "INSERT INTO localPlayers VALUES(1, 'Captured character', 0);";
            await command.ExecuteNonQueryAsync();
        }
        return BackupConfiguration.Parse("format_version = 1", temp.GetPath("repository"), temp.GetPath("config.toml"),
            new BackupOptionOverrides { Sources = [new("test", temp.GetPath("source"))] });
    }

    private sealed class NoJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new System.ComponentModel.Win32Exception(50);
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint, long upperUsnExclusive,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
