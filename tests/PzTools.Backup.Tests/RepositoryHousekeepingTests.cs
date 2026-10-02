using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Tests;

public sealed class RepositoryHousekeepingTests
{
    [Fact]
    public async Task SmallOldDeletion_IsDue_RecentDeletionAndHiddenBaselineAreNot()
    {
        using var temp = new TempDirectory();
        var repository = await CreateAsync(temp);
        await SeedVersionsAsync(repository);
        Assert.True(await repository.IsRevisionCompactionDueAsync(1, 20, TimeSpan.FromHours(1)));
        await ExecuteAsync(repository, "UPDATE revisions SET deleted_utc='2099-01-01T00:00:00+00:00' WHERE revision<4;");
        Assert.False(await repository.IsRevisionCompactionDueAsync(1, 20, TimeSpan.FromHours(1)));
        Assert.True(await repository.IsRevisionCompactionDueAsync(1, 2, TimeSpan.FromHours(1)));
        Assert.Empty(await repository.ReadSourcesDueForRevisionCompactionAsync(20, TimeSpan.FromHours(1)));
        await AssertHealthyAsync(repository);
    }

    [Fact]
    public async Task ClosedVersionCleanup_IsBounded_AndPreservesVisibleRevisionAndCurrentTombstone()
    {
        using var temp = new TempDirectory();
        var repository = await CreateAsync(temp);
        await SeedVersionsAsync(repository);
        var visible = await repository.ReadRevisionEntriesAsync(1, 1);
        var state = await repository.GetSourceStateAsync(1);
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var removed = 0;
        for (var i = 0; i < 6; i++)
        {
            var sweep = await repository.SweepUnreachableEntryVersionsAsync(lease, 1, 1);
            Assert.InRange(sweep.InspectedRows, 0, 1);
            removed += sweep.RemovedRows;
        }
        Assert.Equal(2, removed);
        Assert.Equal(visible, await repository.ReadRevisionEntriesAsync(1, 1));
        Assert.Equal(state, await repository.GetSourceStateAsync(1));
        Assert.Equal(1, await ScalarAsync(repository, "SELECT COUNT(*) FROM entry_versions WHERE valid_to_revision IS NULL AND tombstone=1;"));
        await AssertHealthyAsync(repository);
    }

