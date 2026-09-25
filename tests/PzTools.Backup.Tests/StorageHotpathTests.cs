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

public sealed class StorageHotpathTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SmallRequestPlans_UseBothIndexKeys_BeforeAndAfterAnalyze(bool analyze)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(Enumerable.Range(1, 200).Select(Entry).ToArray());
        await using var connection = await f.Repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "CREATE TEMP TABLE requested_paths(path_key TEXT PRIMARY KEY) WITHOUT ROWID;"
            + "INSERT INTO requested_paths VALUES('ITEM00001');"
            + "CREATE TEMP TABLE requested_file_references(value BLOB PRIMARY KEY) WITHOUT ROWID;"
            + "INSERT INTO requested_file_references VALUES(X'00000000000000000000000000000001');";
        await command.ExecuteNonQueryAsync();
        if (analyze) { command.CommandText = "ANALYZE;"; await command.ExecuteNonQueryAsync(); }
        command.Parameters.AddWithValue("$sourceId", f.Source.SourceId);
        var paths = await PlanAsync(command, RepositoryDatabase.CurrentEntriesLookupSql(RepositoryDatabase.PathsRequestFirstFrom));
        Assert.Contains(paths, row => row.Contains("SEARCH entry", StringComparison.Ordinal)
            && row.Contains("source_id=?", StringComparison.Ordinal) && row.Contains("path_id=?", StringComparison.Ordinal));
        Assert.DoesNotContain(paths, row => row.StartsWith("SCAN entry", StringComparison.Ordinal));
        var large = await PlanAsync(command, RepositoryDatabase.CurrentEntriesLookupSql(RepositoryDatabase.PathsScanFrom));
        Assert.Contains(large, row => row.Contains("ix_entry_versions_current", StringComparison.Ordinal));
        Assert.DoesNotContain(large, row => row.Contains("ix_entry_versions_revision_start", StringComparison.Ordinal));
        var refs = await PlanAsync(command, RepositoryDatabase.TrackedPathsRequestFirstSql);
        Assert.Contains(refs, row => row.Contains("ix_entry_versions_current_file_reference", StringComparison.Ordinal)
            && row.Contains("source_id=?", StringComparison.Ordinal) && row.Contains("<expr>=?", StringComparison.Ordinal));
        Assert.DoesNotContain(refs, row => row.StartsWith("SCAN entry", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(10)]
    [InlineData(1100)]
    public async Task RequestedPathsAndReferences_PreserveResultsAcrossQueryStrategies(int requested)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        var all = Enumerable.Range(1, 1200).Select(Entry).ToArray();
        await f.CommitAsync(all);
        var other = await f.Repository.AddOrGetSourceAsync(f.Lease, "Sandbox/Other", temp.GetPath("other"));
        var otherRun = await f.Repository.StartRunAsync(f.Lease, other.SourceId);
        await f.Repository.CommitRevisionAsync(f.Lease, new(otherRun.RunIndex, other.SourceId, null, [], [], all));
        await f.CommitAsync(Entry(2) with { Tombstone = true }, Entry(3) with { RelativePath = "ITEM00003" });
        var input = Enumerable.Range(1, requested).Select(i => $"item{i:D5}")
            .Concat(["item00001", "missing"]).ToArray();
        var actual = await f.Repository.ReadCurrentEntriesByPathsAsync(f.Source.SourceId, input);
        var expected = (await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 2))
            .Where(e => input.Contains(e.RelativePath, StringComparer.OrdinalIgnoreCase))
            .Select(e => e.RelativePath).Order(StringComparer.Ordinal).ToArray();
        Assert.Equal(expected, actual.Select(e => e.RelativePath).Order(StringComparer.Ordinal).ToArray());
        Assert.Contains(actual, e => e.RelativePath == "ITEM00003");
        Assert.DoesNotContain(actual, e => e.RelativePath == "item00002");
        var refs = Enumerable.Range(1, requested).Select(i => $"{i:X32}")
            .Concat([$"{1:X32}", $"{999999:X32}"]).ToArray();
        var tracked = await f.Repository.ReadCurrentTrackedPathsAsync(f.Source.SourceId, refs);
        Assert.Equal(expected, tracked.Select(e => e.RelativePath).Order(StringComparer.Ordinal).ToArray());
        Assert.Equal(1200, (await f.Repository.ReadRevisionEntriesAsync(other.SourceId, 1)).Count);
        Assert.Empty(await f.Repository.ReadCurrentEntriesByPathsAsync(f.Source.SourceId, []));
        Assert.Empty(await f.Repository.ReadCurrentTrackedPathsAsync(f.Source.SourceId, []));
        await f.HealthyAsync();
    }

    [Fact]
    public async Task TempScanBatch_DoesNotReserveMainDatabaseWriter()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        Directory.CreateDirectory(f.Source.RootPath);
        await File.WriteAllTextAsync(Path.Combine(f.Source.RootPath, "one"), "a");
        await File.WriteAllTextAsync(Path.Combine(f.Source.RootPath, "two"), "b");
        await f.ExecuteAsync("CREATE TABLE concurrent_fixture(value INTEGER); INSERT INTO concurrent_fixture VALUES(0);");
        await using var writer = await f.Repository.OpenConnectionAsync();
        writer.DefaultTimeout = 1;
        var writes = 0;
        await using var scan = await new StreamingFullScanner(new WindowsFileMetadataReader(), 100).ScanAsync(
            f.Repository, f.Source.SourceId, f.Source.RootPath, progress: async _ =>
            {
                // The scanner's batch is still open when it reports progress.
                using var transaction = writer.BeginTransaction();
                await using var update = writer.CreateCommand();
                update.Transaction = transaction;
                update.CommandTimeout = 1;
                update.CommandText = "UPDATE concurrent_fixture SET value=value+1;";
                await update.ExecuteNonQueryAsync();
                transaction.Commit();
                writes++;
            });
        Assert.Equal(2, writes);
        Assert.Equal(2, scan.EntryCount);
        Assert.Equal(2, await f.ScalarAsync("SELECT value FROM concurrent_fixture;"));
        Assert.Equal(0, await f.ScalarAsync("SELECT COUNT(*) FROM entry_versions;"));
    }

    [Theory]
    [InlineData("paths")]
    [InlineData("references")]
    [InlineData("roots")]
    [InlineData("locator")]
    public async Task ReadAndTempQueries_CanCompleteWhileUnrelatedWriterIsHeld(string operation)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        Directory.CreateDirectory(f.Source.RootPath);
        await File.WriteAllTextAsync(Path.Combine(f.Source.RootPath, "value.bin"), "read-only locator");
        var metadata = new WindowsFileMetadataReader();
        await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata), new NoCheckpoint())
            .RunAsync(f.Repository, TelemetryStore.CreateDisabled(f.Repository.RepositoryPath), f.Lease, f.Source,
                new(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false), new(TelemetryMode.Off, 8, 5, 10, 32));
        var file = Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 1));
        await f.ExecuteAsync("CREATE TABLE concurrent_fixture(value INTEGER); INSERT INTO concurrent_fixture VALUES(0);");
        await using var writer = await f.Repository.OpenConnectionAsync();
        using var held = writer.BeginTransaction();
        await using var update = writer.CreateCommand();
        update.Transaction = held;
        update.CommandText = "UPDATE concurrent_fixture SET value=1;";
        await update.ExecuteNonQueryAsync();
        var read = Task.Run(async () =>
        {
            switch (operation)
            {
                case "paths": Assert.Single(await f.Repository.ReadCurrentEntriesByPathsAsync(f.Source.SourceId, ["value.bin"])); break;
                case "references": Assert.Single(await f.Repository.ReadCurrentTrackedPathsAsync(f.Source.SourceId,
                    [Convert.ToHexString(file.FileId!.AsSpan(8))])); break;
                case "roots": Assert.Single(await f.Repository.ReadCurrentEntriesUnderRootsAsync(f.Source.SourceId, ["value.bin"])); break;
                case "locator": Assert.NotNull(await f.Repository.TryLocateRevisionFileAsync(f.Source.SourceId, 1, "VALUE.BIN")); break;
                default: throw new ArgumentException(operation);
            }
        });
        try { await read.WaitAsync(TimeSpan.FromSeconds(10)); }
        finally
        {
            held.Rollback();
            // Never abandon a background SQL call when a failing implementation times out.
            await read.WaitAsync(TimeSpan.FromSeconds(10));
        }
        await f.HealthyAsync();
    }

    [Fact]
    public async Task MaintenancePredicates_UsePackAndRevisionIndexes()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await using var connection = await f.Repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        var packs = await PlanAsync(command,
            "SELECT relative_path FROM packs WHERE NOT EXISTS (SELECT 1 FROM stored_objects WHERE pack_id=packs.pack_id);");
        Assert.Contains(packs, row => row.Contains("ix_stored_objects_pack", StringComparison.Ordinal));
        Assert.DoesNotContain(packs, row => row.Contains("SCAN stored_objects", StringComparison.Ordinal));
        var start = await PlanAsync(command, "SELECT * FROM entry_versions WHERE source_id=1 AND valid_from_revision=2;");
        Assert.Contains(start, row => row.Contains("ix_entry_versions_revision_start", StringComparison.Ordinal));
        var end = await PlanAsync(command, "SELECT * FROM entry_versions WHERE source_id=1 AND valid_to_revision=2;");
        Assert.Contains(end, row => row.Contains("ix_entry_versions_revision_end", StringComparison.Ordinal));
        command.Parameters.AddWithValue("$afterPath", 4);
        command.Parameters.AddWithValue("$afterSpelling", 0);
        command.Parameters.AddWithValue("$limit", 3);
        var sweep = await PlanAsync(command, RepositoryDatabase.PathSpellingWindowSql);
        Assert.Contains(sweep, row => row.StartsWith("SEARCH spelling", StringComparison.Ordinal));
        Assert.Contains(sweep, row => row.Contains("ix_entry_versions_spelling", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(3)]
    [InlineData(16)]
    public async Task PathInspection_ResumesAcrossOpeningsAndRevisitsEarlierFreedRows(int budget)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(Enumerable.Range(1, 20).Select(Entry).ToArray());
        await f.AddUnusedAsync(4);
        var removed = 0;
        var sawLiveOnlyPage = false;
        for (var i = 0; i < 180 && removed < 8; i++)
        {
            var reopened = await RepositoryDatabase.OpenExistingAsync(f.Repository.RepositoryPath);
            var page = await reopened.SweepUnreferencedPathsAsync(f.Lease, budget);
            Assert.InRange(page.InspectedRows, 0, budget);
            Assert.InRange(page.RemovedRows, 0, page.InspectedRows);
            sawLiveOnlyPage |= page.InspectedRows > 0 && page.RemovedRows == 0;
            removed += page.RemovedRows;
        }
        Assert.True(sawLiveOnlyPage);
        Assert.Equal(8, removed);
        Assert.Equal(20, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        // Free names below an already advanced cursor; wrap-around must find them.
        await f.Repository.ReclaimOrphanSourceAsync(f.Lease, f.Source);
        for (var i = 0; i < 180 && removed < 48; i++)
        {
            var page = await f.Repository.SweepUnreferencedPathsAsync(f.Lease, budget);
            Assert.InRange(page.InspectedRows, 0, budget);
            removed += page.RemovedRows;
        }
        Assert.Equal(48, removed);
        Assert.Equal(0, await f.ScalarAsync("SELECT COUNT(*) FROM paths;"));
        await f.HealthyAsync();
    }

    [Fact]
    public async Task CursorFailureAndCancellation_RollBackProgressAndDeletions()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.AddUnusedAsync(3);
        await f.ExecuteAsync("CREATE TRIGGER cursor_failure BEFORE UPDATE ON path_gc_cursor BEGIN SELECT RAISE(ABORT,'injected'); END;");
        await Assert.ThrowsAsync<SqliteException>(() => f.Repository.SweepUnreferencedPathsAsync(f.Lease, 100));
        Assert.Equal(3, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        Assert.Equal(long.MinValue, await f.ScalarAsync("SELECT spelling_path_id FROM path_gc_cursor;"));
        await f.ExecuteAsync("DROP TRIGGER cursor_failure;");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.SweepUnreferencedPathsAsync(f.Lease, 100, new CancellationToken(true)));
        Assert.Equal(long.MinValue, await f.ScalarAsync("SELECT spelling_path_id FROM path_gc_cursor;"));
        Assert.Equal(6, (await f.Repository.SweepUnreferencedPathsAsync(f.Lease, 100)).RemovedRows);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task Housekeeping_GarbageCollectionAndPathSweepShareOneInspectionBudget()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.CommitAsync(Entry(1));
        await f.CommitAsync(Entry(1) with { RelativePath = "ITEM00001" });
        await f.Repository.MarkRevisionDeletedAsync(f.Lease, f.Source.SourceId, 1);
        await f.ExecuteAsync("UPDATE revisions SET deleted_utc='2000-01-01T00:00:00Z' WHERE state='Deleted';");
        await f.AddUnusedAsync(20);
        var result = await new RepositoryHousekeepingService().RunAsync(f.Repository, f.Lease, null, 0,
            new MaintenanceOptions { Housekeeping = new(HistoryRetentionDays: 0, BatchSize: 3, VacuumEnabled: false) });
        Assert.Equal(1, result.CompactedRevisions); // Exercises the object-GC branch too.
        Assert.InRange(result.InspectedPathRows, 0, 3);
        Assert.InRange(result.RemovedPathRows, 0, result.InspectedPathRows);
        Assert.True(await f.ScalarAsync("SELECT COUNT(*) FROM paths;") >= 18);
        Assert.Equal("ITEM00001", Assert.Single(await f.Repository.ReadRevisionEntriesAsync(f.Source.SourceId, 2)).RelativePath);
        await f.HealthyAsync();
    }

    [Fact]
    public async Task OrphanCleanup_CanDeferItsDictionaryPassToHousekeeping()
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        var saves = temp.GetPath("Saves");
        Directory.CreateDirectory(saves);
        await f.AddUnusedAsync(20);
        await new OrphanBackupCleanupService().RunAsync(f.Repository, f.Lease, saves, collectPaths: false);
        Assert.Equal(20, await f.ScalarAsync("SELECT COUNT(*) FROM path_spellings;"));
        Assert.Equal(long.MinValue, await f.ScalarAsync("SELECT spelling_path_id FROM path_gc_cursor;"));
        var result = await new RepositoryHousekeepingService().RunAsync(f.Repository, f.Lease, null, 0,
            new MaintenanceOptions { Housekeeping = new(HistoryRetentionDays: 0, BatchSize: 3, VacuumEnabled: false) });
        Assert.InRange(result.InspectedPathRows, 0, 3);
        Assert.InRange(result.RemovedPathRows, 1, 3);
        await f.HealthyAsync();
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Schema3RequiresFreshRepository_WithoutMutatingOldFile(bool createOrOpen)
    {
        using var temp = new TempDirectory();
        await using var f = await Fixture.CreateAsync(temp);
        await f.ExecuteAsync("UPDATE repository_info SET schema_version=3;");
        var original = SHA256.HashData(await File.ReadAllBytesAsync(f.Repository.DatabasePath));
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => createOrOpen
            ? RepositoryDatabase.CreateOrOpenAsync(f.Repository.RepositoryPath)
            : RepositoryDatabase.OpenExistingAsync(f.Repository.RepositoryPath));
        Assert.Contains("repository-reset-required", error.Message);
        Assert.Equal(original, SHA256.HashData(await File.ReadAllBytesAsync(f.Repository.DatabasePath)));
    }

    private static EntryVersionRegistration Entry(int i) => new($"item{i:D5}", CatalogEntryKind.Directory, false, 0,
        DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, FileAttributes.Directory,
        FileIdentityCodec.Encode($"0000000000000001:{i:X32}"), FileIdentityCodec.Encode($"0000000000000001:{999999:X32}"), null);

    private static async Task<string[]> PlanAsync(SqliteCommand command, string sql)
    {
        command.CommandText = "EXPLAIN QUERY PLAN " + sql;
        var rows = new List<string>();
        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync()) rows.Add(reader.GetString(3));
        return rows.ToArray();
    }

    private sealed class NoCheckpoint : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(null, "isolated fixture");
    }

    private sealed class Fixture(RepositoryDatabase repository, RepositoryWriterLease lease, RepositorySource source) : IAsyncDisposable
    {
        internal RepositoryDatabase Repository => repository;
        internal RepositoryWriterLease Lease => lease;
        internal RepositorySource Source => source;
        internal static async Task<Fixture> CreateAsync(TempDirectory temp)
        {
            var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
            var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
            try
            {
                var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", temp.GetPath("source"));
                return new(repository, lease, source);
            }
            catch { await lease.DisposeAsync(); throw; }
        }
        internal async Task CommitAsync(params EntryVersionRegistration[] entries)
        {
            var run = await repository.StartRunAsync(lease, source.SourceId);
            await repository.CommitRevisionAsync(lease, new(run.RunIndex, source.SourceId, null, [], [], entries));
        }
        internal async Task AddUnusedAsync(int count)
        {
            await using var connection = await repository.OpenConnectionAsync();
            using var transaction = connection.BeginTransaction();
            await using var paths = new RepositoryPathWriter(connection, transaction);
            for (var i = 0; i < count; i++) await paths.InternAsync($"unreferenced-{i}");
            transaction.Commit();
        }
        internal async Task ExecuteAsync(string sql)
        {
            await using var connection = await repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            await command.ExecuteNonQueryAsync();
        }
        internal async Task<long> ScalarAsync(string sql)
        {
            await using var connection = await repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            return Convert.ToInt64(await command.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture);
        }
        internal async Task HealthyAsync()
        {
            await using var connection = await repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "PRAGMA foreign_key_check;";
            await using (var reader = await command.ExecuteReaderAsync()) Assert.False(await reader.ReadAsync());
            command.CommandText = "PRAGMA integrity_check;";
            Assert.Equal("ok", await command.ExecuteScalarAsync());
        }
        public ValueTask DisposeAsync() => lease.DisposeAsync();
    }
}
