using System.Security.Cryptography;
using Microsoft.Data.Sqlite;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class NormalizedPathTests
{
    [Theory]
    [InlineData("Folder/File", "FOLDER/FILE")]
    [InlineData("폴더/école", "폴더/ÉCOLE")]
    [InlineData("100%_Save/Item", "100%_SAVE/ITEM")]
    public async Task CaseOnlyChanges_KeepIdentityAndHistoricalSpelling(string first, string second)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(f.Source, Dir(first));
        await f.CommitAsync(f.Source, Dir(second));
        await f.CommitAsync(f.Source, Dir(first));
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        Assert.Equal(2, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        Assert.Equal(3, await f.ScalarAsync("SELECT COUNT(*) FROM entry_versions;"));
        for (var revision = 1; revision <= 3; revision++)
            Assert.Equal(revision == 2 ? second : first,
                Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, revision)).RelativePath);
        Assert.Equal(first, Assert.Single(await f.Repository.ReadCurrentEntriesByPathsAsync(
            f.Source.SourceId, [second])).RelativePath);
        await f.Repository.MarkRevisionDeletedAsync(f.Lease, f.Source.SourceId, 2);
        await f.Repository.CompactDeletedRevisionsAsync(f.Lease, f.Source.SourceId);
        await f.Repository.CollectGarbageAsync(f.Lease);
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        Assert.Equal(first, Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 1)).RelativePath);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task SourceSharing_OrphanCleanupDoesNotDeleteAnotherSourcesNames()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        var other = await f.Repository.AddOrGetSourceAsync(f.Lease, "Sandbox/Other", temp.GetPath("absent-other"));
        await f.CommitAsync(f.Source, Dir("Mixed"));
        await f.CommitAsync(other, Dir("MIXED"));
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        Assert.Equal(2, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        await f.Repository.ReclaimOrphanSourceAsync(f.Lease, f.Source);
        await f.Repository.CollectGarbageAsync(f.Lease);
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        Assert.Equal("MIXED", Assert.Single(await f.Repository.ReadRevisionEntriesAsync(other.SourceId, 1)).RelativePath);
        await f.Repository.ReclaimOrphanSourceAsync(f.Lease, other);
        await f.Repository.CollectGarbageAsync(f.Lease);
        Assert.Equal(0, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        await f.CommitAsync(f.Source, Dir("Mixed"));
        Assert.Equal("Mixed", Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 2)).RelativePath);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task TombstoneAndHiddenLatest_KeepTheirDictionaryReferences()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(f.Source, Dir("Gone"));
        await f.CommitAsync(f.Source, Dir("Gone") with { Tombstone = true });
        await f.Repository.MarkRevisionDeletedAsync(f.Lease, f.Source.SourceId, 1);
        await f.Repository.MarkRevisionDeletedAsync(f.Lease, f.Source.SourceId, 2);
        await f.Repository.CompactDeletedRevisionsAsync(f.Lease, f.Source.SourceId);
        await f.Repository.PruneUnreachableEntryVersionsAsync(f.Lease, f.Source.SourceId);
        await f.Repository.CollectGarbageAsync(f.Lease);
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM entry_versions WHERE tombstone=1 AND valid_to_revision IS NULL;"));
        await f.CommitAsync(f.Source, Dir("GONE"));
        Assert.Equal("GONE", Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 3)).RelativePath);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task FailedIncrementalCommit_RollsBackNewPathsAndSpellings()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(f.Source, Dir("Before"));
        var run = await f.Repository.StartRunAsync(f.Lease, f.Source.SourceId);
        await Assert.ThrowsAsync<InvalidOperationException>(() => f.Repository.CommitRevisionAsync(f.Lease,
            new(run.RunIndex, f.Source.SourceId, null, [], [], [Dir("BEFORE"), Dir("New")]),
            beforeTransactionCommit: () => throw new InvalidOperationException("injected")));
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        Assert.Equal(1, (await f.Repository.GetSourceStateAsync(f.Source.SourceId)).CurrentRevision);
        Assert.Equal("Before", Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 1)).RelativePath);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task InitialScan_InternsOnlyInAtomicCommit_AndReusesOtherSourceDictionary()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(f.Source, Dir("folder"));
        var root = temp.GetPath("live-source");
        Directory.CreateDirectory(Path.Combine(root, "FOLDER"));
        var other = await f.Repository.AddOrGetSourceAsync(f.Lease, "Sandbox/Scan", root);
        await using var scan = await new StreamingFullScanner(new WindowsFileMetadataReader()).ScanAsync(
            f.Repository, other.SourceId, root);
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        var run = await f.Repository.StartRunAsync(f.Lease, other.SourceId);
        await Assert.ThrowsAsync<InvalidOperationException>(() => f.Repository.CommitInitialRevisionFromStagingAsync(
            f.Lease, scan.Connection, run.RunIndex, other.SourceId, null, null,
            beforeTransactionCommit: () => throw new InvalidOperationException("injected")));
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        await f.Repository.CommitInitialRevisionFromStagingAsync(f.Lease, scan.Connection,
            run.RunIndex, other.SourceId, null, null);
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        Assert.Equal(2, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        Assert.Equal("folder", Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 1)).RelativePath);
        Assert.Equal("FOLDER", Assert.Single(await f.Repository.ReadRevisionEntriesAsync(other.SourceId, 1)).RelativePath);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task RealBackup_CaseRenameAndFileMove_RestoreEachRevisionAndSurviveCompaction()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        var root = f.Source.RootPath;
        Directory.CreateDirectory(Path.Combine(root, "Folder"));
        await File.WriteAllTextAsync(Path.Combine(root, "Folder", "item.bin"), "before");
        var metadata = new WindowsFileMetadataReader();
        var telemetry = await TelemetryStore.CreateOrOpenAsync(f.Repository.RepositoryPath);
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, false);
        var trace = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
            new NoCheckpoint()).RunAsync(f.Repository, telemetry, f.Lease, f.Source, storage, trace);
        Directory.Move(Path.Combine(root, "Folder"), Path.Combine(root, "rename-temporary"));
        Directory.Move(Path.Combine(root, "rename-temporary"), Path.Combine(root, "FOLDER"));
        await File.WriteAllTextAsync(Path.Combine(root, "FOLDER", "item.bin"), "after!");
        var runner = new IncrementalBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
            metadata, new NoJournal(), new UsnDeltaPlanner());
        Assert.Equal(2, (await runner.RunAsync(f.Repository, telemetry, f.Lease, f.Source, storage, trace)).Revision);
        Assert.Null((await runner.RunAsync(f.Repository, telemetry, f.Lease, f.Source, storage, trace)).Revision);
        var first = temp.GetPath("restore-1");
        var second = temp.GetPath("restore-2");
        await new RevisionRestorer().RestoreAsync(f.Repository, f.Source.SourceId, 1, first);
        await new RevisionRestorer().RestoreAsync(f.Repository, f.Source.SourceId, 2, second);
        Assert.Equal("Folder", Path.GetFileName(Assert.Single(Directory.GetDirectories(first))));
        Assert.Equal("FOLDER", Path.GetFileName(Assert.Single(Directory.GetDirectories(second))));
        Assert.Equal("before", await File.ReadAllTextAsync(Path.Combine(first, "Folder", "item.bin")));
        Assert.Equal("after!", await File.ReadAllTextAsync(Path.Combine(second, "FOLDER", "item.bin")));
        Assert.NotNull(await f.Repository.TryLocateRevisionFileAsync(f.Source.SourceId, 1, "folder/ITEM.BIN"));
        File.Move(Path.Combine(root, "FOLDER", "item.bin"), Path.Combine(root, "moved.bin"));
        Assert.Equal(3, (await runner.RunAsync(f.Repository, telemetry, f.Lease, f.Source, storage, trace)).Revision);
        await f.Repository.MarkRevisionDeletedAsync(f.Lease, f.Source.SourceId, 2);
        await f.Repository.CompactDeletedRevisionsAsync(f.Lease, f.Source.SourceId);
        await f.Repository.CollectGarbageAsync(f.Lease);
        var third = temp.GetPath("restore-3");
        await new RevisionRestorer().RestoreAsync(f.Repository, f.Source.SourceId, 3, third);
        Assert.Equal("after!", await File.ReadAllTextAsync(Path.Combine(third, "moved.bin")));
        Assert.False(File.Exists(Path.Combine(third, "FOLDER", "item.bin")));
        Assert.True((await new RepositoryVerifier().VerifyAsync(f.Repository)).IsValid);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task Roots_AreSegmentBoundedAndTreatWildcardsLiterally()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(f.Source, Dir("A%_"), Dir("A%_/child"), Dir("A%_suffix"), Dir("AXY/child"));
        var entries = await f.Repository.ReadCurrentEntriesUnderRootsAsync(f.Source.SourceId, ["a%_"]);
        Assert.Equal(new[] { "A%_", "A%_/child" }, entries.Select(e => e.RelativePath).ToArray());
        await f.HealthyAsync();
    }

    [Fact]
    public async Task ImmutableDictionariesAndCompositeForeignKey_RejectHistoryRewrites()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(f.Source, Dir("Before"), Dir("Other"));
        foreach (var sql in new[] {
            "UPDATE paths SET path_key='CHANGED';",
            "UPDATE path_spellings SET display_path='changed';",
            "UPDATE entry_versions SET spelling_id=999;",
            "DELETE FROM path_spellings;" })
        {
            var error = await Assert.ThrowsAsync<SqliteException>(() => f.ExecuteAsync(sql));
            Assert.Equal(19, error.SqliteErrorCode);
        }
        Assert.Equal(2, (await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 1)).Count);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task SameCanonicalPathTwiceInOneCommit_FailsAtomically()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await Assert.ThrowsAsync<ArgumentException>(() => f.CommitAsync(f.Source, Dir("File"), Dir("FILE")));
        Assert.Equal(0, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        Assert.Equal(0, (await f.Repository.GetSourceStateAsync(f.Source.SourceId)).CurrentRevision);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task PathCollection_IsBoundedCancellableAndDrainsWithoutNewDeletions()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(f.Source, Dir("Keep"));
        await using (var connection = await f.Repository.OpenConnectionAsync())
        using (var transaction = connection.BeginTransaction())
        {
            await using var paths = new RepositoryPathWriter(connection, transaction);
            for (var i = 0; i < 5; i++) await paths.InternAsync($"unreferenced-{i}");
            transaction.Commit();
        }
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.PruneUnreferencedPathsAsync(
            f.Lease, 3, new CancellationToken(true)));
        Assert.Equal(6, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        var removed = await f.Repository.PruneUnreferencedPathsAsync(f.Lease, 3);
        Assert.InRange(removed, 0, 3);
        var options = new MaintenanceOptions { Housekeeping = new(HistoryRetentionDays: 0, BatchSize: 3, VacuumEnabled: false) };
        for (var i = 0; i < 30; i++)
        {
            var result = await new RepositoryHousekeepingService().RunAsync(f.Repository, f.Lease, null, 0, options);
            Assert.InRange(result.InspectedPathRows, 0, 3);
            Assert.InRange(result.RemovedPathRows, 0, result.InspectedPathRows);
            removed += result.RemovedPathRows;
        }
        Assert.Equal(10, removed);
        Assert.Equal(1, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        Assert.Equal("Keep", Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 1)).RelativePath);
        await f.HealthyAsync();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task PreviousSchema2_IsRejectedWithoutChangingItsDatabase(bool createOrOpen)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.ExecuteAsync("UPDATE repository_info SET schema_version=2;");
        var before = SHA256.HashData(await File.ReadAllBytesAsync(f.Repository.DatabasePath));
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => createOrOpen
            ? RepositoryDatabase.CreateOrOpenAsync(f.Repository.RepositoryPath)
            : RepositoryDatabase.OpenExistingAsync(f.Repository.RepositoryPath));
        Assert.Contains("repository-reset-required", error.Message);
        Assert.Equal(before, SHA256.HashData(await File.ReadAllBytesAsync(f.Repository.DatabasePath)));
    }

    private static EntryVersionRegistration Dir(string path) => new(path, CatalogEntryKind.Directory, false,
        0, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, FileAttributes.Directory, null, null, null);

    private sealed class Fixture(RepositoryDatabase repository, RepositoryWriterLease lease, RepositorySource source) : IAsyncDisposable
    {
        internal RepositoryDatabase Repository { get; } = repository;
        internal RepositoryWriterLease Lease { get; } = lease;
        internal RepositorySource Source { get; } = source;
        internal static async Task<Fixture> CreateAsync(TempDirectory temp)
        {
            var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
            var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
            var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", temp.GetPath("save"));
            return new(repository, lease, source);
        }
        internal async Task CommitAsync(RepositorySource source, params EntryVersionRegistration[] entries)
        {
            var run = await Repository.StartRunAsync(Lease, source.SourceId);
            await Repository.CommitRevisionAsync(Lease, new(run.RunIndex, source.SourceId, null, [], [], entries));
        }
        internal async Task ExecuteAsync(string sql)
        {
            await using var connection = await Repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand(); command.CommandText = sql;
            await command.ExecuteNonQueryAsync();
        }
        internal async Task<long> ScalarAsync(string sql)
        {
            await using var connection = await Repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand(); command.CommandText = sql;
            return Convert.ToInt64(await command.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture);
        }
        internal async Task HealthyAsync()
        {
            await using var connection = await Repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand(); command.CommandText = "PRAGMA foreign_key_check;";
            await using (var reader = await command.ExecuteReaderAsync()) Assert.False(await reader.ReadAsync());
            command.CommandText = "PRAGMA integrity_check;";
            Assert.Equal("ok", await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM pragma_table_info('entry_versions') WHERE name IN ('path_key','display_path');";
            Assert.Equal(0L, await command.ExecuteScalarAsync());
        }
        public ValueTask DisposeAsync() => Lease.DisposeAsync();
    }

    private sealed class NoCheckpoint : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(null, "path regression");
    }
    private sealed class NoJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new PlatformNotSupportedException("path regression");
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint, long upperUsnExclusive,
            CancellationToken cancellationToken = default) => throw new InvalidOperationException("Full scan required.");
    }
}