    [Fact]
    public async Task PeriodicHousekeeping_ReclaimsInactiveSaveWithoutAnotherBackup_AndPreservesNextBaseline()
    {
        using var temp = new TempDirectory();
        var repository = await CreateAsync(temp);
        await SeedVersionsAsync(repository);
        var visible = await repository.ReadRevisionEntriesAsync(1, 1);
        var state = await repository.GetSourceStateAsync(1);
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var result = await new RepositoryHousekeepingService().RunAsync(repository, lease, null, 0,
            new MaintenanceOptions { Housekeeping = new(HistoryRetentionDays: 0, VacuumEnabled: false) });
        Assert.Equal(2, result.CompactedRevisions);
        Assert.Equal(1, await repository.CountDeletedRevisionsAsync(1));
        Assert.Equal(visible, await repository.ReadRevisionEntriesAsync(1, 1));
        Assert.Equal(state, await repository.GetSourceStateAsync(1));
        var run = await repository.StartRunAsync(lease, 1);
        var now = DateTimeOffset.UtcNow;
        await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(run.RunIndex, 1, null, [], [],
            [new EntryVersionRegistration("next", CatalogEntryKind.Directory, false, 0, now, now,
                FileAttributes.Directory, null, null, null)]));
        Assert.Equal(5, (await repository.GetSourceStateAsync(1)).CurrentRevision);
        Assert.Equal("next", Assert.Single(await repository.ReadRevisionEntriesAsync(1, 5)).RelativePath);
        Assert.Equal(visible, await repository.ReadRevisionEntriesAsync(1, 1));
        await AssertHealthyAsync(repository);
    }

    [Fact]
    public async Task HistoryCleanup_ProtectsReferencesRecentIdsLiveWorkAndUncertainTimestamps()
    {
        using var temp = new TempDirectory();
        var repository = await CreateAsync(temp);
        await SeedHistoryAsync(repository, 12);
        await ExecuteAsync(repository,
            """
            INSERT INTO revisions(source_id,revision,run_index,created_utc) VALUES(1,1,1,'2000-01-01T00:00:00+00:00');
            UPDATE source_state SET current_revision=1;
            INSERT INTO packs(pack_id,relative_path,format_version,byte_length,status,created_run_index,created_utc)
                VALUES(X'00000000000000000000000000000002','packs/protected.pzpack',1,1,'Committed',2,'2000-01-01T00:00:00+00:00');
            UPDATE workflow_runs SET status='Running' WHERE run_index=3;
            UPDATE workflow_stages SET status='Running' WHERE run_index=4;
            UPDATE workflow_runs SET completed_utc=NULL WHERE run_index=5;
            UPDATE workflow_stages SET completed_utc='2099-01-01T00:00:00+00:00' WHERE run_index=6;
            UPDATE workflow_runs SET completed_utc='unreadable' WHERE run_index=7;
            UPDATE workflow_stages SET completed_utc=NULL WHERE run_index=8;
            """);
        var nextRun = await ScalarAsync(repository, "SELECT next_run_index FROM repository_info;");
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var result = await repository.PruneCompletedHistoryAsync(lease, DateTimeOffset.UtcNow.AddDays(-90), 2);
        Assert.Equal(new CompletedHistoryCleanup(2, 2), result);
        Assert.Equal(0, await ScalarAsync(repository, "SELECT COUNT(*) FROM workflow_runs WHERE run_index IN (9,10);"));
        Assert.Equal(10, await ScalarAsync(repository, "SELECT COUNT(*) FROM workflow_runs;"));
        Assert.Equal(nextRun, await ScalarAsync(repository, "SELECT next_run_index FROM repository_info;"));
        await AssertHealthyAsync(repository);
    }

    [Fact]
    public async Task HistoryCleanup_BoundsBatches_AndCancellationRollsBack()
    {
        using var temp = new TempDirectory();
        var repository = await CreateAsync(temp);
        await SeedHistoryAsync(repository, 6);
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => repository.PruneCompletedHistoryAsync(
            lease, DateTimeOffset.UtcNow.AddDays(-90), 1, 2, new CancellationToken(true)));
        Assert.Equal(6, await ScalarAsync(repository, "SELECT COUNT(*) FROM workflow_stages;"));
        Assert.Equal(new CompletedHistoryCleanup(2, 2), await repository.PruneCompletedHistoryAsync(
            lease, DateTimeOffset.UtcNow.AddDays(-90), 1, 2));
        Assert.Equal(new CompletedHistoryCleanup(2, 2), await repository.PruneCompletedHistoryAsync(
            lease, DateTimeOffset.UtcNow.AddDays(-90), 1, 2));
        Assert.Equal(new CompletedHistoryCleanup(1, 1), await repository.PruneCompletedHistoryAsync(
            lease, DateTimeOffset.UtcNow.AddDays(-90), 1, 2));
        Assert.Equal(new CompletedHistoryCleanup(0, 0), await repository.PruneCompletedHistoryAsync(
            lease, DateTimeOffset.UtcNow.AddDays(-90), 1, 2));
        await AssertHealthyAsync(repository);
    }

    [Fact]
    public async Task HistoryRetention_CanBeDisabled()
    {
        using var temp = new TempDirectory();
        var repository = await CreateAsync(temp);
        await SeedHistoryAsync(repository, 6);
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var result = await new RepositoryHousekeepingService().RunAsync(repository, lease, null, 0,
            new MaintenanceOptions { Housekeeping = new(HistoryRetentionDays: 0, MinimumRetainedRuns: 1, VacuumEnabled: false) });
        Assert.Equal(new CompletedHistoryCleanup(0, 0), result.History);
        Assert.Equal(6, await ScalarAsync(repository, "SELECT COUNT(*) FROM workflow_runs;"));
        Assert.Equal("disabled", result.Vacuum.Status);
    }

    [Fact]
    public async Task Vacuum_ReclaimsSpaceWithoutChangingRetainedData()
    {
        using var temp = new TempDirectory();
        var repository = await CreateAsync(temp);
        await SeedVersionsAsync(repository);
        await MakeFreePagesAsync(repository);
        var visible = await repository.ReadRevisionEntriesAsync(1, 1);
        var state = await repository.GetSourceStateAsync(1);
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var result = await repository.TryVacuumAsync(lease, 0,
            new RepositoryHousekeepingOptions(VacuumMinimumFreeMib: 1, VacuumMinimumFreePercent: 1));
        Assert.Equal("compacted", result.Status);
        Assert.True(result.AfterBytes < result.BeforeBytes);
        Assert.True(result.CheckpointCompleted);
        Assert.Equal(visible, await repository.ReadRevisionEntriesAsync(1, 1));
        Assert.Equal(state, await repository.GetSourceStateAsync(1));
        await AssertHealthyAsync(repository);
    }

    [Fact]
    public async Task Vacuum_DefersForActiveWork_AndForConfiguredSizeLimit()
    {
        using var temp = new TempDirectory();
        var repository = await CreateAsync(temp);
        await SeedHistoryAsync(repository, 2);
        await MakeFreePagesAsync(repository);
        await ExecuteAsync(repository, "UPDATE workflow_runs SET status='Running' WHERE run_index=1;");
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var options = new RepositoryHousekeepingOptions(VacuumMinimumFreeMib: 1, VacuumMinimumFreePercent: 1);
        Assert.Equal("active-work", (await repository.TryVacuumAsync(lease, 0, options)).Status);
        Assert.Equal("database-size-limit", (await repository.TryVacuumAsync(
            lease, 0, options with { VacuumMaximumDatabaseMib = 1 })).Status);
        await AssertHealthyAsync(repository);
    }

    private static async Task<RepositoryDatabase> CreateAsync(TempDirectory temp)
    {
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", temp.GetPath("save"));
        Assert.Equal(1, source.SourceId);
        return repository;
    }

    private static async Task SeedHistoryAsync(RepositoryDatabase repository, int count)
    {
        for (var index = 1; index <= count; index++)
            await ExecuteAsync(repository, $"""
                INSERT INTO workflow_runs(run_index,pipeline,source_id,owner_component,status,started_utc,completed_utc)
                    VALUES({index},'backup',1,'fixture','Succeeded','2000-01-01T00:00:00+00:00','2000-01-01T00:00:00+00:00');
                INSERT INTO workflow_stages(run_index,producer,status,started_utc,completed_utc)
                    VALUES({index},'fixture','Succeeded','2000-01-01T00:00:00+00:00','2000-01-01T00:00:00+00:00');
                """);
        await ExecuteAsync(repository, "UPDATE repository_info SET next_run_index=10000;");
    }

    private static async Task SeedVersionsAsync(RepositoryDatabase repository)
    {
        await SeedHistoryAsync(repository, 4);
        await ExecuteAsync(repository, "INSERT INTO paths VALUES(1, 'A'); INSERT INTO path_spellings VALUES(1,0,'a');");
        for (var revision = 1; revision <= 4; revision++)
            await ExecuteAsync(repository, $"""
                INSERT INTO revisions(source_id,revision,run_index,created_utc,state,deleted_utc)
                    VALUES(1,{revision},{revision},'2000-01-01T00:00:00+00:00','{(revision == 1 ? "Active" : "Deleted")}','2000-01-01T00:00:00+00:00');
                INSERT INTO entry_versions(source_id,path_id,spelling_id,valid_from_revision,valid_to_revision,
                    entry_kind,tombstone,byte_length,modified_utc,changed_utc,attributes)
                    VALUES(1,1,0,{revision},{(revision == 4 ? "NULL" : (revision + 1).ToString(System.Globalization.CultureInfo.InvariantCulture))},
                        'Directory',{(revision == 4 ? 1 : 0)},0,630822816000000000,630822816000000000,16);
                """);
        await ExecuteAsync(repository, "UPDATE source_state SET current_revision=4;");
    }

    private static Task MakeFreePagesAsync(RepositoryDatabase repository) => ExecuteAsync(repository,
        "CREATE TABLE housekeeping_fixture(payload BLOB); INSERT INTO housekeeping_fixture VALUES(randomblob(8*1024*1024)); DROP TABLE housekeeping_fixture;");

    private static async Task ExecuteAsync(RepositoryDatabase repository, string sql)
    {
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<long> ScalarAsync(RepositoryDatabase repository, string sql)
    {
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(await command.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture);
    }

    private static async Task AssertHealthyAsync(RepositoryDatabase repository)
    {
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA foreign_key_check;";
        await using (var reader = await command.ExecuteReaderAsync()) Assert.False(await reader.ReadAsync());
        command.CommandText = "PRAGMA integrity_check;";
        Assert.Equal("ok", await command.ExecuteScalarAsync());
    }
}
