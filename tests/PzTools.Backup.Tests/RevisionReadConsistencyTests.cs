using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Tests;

public sealed class RevisionReadConsistencyTests
{
    [Fact]
    public async Task RevisionReclaimedAfterExistenceCheck_StillReadsTheValidatedSnapshot()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "test", temp.GetPath("source"));
        var firstTime = DateTimeOffset.UtcNow;
        await CommitDirectoryAsync(repository, lease, source.SourceId, firstTime);
        await CommitDirectoryAsync(repository, lease, source.SourceId, firstTime.AddSeconds(1));

        // Separate processes do not share SQLite's in-process table locks. A private
        // reader cache reproduces that WAL concurrency without launching a process.
        await using var reader = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = repository.DatabasePath,
            Mode = SqliteOpenMode.ReadWrite,
            Cache = SqliteCacheMode.Private,
            Pooling = false,
        }.ToString());
        await reader.OpenAsync();
        var reclaimed = false;
        Exception? maintenanceFailure = null;
        SQLitePCL.strdelegate_trace trace = (_, sql) =>
        {
            if (reclaimed || !sql.Contains("SELECT entry.display_path, entry.entry_kind", StringComparison.Ordinal))
                return;
            reclaimed = true;
            try
            {
                repository.MarkRevisionDeletedAsync(lease, source.SourceId, 1).GetAwaiter().GetResult();
                repository.CompactDeletedRevisionsAsync(lease, source.SourceId).GetAwaiter().GetResult();
            }
            catch (Exception exception)
            {
                // Do not throw across SQLite's native callback boundary.
                maintenanceFailure = exception;
            }
        };
        SQLitePCL.raw.sqlite3_trace(reader.Handle, trace, null);
        var entries = await RepositoryDatabase.ReadRevisionEntriesCoreAsync(reader, source.SourceId, 1);
        GC.KeepAlive(trace);

        Assert.True(reclaimed);
        Assert.Null(maintenanceFailure);
        Assert.Equal(firstTime, Assert.Single(entries).ModifiedUtc);
        await Assert.ThrowsAsync<KeyNotFoundException>(() => repository.ReadRevisionEntriesAsync(source.SourceId, 1));
        Assert.Equal(firstTime.AddSeconds(1), Assert.Single(
            await repository.ReadRevisionEntriesAsync(source.SourceId, 2)).ModifiedUtc);
    }

    [Fact]
    public async Task ExistingEmptyRevision_IsDistinctFromAMissingRevision()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "test", temp.GetPath("source"));
        var run = await repository.StartRunAsync(lease, source.SourceId);
        await repository.CommitRevisionAsync(lease,
            new RevisionCommitRequest(run.RunIndex, source.SourceId, null, [], [], []));

        Assert.Empty(await repository.ReadRevisionEntriesAsync(source.SourceId, 1));
        await Assert.ThrowsAsync<KeyNotFoundException>(() => repository.ReadRevisionEntriesAsync(source.SourceId, 2));
    }

    internal static async Task CommitDirectoryAsync(
        RepositoryDatabase repository, RepositoryWriterLease lease, long sourceId, DateTimeOffset timestamp)
    {
        var run = await repository.StartRunAsync(lease, sourceId);
        await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(run.RunIndex, sourceId, null, [], [],
            [new EntryVersionRegistration("folder", CatalogEntryKind.Directory, false, 0,
                timestamp, timestamp, FileAttributes.Directory, null, null, null)]));
    }
}
