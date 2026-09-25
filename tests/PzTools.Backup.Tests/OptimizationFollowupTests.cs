using System.Security.Cryptography;
using Microsoft.Data.Sqlite;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class OptimizationFollowupTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FullScan_UsesIndexedAntiJoin_AndPreservesAddDeleteAndCaseChange(bool analyze)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        Directory.CreateDirectory(f.Source.RootPath);
        for (var i = 0; i < 40; i++) Directory.CreateDirectory(Path.Combine(f.Source.RootPath, $"folder{i:D2}"));
        var scanner = new StreamingFullScanner(new WindowsFileMetadataReader());
        await using (var initial = await scanner.ScanAsync(f.Repository, f.Source.SourceId, f.Source.RootPath))
        {
            var run = await f.Repository.StartRunAsync(f.Lease, f.Source.SourceId);
            await f.Repository.CommitInitialRevisionFromStagingAsync(f.Lease, initial.Connection,
                run.RunIndex, f.Source.SourceId, null, null);
        }
        var other = await f.Repository.AddOrGetSourceAsync(f.Lease, "Sandbox/Other", temp.GetPath("other"));
        await f.CommitForAsync(other, Dir("new-folder"));
        Directory.Delete(Path.Combine(f.Source.RootPath, "folder01"));
        Directory.Move(Path.Combine(f.Source.RootPath, "folder02"), Path.Combine(f.Source.RootPath, "temporary-name"));
        Directory.Move(Path.Combine(f.Source.RootPath, "temporary-name"), Path.Combine(f.Source.RootPath, "FOLDER02"));
        Directory.CreateDirectory(Path.Combine(f.Source.RootPath, "new-folder"));
        await using var scan = await scanner.ScanAsync(f.Repository, f.Source.SourceId, f.Source.RootPath);
        await using var command = scan.Connection.CreateCommand();
        if (analyze) { command.CommandText = "ANALYZE;"; await command.ExecuteNonQueryAsync(); }
        command.Parameters.AddWithValue("$sourceId", f.Source.SourceId);
        var plan = await PlanAsync(command, FullScanSession.ChangeEnumerationSql);
        Assert.Contains(plan, line => line.Contains("SEARCH live", StringComparison.Ordinal)
            && line.Contains("source_id=?", StringComparison.Ordinal) && line.Contains("path_id=?", StringComparison.Ordinal));
        Assert.DoesNotContain(plan, line => line.Contains("SCAN live", StringComparison.Ordinal));
        var changes = new List<FullScanChange>();
        await foreach (var change in scan.EnumerateChangesAsync()) changes.Add(change);
        Assert.Equal(3, changes.Count);
        Assert.Contains(changes, change => change.Kind == FullScanChangeKind.Added && change.Entry.RelativePath == "new-folder");
        Assert.Contains(changes, change => change.Kind == FullScanChangeKind.Deleted && change.Entry.RelativePath == "folder01");
        Assert.Contains(changes, change => change.Kind == FullScanChangeKind.Modified && change.Entry.RelativePath == "FOLDER02");
        await f.HealthyAsync();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RootRanges_PreserveUnicodeBoundariesWildcardsAndOverlapMultiplicity(bool analyze)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        string[] names = ["A", "A/child", "A/child/deeper", "A0/not-a-child", "AA/no", "100%_Save",
            "100%_Save/École", "100XYSave/no", "폴더", "폴더/école", "폴더/École/leaf", "missing-suffix"];
        await f.CommitForAsync(f.Source, names.Select(Dir).ToArray());
        string[] roots = ["a", "A/child", "a", "100%_save", "폴더/école", "missing"];
        var normalized = roots.Select(BackupPath.NormalizeRelative).Select(path => path.ToUpperInvariant()).Distinct().ToArray();
        var expected = names.SelectMany(name => normalized.Where(key => name.ToUpperInvariant() == key
                || name.ToUpperInvariant().StartsWith(key + "/", StringComparison.Ordinal)).Select(_ => name))
            .Order(StringComparer.Ordinal).ToArray();
        var actual = await f.Repository.ReadCurrentEntriesUnderRootsAsync(f.Source.SourceId, roots);
        Assert.Equal(expected, actual.Select(entry => entry.RelativePath).Order(StringComparer.Ordinal).ToArray());
        await using var connection = await f.Repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "CREATE TEMP TABLE requested_roots(path_key TEXT PRIMARY KEY) WITHOUT ROWID; INSERT INTO requested_roots VALUES('A');";
        await command.ExecuteNonQueryAsync();
        if (analyze) { command.CommandText = "ANALYZE;"; await command.ExecuteNonQueryAsync(); }
        command.Parameters.AddWithValue("$sourceId", f.Source.SourceId);
        var plan = await PlanAsync(command, RepositoryDatabase.CurrentEntriesLookupSql(RepositoryDatabase.RootsRangeFrom));
        Assert.Contains(plan, line => line.Contains("path_key>? AND path_key<?", StringComparison.Ordinal));
        Assert.DoesNotContain(plan, line => line.StartsWith("SCAN entry", StringComparison.Ordinal));
        await f.HealthyAsync();
    }

    [Fact]
    public async Task ThumbnailCache_SharesImmutableObjectsButRevalidatesTheRequestedRevision()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        byte[] png = [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4];
        await f.AddFilesAsync(("thumb.png", png));
        await f.CommitForAsync(f.Source, Dir("additional"));
        var cache = new ThumbnailCache(png.Length);
        var first = await cache.ReadRevisionThumbnailAsync("revision-one", f.Repository, f.Source.SourceId, 1);
        var second = await cache.ReadRevisionThumbnailAsync("revision-two", f.Repository, f.Source.SourceId, 2);
        Assert.Equal(png, first);
        Assert.Same(first, second);
        await f.Repository.MarkRevisionDeletedAsync(f.Lease, f.Source.SourceId, 1);
        Assert.Null(await cache.ReadRevisionThumbnailAsync("revision-one", f.Repository, f.Source.SourceId, 1));
        Assert.Same(second, await cache.ReadRevisionThumbnailAsync("still-two", f.Repository, f.Source.SourceId, 2));
        var changedPng = png.Select(value => value).ToArray();
        changedPng[^1] = 99;
        await f.AddFilesAsync(("thumb.png", changedPng));
        // A UI cache key must not override the repository/object identity.
        Assert.Equal(changedPng, await cache.ReadRevisionThumbnailAsync("revision-two", f.Repository, f.Source.SourceId, 3));
        Assert.Equal(png, await cache.ReadRevisionThumbnailAsync("revision-two", f.Repository, f.Source.SourceId, 2));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cache.ReadRevisionThumbnailAsync(
            "revision-two", f.Repository, f.Source.SourceId, 2, new CancellationToken(true)));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Restore_GroupsPacks_ClosesBeforeNextOpen_AndReleasesOnCancellation(bool cancel)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        var contents = new Dictionary<string, byte[]>();
        for (var i = 0; i < 6; i++)
        {
            var first = ($"a{i:D2}.bin", new byte[] { (byte)i, 1, 2, 3 });
            var second = ($"z{i:D2}.bin", new byte[] { (byte)i, 4, 5, 6 });
            contents.Add(first.Item1, first.Item2);
            contents.Add(second.Item1, second.Item2);
            await f.AddFilesAsync(first, second);
        }
        PackReader? previous = null;
        var opened = new HashSet<Guid>();
        var restorer = new RevisionRestorer(async (path, id, token) =>
        {
            if (previous is not null)
                await Assert.ThrowsAsync<ObjectDisposedException>(() => previous.CopyObjectAtAsync(Guid.Empty, 0, Stream.Null));
            Assert.True(opened.Add(id), "A pack was opened a second time despite grouping.");
            previous = await PackReader.OpenForLocatedReadsAsync(path, id, token);
            return previous;
        });
        var target = temp.GetPath("restored");
        using var cancellation = new CancellationTokenSource();
        Task RestoreAsync() => restorer.RestoreAsync(f.Repository, f.Source.SourceId, 6, target,
            (progress, _) =>
            {
                if (cancel && progress.Event == "file.restore.completed") cancellation.Cancel();
                return Task.CompletedTask;
            }, cancellation.Token);
        if (cancel) await Assert.ThrowsAnyAsync<OperationCanceledException>(RestoreAsync);
        else
        {
            await RestoreAsync();
            Assert.Equal(6, opened.Count);
            foreach (var item in contents)
                Assert.Equal(item.Value, await File.ReadAllBytesAsync(Path.Combine(target, item.Key)));
        }
        Assert.NotNull(previous);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => previous.CopyObjectAtAsync(Guid.Empty, 0, Stream.Null));
    }

    [Fact]
    public async Task EntryInspection_IsBoundedWhenNothingIsDead_ResumesAndRevisitsNewlyDeletedHistory()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        var entries = Enumerable.Range(0, 20).Select(i => Dir($"path{i:D2}")).ToArray();
        await f.CommitForAsync(f.Source, entries);
        await f.CommitForAsync(f.Source, entries);
        var expected = await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 2);
        var first = await f.Repository.SweepUnreachableEntryVersionsAsync(f.Lease, null, 3);
        Assert.Equal(new EntryVersionCollectionResult(3, 0), first);
        var reopened = await RepositoryDatabase.OpenExistingAsync(f.Repository.RepositoryPath);
        Assert.Equal(new EntryVersionCollectionResult(3, 0), await reopened.SweepUnreachableEntryVersionsAsync(f.Lease, null, 3));
        await f.Repository.MarkRevisionDeletedAsync(f.Lease, f.Source.SourceId, 1);
        var removed = 0;
        for (var i = 0; i < 35; i++)
        {
            var sweep = await reopened.SweepUnreachableEntryVersionsAsync(f.Lease, null, 3);
            Assert.InRange(sweep.InspectedRows, 0, 3);
            Assert.InRange(sweep.RemovedRows, 0, sweep.InspectedRows);
            removed += sweep.RemovedRows;
        }
        Assert.Equal(20, removed);
        Assert.Equal(expected, await reopened.ReadRevisionEntriesAsync(f.Source.SourceId, 2));
        Assert.Equal(20, await f.ScalarAsync("SELECT COUNT(*) FROM entry_versions;"));
        await f.HealthyAsync();
    }

    [Fact]
    public async Task EntrySweep_CursorFailureRollsBackDeletes_AndSourceScopeCannotDeleteOtherHistory()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        var other = await f.Repository.AddOrGetSourceAsync(f.Lease, "Sandbox/Other", temp.GetPath("other"));
        foreach (var source in new[] { f.Source, other })
        {
            await f.CommitForAsync(source, Dir("same"));
            await f.CommitForAsync(source, Dir("SAME"));
            await f.Repository.MarkRevisionDeletedAsync(f.Lease, source.SourceId, 1);
        }
        await f.ExecuteAsync("CREATE TRIGGER fail_cursor BEFORE UPDATE ON entry_gc_cursors BEGIN SELECT RAISE(ABORT, 'injected'); END;");
        await Assert.ThrowsAsync<SqliteException>(() => f.Repository.SweepUnreachableEntryVersionsAsync(f.Lease, f.Source.SourceId));
        Assert.Equal(4, await f.ScalarAsync("SELECT COUNT(*) FROM entry_versions;"));
        Assert.Equal(0, await f.ScalarAsync("SELECT COUNT(*) FROM entry_gc_cursors;"));
        await f.ExecuteAsync("DROP TRIGGER fail_cursor;");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.SweepUnreachableEntryVersionsAsync(
            f.Lease, f.Source.SourceId, cancellationToken: new CancellationToken(true)));
        Assert.Equal(4, await f.ScalarAsync("SELECT COUNT(*) FROM entry_versions;"));
        var result = await f.Repository.SweepUnreachableEntryVersionsAsync(f.Lease, f.Source.SourceId);
        Assert.Equal(new EntryVersionCollectionResult(4, 1), result);
        Assert.Equal(1, await f.ScalarAsync($"SELECT COUNT(*) FROM entry_versions WHERE source_id={other.SourceId} AND valid_to_revision IS NOT NULL;"));
        await f.HealthyAsync();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Schema4_IsRejectedWithoutMigrationOrMutation(bool createOrOpen)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.ExecuteAsync("UPDATE repository_info SET schema_version=4;");
        var before = SHA256.HashData(await File.ReadAllBytesAsync(f.Repository.DatabasePath));
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => createOrOpen
            ? RepositoryDatabase.CreateOrOpenAsync(f.Repository.RepositoryPath)
            : RepositoryDatabase.OpenExistingAsync(f.Repository.RepositoryPath));
        Assert.Contains("repository-reset-required", error.Message);
        Assert.Equal(before, SHA256.HashData(await File.ReadAllBytesAsync(f.Repository.DatabasePath)));
    }

    private static EntryVersionRegistration Dir(string path) => new(path, CatalogEntryKind.Directory,
        false, 0, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, FileAttributes.Directory, null, null, null);

    private static async Task<string[]> PlanAsync(SqliteCommand command, string sql)
    {
        command.CommandText = "EXPLAIN QUERY PLAN " + sql;
        var result = new List<string>();
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync()) result.Add(reader.GetString(3));
        return result.ToArray();
    }

    private sealed class Fixture(RepositoryDatabase repository, RepositoryWriterLease lease, RepositorySource source) : IAsyncDisposable
    {
        internal RepositoryDatabase Repository { get; } = repository;
        internal RepositoryWriterLease Lease { get; } = lease;
        internal RepositorySource Source { get; } = source;
        internal static async Task<Fixture> CreateAsync(TempDirectory temp)
        {
            var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
            var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
            try { return new(repository, lease, await repository.AddOrGetSourceAsync(lease, "Sandbox/Save", temp.GetPath("save"))); }
            catch { await lease.DisposeAsync(); throw; }
        }
        internal async Task CommitForAsync(RepositorySource source, params EntryVersionRegistration[] entries)
        {
            var run = await Repository.StartRunAsync(Lease, source.SourceId);
            await Repository.CommitRevisionAsync(Lease, new(run.RunIndex, source.SourceId, null, [], [], entries));
        }
        internal async Task AddFilesAsync(params (string Path, byte[] Bytes)[] files)
        {
            var run = await Repository.StartRunAsync(Lease, Source.SourceId);
            await using var writer = await PackWriter.CreateAsync(Repository.RepositoryPath, run.RunIndex);
            var objects = new List<StoredObjectRegistration>();
            var entries = new List<EntryVersionRegistration>();
            foreach (var file in files)
            {
                using var stream = new MemoryStream(file.Bytes, false);
                var descriptor = await writer.AddObjectAsync(stream, ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli);
                objects.Add(new(descriptor.ObjectId, writer.PackId, descriptor.RecordOffset, descriptor.StoredLength,
                    descriptor.OriginalLength, "Sha256", descriptor.Checksum, "Brotli"));
                entries.Add(new(file.Path, CatalogEntryKind.File, false, file.Bytes.Length, DateTimeOffset.UnixEpoch,
                    DateTimeOffset.UnixEpoch, FileAttributes.Normal, null, null, descriptor.ObjectId));
            }
            var pack = await writer.SealAndPromoteAsync();
            await Repository.CommitRevisionAsync(Lease, new(run.RunIndex, Source.SourceId, null,
                [new(pack.PackId, pack.RelativePath, PackWriter.CurrentFormatVersion, pack.ByteLength)], objects, entries));
        }
        internal async Task ExecuteAsync(string sql)
        {
            await using var connection = await Repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            await command.ExecuteNonQueryAsync();
        }
        internal async Task<long> ScalarAsync(string sql)
        {
            await using var connection = await Repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            return Convert.ToInt64(await command.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture);
        }
        internal async Task HealthyAsync()
        {
            await using var connection = await Repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA foreign_key_check;";
            await using (var reader = await command.ExecuteReaderAsync()) Assert.False(await reader.ReadAsync());
            command.CommandText = "PRAGMA integrity_check;";
            Assert.Equal("ok", await command.ExecuteScalarAsync());
        }
        public ValueTask DisposeAsync() => Lease.DisposeAsync();
    }
}
