using System.Buffers;
using System.Security.Cryptography;
using Microsoft.Data.Sqlite;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class StoragePerformanceTests
{
    [Theory]
    [InlineData(false, false, CompressionAlgorithm.None)]
    [InlineData(false, true, CompressionAlgorithm.Brotli)]
    [InlineData(true, false, CompressionAlgorithm.Brotli)]
    [InlineData(true, true, CompressionAlgorithm.None)]
    public async Task RepeatedContent_NeverEntersCompressionOrAppendsAnotherObject(
        bool verify, bool fingerprint, CompressionAlgorithm compression)
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var source = temp.GetPath("source");
        var content = new byte[384 * 1024 + 19];
        new Random(410).NextBytes(content);
        await File.WriteAllBytesAsync(source, content);
        await using var capture = new DeduplicatingFileCapturer(new StableFileCapturer(new WindowsFileMetadataReader(),
            verifyStagedCopies: verify, recordContentHash: fingerprint));
        await using var writer = await PackWriter.CreateAsync(repository.RepositoryPath, 1);
        var first = await capture.CaptureAsync(repository, source, writer, ChecksumAlgorithm.Sha256, compression, true);
        Assert.Equal(SHA256.HashData(content), first.Capture.Object.Checksum);
        for (var i = 0; i < 4; i++)
        {
            var repeated = await capture.CaptureAsync(repository, source, writer, ChecksumAlgorithm.Sha256,
                compression, true, progress: value =>
                {
                    Assert.NotEqual("capture", value.Phase);
                    return ValueTask.CompletedTask;
                });
            Assert.True(repeated.Reused);
            Assert.Equal(first.Capture.Object.ObjectId, repeated.Capture.Object.ObjectId);
            Assert.Equal(fingerprint ? 16 : 0, repeated.Capture.ContentHash?.Length ?? 0);
        }
        Assert.Equal(1, writer.ObjectCount);
        var pack = await writer.SealAndPromoteAsync();
        await using var reader = await PackReader.OpenAsync(pack.FullPath, verifyPayloads: true);
        await using var restored = new MemoryStream();
        await reader.CopyObjectToAsync(first.Capture.Object.ObjectId, restored);
        Assert.Equal(content, restored.ToArray());
    }

    [Fact]
    public async Task CommittedCandidate_IsReusedBeforeCompression_AndForgedDigestIsNotTrusted()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("source");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "value.bin");
        await File.WriteAllTextAsync(path, "first!");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var metadata = new WindowsFileMetadataReader();
        var stable = new StableFileCapturer(metadata);
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", root);
            await new InitialBackupRunner(new StreamingFullScanner(metadata), stable, new NoJournal())
                .RunAsync(repository, TelemetryStore.CreateDisabled(repository.RepositoryPath), lease, source,
                    new(ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, false), new(TelemetryMode.Off, 8, 5, 10, 32));
        }
        await using var capture = new DeduplicatingFileCapturer(stable);
        await using (var writer = await PackWriter.CreateAsync(repository.RepositoryPath, 2))
        {
            var reused = await capture.CaptureAsync(repository, path, writer, ChecksumAlgorithm.Sha256,
                CompressionAlgorithm.Brotli, true, progress: value =>
                {
                    Assert.NotEqual("capture", value.Phase);
                    return ValueTask.CompletedTask;
                });
            Assert.True(reused.Reused);
            Assert.Equal(0, writer.ObjectCount);
        }
        // Force a hash candidate for DIFFERENT bytes. The embedded pack checksum is intact.
        await File.WriteAllTextAsync(path, "second");
        await using (var connection = await repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = "UPDATE stored_objects SET checksum=$hash;";
            command.Parameters.AddWithValue("$hash", SHA256.HashData("second"u8));
            await command.ExecuteNonQueryAsync();
        }
        await using var newWriter = await PackWriter.CreateAsync(repository.RepositoryPath, 3);
        var result = await capture.CaptureAsync(repository, path, newWriter,
            ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, true);
        Assert.False(result.Reused);
        Assert.Equal(1, newWriter.ObjectCount);
        var committed = await newWriter.SealAndPromoteAsync();
        await using var packReader = await PackReader.OpenAsync(committed.FullPath, verifyPayloads: true);
        await using var restored = new MemoryStream();
        await packReader.CopyObjectToAsync(result.Capture.Object.ObjectId, restored);
        Assert.Equal("second"u8.ToArray(), restored.ToArray());
    }

    [Fact]
    public async Task CancellationAtReuse_InvalidatesWriterWithoutWritingDuplicate()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var path = temp.GetPath("value");
        await File.WriteAllTextAsync(path, "same");
        await using var capture = new DeduplicatingFileCapturer(new StableFileCapturer(new WindowsFileMetadataReader()));
        await using var writer = await PackWriter.CreateAsync(repository.RepositoryPath, 1);
        await capture.CaptureAsync(repository, path, writer, ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, true);
        using var cancellation = new CancellationTokenSource();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => capture.CaptureAsync(repository, path,
            writer, ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, true, cancellation.Token, value =>
            {
                if (value.Phase == "deduplication") cancellation.Cancel();
                return ValueTask.CompletedTask;
            }));
        Assert.Equal(1, writer.ObjectCount);
        await Assert.ThrowsAsync<InvalidOperationException>(() => writer.SealAndPromoteAsync());
    }

    [Fact]
    public async Task Comparison_ReusesOneBoundedBufferAndDoesNotOwnItsSource()
    {
        var content = new byte[3 * 128 * 1024 + 13];
        new Random(51).NextBytes(content);
        using var source = new MemoryStream(content);
        var pool = new CountingPool();
        var comparer = new ContentComparisonStream(source, pool);
        await comparer.WriteAsync(content.AsMemory(0, 300_000));
        comparer.Write(content, 300_000, 20_000);
        comparer.Write(content.AsSpan(320_000));
        Assert.True(await comparer.IsSourceExhaustedAsync(default));
        await comparer.DisposeAsync();
        comparer.Dispose();
        Assert.Equal(1, pool.Rents);
        Assert.Equal(1, pool.Returns);
        Assert.Equal(128 * 1024, pool.MaximumRequested);
        Assert.True(pool.Cleared);
        Assert.True(source.CanRead);
        Assert.Throws<ObjectDisposedException>(() => comparer.Write([1], 0, 1));
    }

    [Theory]
    [InlineData("different")]
    [InlineData("short")]
    [InlineData("cancel")]
    public async Task Comparison_ReturnsBufferAfterMismatchOrCancellation(string mode)
    {
        using var source = new MemoryStream(mode == "short" ? [1] : [1, 2]);
        var pool = new CountingPool();
        await using (var comparer = new ContentComparisonStream(source, pool))
        {
            if (mode == "cancel")
                await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
                    await comparer.WriteAsync(new byte[] { 1, 2 }, new CancellationToken(true)));
            else
                await Assert.ThrowsAsync<ContentComparisonStream.ContentMismatchException>(async () =>
                    await comparer.WriteAsync(mode == "short" ? new byte[] { 1, 2 } : new byte[] { 1, 3 }));
        }
        Assert.Equal(1, pool.Returns);
        Assert.True(source.CanRead);
    }

    [Fact]
    public async Task Summary_TracksReplacementDeletionResurrectionAndRevisionGaps()
    {
        using var temp = new TempDirectory();
        await using var fixture = await MetadataFixture.CreateAsync(temp);
        await fixture.CommitAsync([FileChange("players.db", 9), FileChange("a", 12), DirectoryChange("empty")]);
        await fixture.CommitAsync([FileChange("A", 25), DirectoryChange("players.db"), FileChange("empty", 4)], revision: 10);
        await fixture.CommitAsync([DeletedChange("a"), FileChange("players.db", 11), DeletedChange("empty")]);
        await fixture.CommitAsync([FileChange("a", 1), FileChange("players.db", 0)]);
        await fixture.AssertSummariesAsync();
        var summary = Assert.Single((await fixture.Repository.ReadCatalogIfChangedAsync(-1, "PLAYERS.DB")).Sources)
            .Revisions.Single(item => item.Revision == 12);
        Assert.Equal(1, summary.LogicalSize);
        Assert.Equal(2, summary.FileCount);
        Assert.NotNull(summary.MetadataFileModifiedUtc);
    }

    [Fact]
    public async Task Summary_RollbackAndHiddenLatestBaselinePreserveCounts()
    {
        using var temp = new TempDirectory();
        await using var fixture = await MetadataFixture.CreateAsync(temp);
        await fixture.CommitAsync([FileChange("players.db", 8), FileChange("unchanged", 7)]);
        var state = await fixture.Repository.GetSourceStateAsync(fixture.Source.SourceId);
        await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.CommitAsync([FileChange("new", 15)],
            failBeforeCommit: true));
        Assert.Equal(state, await fixture.Repository.GetSourceStateAsync(fixture.Source.SourceId));
        await fixture.Repository.MarkRevisionDeletedAsync(fixture.Lease, fixture.Source.SourceId, 1);
        await fixture.CommitAsync([FileChange("new", 3), DeletedChange("players.db")]);
        await fixture.Repository.CompactDeletedRevisionsAsync(fixture.Lease, fixture.Source.SourceId);
        await fixture.AssertSummariesAsync();
        var summary = Assert.Single(Assert.Single((await fixture.Repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        Assert.Equal(10, summary.LogicalSize);
        Assert.Equal(2, summary.FileCount);
    }

    [Fact]
    public async Task Summary_OrphanReclamationResetsTheEmptyBaselineBeforeRecreation()
    {
        using var temp = new TempDirectory();
        await using var fixture = await MetadataFixture.CreateAsync(temp);
        await fixture.CommitAsync([FileChange("old", 19)]);
        Assert.Equal(1, await fixture.Repository.ReclaimOrphanSourceAsync(fixture.Lease, fixture.Source));
        await fixture.AssertSummariesAsync();
        await fixture.CommitAsync([FileChange("new", 5)]);
        await fixture.AssertSummariesAsync();
        var summary = Assert.Single(Assert.Single((await fixture.Repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        Assert.Equal(5, summary.LogicalSize);
        Assert.Equal(1, summary.FileCount);
        Assert.Equal(2, summary.Revision);
    }

    [Fact]
    public async Task Summary_GeneratedHistoryMatchesIndependentRangeAggregationAfterHousekeeping()
    {
        using var temp = new TempDirectory();
        await using var fixture = await MetadataFixture.CreateAsync(temp);
        var random = new Random(713);
        for (var i = 1; i <= 25; i++)
        {
            var index = random.Next(8);
            var path = index == 0 ? "players.db" : "path-" + index;
            var item = random.Next(3) switch
            {
                0 => FileChange(path, random.Next(100)),
                1 => DirectoryChange(path),
                _ => DeletedChange(path),
            };
            await fixture.CommitAsync([item]);
            if (i % 4 == 0)
                await fixture.Repository.MarkRevisionDeletedAsync(fixture.Lease, fixture.Source.SourceId, i - 1);
            if (i % 5 == 0)
            {
                await fixture.Repository.CompactDeletedRevisionsAsync(fixture.Lease, fixture.Source.SourceId, 2);
                await fixture.Repository.PruneUnreachableEntryVersionsAsync(fixture.Lease, fixture.Source.SourceId, 3);
            }
            await fixture.AssertSummariesAsync();
        }
    }

    [Fact]
    public async Task Summary_OverflowAbortsTheEntireRevision()
    {
        using var temp = new TempDirectory();
        await using var fixture = await MetadataFixture.CreateAsync(temp);
        await fixture.CommitAsync([FileChange("large", long.MaxValue)]);
        await Assert.ThrowsAsync<OverflowException>(() => fixture.CommitAsync([FileChange("overflow", 1)]));
        Assert.Equal(1, (await fixture.Repository.GetSourceStateAsync(fixture.Source.SourceId)).CurrentRevision);
        await fixture.AssertSummariesAsync();
    }

    [Fact]
    public async Task Catalog_UsesPathLookupInsteadOfScanningHistoricalEntries()
    {
        using var temp = new TempDirectory();
        await using var fixture = await MetadataFixture.CreateAsync(temp);
        await fixture.CommitAsync([FileChange("players.db", 4)]);
        await using var connection = await fixture.Repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "EXPLAIN QUERY PLAN " + RepositoryDatabase.CatalogSummarySql;
        command.Parameters.AddWithValue("$metadataPathKey", "PLAYERS.DB");
        await using var reader = await command.ExecuteReaderAsync();
        var plan = new List<string>();
        while (await reader.ReadAsync()) plan.Add(reader.GetString(3));
        Assert.DoesNotContain(plan, line => line.Contains("SCAN entry", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(plan, line => line.Contains("SEARCH entry", StringComparison.OrdinalIgnoreCase)
            && line.Contains("path_id=?", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task PreviousSchema_IsRejectedWithoutMigrationOrDeletion(bool createOrOpen)
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using (var connection = await repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = "UPDATE repository_info SET schema_version=1; PRAGMA wal_checkpoint(TRUNCATE);";
            await command.ExecuteNonQueryAsync();
        }
        var before = SHA256.HashData(await File.ReadAllBytesAsync(repository.DatabasePath));
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => createOrOpen
            ? RepositoryDatabase.CreateOrOpenAsync(repository.RepositoryPath)
            : RepositoryDatabase.OpenExistingAsync(repository.RepositoryPath));
        Assert.Contains("repository-reset-required", error.Message);
        Assert.Equal(before, SHA256.HashData(await File.ReadAllBytesAsync(repository.DatabasePath)));
    }

    private static Change FileChange(string path, long length) => new(path, CatalogEntryKind.File, false, length);
    private static Change DirectoryChange(string path) => new(path, CatalogEntryKind.Directory, false, 0);
    private static Change DeletedChange(string path) => new(path, CatalogEntryKind.File, true, 0);
    private sealed record Change(string Path, CatalogEntryKind Kind, bool Tombstone, long Length);

    // Synthetic metadata only: no user save is opened, and the fixture is not a pack-I/O benchmark.
    private sealed class MetadataFixture(RepositoryDatabase repository, RepositoryWriterLease lease,
        RepositorySource source) : IAsyncDisposable
    {
        public RepositoryDatabase Repository { get; } = repository;
        public RepositoryWriterLease Lease { get; } = lease;
        public RepositorySource Source { get; } = source;

        public static async Task<MetadataFixture> CreateAsync(TempDirectory temp)
        {
            var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
            var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
            var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", temp.GetPath("absent-save"));
            return new(repository, lease, source);
        }

        public async Task CommitAsync(Change[] changes, long? revision = null, bool failBeforeCommit = false)
        {
            var run = await Repository.StartRunAsync(Lease, Source.SourceId);
            var packId = Guid.NewGuid();
            var entries = new List<EntryVersionRegistration>();
            var objects = new List<StoredObjectRegistration>();
            var now = DateTimeOffset.UnixEpoch.AddTicks(run.RunIndex);
            foreach (var change in changes)
            {
                Guid? objectId = change.Kind == CatalogEntryKind.File && !change.Tombstone ? Guid.NewGuid() : null;
                if (objectId is not null)
                    objects.Add(new(objectId.Value, packId, 0, change.Length, change.Length, "None", null, "None"));
                entries.Add(new(change.Path, change.Kind, change.Tombstone, change.Length, now, now,
                    change.Kind == CatalogEntryKind.File ? FileAttributes.Normal : FileAttributes.Directory,
                    null, null, objectId));
            }
            try
            {
                await Repository.CommitRevisionAsync(Lease, new(run.RunIndex, Source.SourceId, null,
                    objects.Count == 0 ? [] : [new PackRegistration(packId, $"packs/{packId:N}.pzpack", 1, 64)],
                    objects, entries, RequestedRevision: revision), beforeTransactionCommit: () =>
                    {
                        if (failBeforeCommit) throw new InvalidOperationException("injected before commit");
                    });
            }
            catch
            {
                await Repository.CompleteRunAsync(Lease, run.RunIndex, RunStatus.Failed, "test-failure");
                throw;
            }
        }

        public async Task AssertSummariesAsync()
        {
            await using var connection = await Repository.OpenConnectionAsync();
            await using var command = connection.CreateCommand();
            command.CommandText =
                """
                SELECT revision.revision,revision.logical_size,revision.file_count,
                    COALESCE(SUM(CASE WHEN entry.entry_kind='File' THEN entry.byte_length ELSE 0 END),0),
                    COUNT(CASE WHEN entry.entry_kind='File' THEN 1 END)
                FROM revisions AS revision
                LEFT JOIN entry_versions AS entry ON entry.source_id=revision.source_id
                    AND entry.valid_from_revision<=revision.revision
                    AND (entry.valid_to_revision IS NULL OR entry.valid_to_revision>revision.revision)
                    AND entry.tombstone=0
                WHERE revision.state='Active' OR revision.revision=(
                    SELECT current_revision FROM source_state WHERE source_id=revision.source_id)
                GROUP BY revision.source_id,revision.revision;
                """;
            await using (var reader = await command.ExecuteReaderAsync())
                while (await reader.ReadAsync())
                {
                    Assert.Equal(reader.GetInt64(3), reader.GetInt64(1));
                    Assert.Equal(reader.GetInt64(4), reader.GetInt64(2));
                }
            command.CommandText = "PRAGMA foreign_key_check;";
            await using (var reader = await command.ExecuteReaderAsync()) Assert.False(await reader.ReadAsync());
            command.CommandText = "PRAGMA integrity_check;";
            Assert.Equal("ok", await command.ExecuteScalarAsync());
        }

        public ValueTask DisposeAsync() => Lease.DisposeAsync();
    }

    private sealed class CountingPool : ArrayPool<byte>
    {
        public int Rents { get; private set; }
        public int Returns { get; private set; }
        public int MaximumRequested { get; private set; }
        public bool Cleared { get; private set; }
        public override byte[] Rent(int minimumLength)
        {
            Rents++;
            MaximumRequested = Math.Max(MaximumRequested, minimumLength);
            return new byte[minimumLength];
        }
        public override void Return(byte[] array, bool clearArray = false)
        {
            Returns++;
            Cleared |= clearArray;
        }
    }

    private sealed class NoJournal : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(null, "test");
    }
}
