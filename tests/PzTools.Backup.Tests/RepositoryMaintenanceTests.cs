using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class RepositoryMaintenanceTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DeletedTail_CompactsOntoHiddenBaselineWithoutChangingRetainedCatalogs(bool keepFirst)
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", temp.GetPath("source"));
        var now = DateTimeOffset.UtcNow;
        await CommitDirectoriesAsync(repository, lease, source.SourceId,
            [EntryDirectory("unchanged", now), EntryDirectory("removed", now)]);
        await CommitDirectoriesAsync(repository, lease, source.SourceId,
            [EntryDirectory("removed", now, tombstone: true), EntryDirectory("added", now)]);
        await CommitDirectoriesAsync(repository, lease, source.SourceId,
            [EntryDirectory("added", now.AddSeconds(1))]);
        var first = await repository.ReadRevisionEntriesAsync(source.SourceId, 1);
        var latest = await repository.ReadRevisionEntriesAsync(source.SourceId, 3);
        var state = await repository.GetSourceStateAsync(source.SourceId);
        for (var revision = keepFirst ? 2 : 1; revision <= 3; revision++)
            await repository.MarkRevisionDeletedAsync(lease, source.SourceId, revision);

        var expectedCompacted = keepFirst ? 1 : 2;
        Assert.Equal(expectedCompacted, await repository.CountCompactableDeletedRevisionsAsync(source.SourceId));
        for (var batch = 0; batch < expectedCompacted; batch++)
            Assert.Equal(1, (await repository.CompactDeletedRevisionsAsync(lease, source.SourceId, 1)).CompactedRevisions);
        Assert.Equal(0, (await repository.CompactDeletedRevisionsAsync(lease, source.SourceId, 1)).CompactedRevisions);
        Assert.Equal(1, await repository.CountDeletedRevisionsAsync(source.SourceId));
        Assert.Equal(state, await repository.GetSourceStateAsync(source.SourceId));
        var current = await repository.ReadCurrentEntriesByPathsAsync(source.SourceId, ["unchanged", "removed", "added"]);
        Assert.Equal(latest, current);
        var history = Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources);
        Assert.Equal(keepFirst ? 1 : 0, history.Revisions.Count);
        if (keepFirst) Assert.Equal(first, await repository.ReadRevisionEntriesAsync(source.SourceId, 1));

        await CommitDirectoriesAsync(repository, lease, source.SourceId, [EntryDirectory("next", now)]);
        Assert.Equal(1, (await repository.CompactDeletedRevisionsAsync(lease, source.SourceId)).CompactedRevisions);
        Assert.Equal(0, await repository.CountDeletedRevisionsAsync(source.SourceId));
        var next = await repository.ReadRevisionEntriesAsync(source.SourceId, 4);
        Assert.Equal(new[] { "added", "next", "unchanged" }, next.Select(entry => entry.RelativePath));
        if (keepFirst) Assert.Equal(first, await repository.ReadRevisionEntriesAsync(source.SourceId, 1));
    }

    [Fact]
    public async Task DeletedLatest_SurvivesGcAndNextIncrementalBackupReleasesOnlyUnusedObjects()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var changedFile = Path.Combine(sourcePath, "changed.txt");
        await File.WriteAllTextAsync(changedFile, "old content");
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "unchanged.txt"), "preserve content");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repository.RepositoryPath);
        var metadata = new WindowsFileMetadataReader();
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, ContentDeduplication: false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        RepositorySource source;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
            await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
                new FixedBoundaryProvider()).RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
            var state = await repository.GetSourceStateAsync(source.SourceId);
            await repository.MarkRevisionDeletedAsync(lease, source.SourceId, 1);
            Assert.Equal(state, await repository.GetSourceStateAsync(source.SourceId));
            Assert.Empty(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
            Assert.Null(await repository.TryLocateRevisionFileAsync(source.SourceId, 1, "changed.txt"));
            await Assert.ThrowsAsync<KeyNotFoundException>(() => new RevisionRestorer().RestoreAsync(
                repository, source.SourceId, 1, temp.GetPath("deleted-restore")));
            Assert.Equal(0, (await repository.CompactDeletedRevisionsAsync(lease, source.SourceId)).CompactedRevisions);
            Assert.Equal(0, (await repository.CollectGarbageAsync(lease)).DeletedObjects);
            Assert.Single(await repository.ReadPacksAsync());
        }

        var maintenance = await new MaintenanceService().RunAsync(repository.RepositoryPath, source.SourceId,
            new MaintenanceOptions(RevisionCompactionBatchSize: 1));
        Assert.Equal("Skipped", Assert.Single(maintenance.Lanes, lane => lane.Lane == "RevisionCompaction").Status);

        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var runner = new IncrementalBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
                metadata, new FullScanJournal(), new UsnDeltaPlanner());
            var unchanged = await runner.RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
            Assert.Null(unchanged.Revision);
            Assert.Empty(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
            await File.WriteAllTextAsync(changedFile, "new content is longer");
            var next = await runner.RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
            Assert.Equal(2, next.Revision);
            Assert.Equal(1, (await repository.CompactDeletedRevisionsAsync(lease, source.SourceId)).CompactedRevisions);
            Assert.Equal(1, (await repository.CollectGarbageAsync(lease)).DeletedObjects);
            Assert.Equal(0, await repository.CountDeletedRevisionsAsync(source.SourceId));
        }
        var target = temp.GetPath("restore");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 2, target);
        Assert.Equal("new content is longer", await File.ReadAllTextAsync(Path.Combine(target, "changed.txt")));
        Assert.Equal("preserve content", await File.ReadAllTextAsync(Path.Combine(target, "unchanged.txt")));
    }

    [Fact]
    public async Task Maintenance_DefersRevisionCompactionAndGcUntilBatchThreshold()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            var source = await repository.AddOrGetSourceAsync(
                lease, "main", temp.GetPath("source"));
            sourceId = source.SourceId;
            for (var index = 1; index <= 4; index++)
            {
                await CommitDirectoriesAsync(repository, lease, sourceId,
                    [EntryDirectory("value", DateTimeOffset.UnixEpoch.AddSeconds(index))]);
            }
        }

        var options = new MaintenanceOptions(
            RetainLatestRevisions: 2,
            RevisionCompactionBatchSize: 3);
        var deferred = await new MaintenanceService().RunAsync(
            repositoryPath, sourceId, options);

        Assert.Equal(2, await repository.CountDeletedRevisionsAsync(sourceId));
        Assert.Equal("Skipped", deferred.Lanes.Single(
            item => item.Lane == "RevisionCompaction").Status);
        Assert.Equal("Skipped", deferred.Lanes.Single(
            item => item.Lane == "ObjectGc").Status);

        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            await CommitDirectoriesAsync(repository, lease, sourceId,
                [EntryDirectory("value", DateTimeOffset.UnixEpoch.AddSeconds(5))]);
        }
        var compacted = await new MaintenanceService().RunAsync(
            repositoryPath, sourceId, options);

        Assert.Equal(0, await repository.CountDeletedRevisionsAsync(sourceId));
        Assert.Equal(3, compacted.Lanes.Single(
            item => item.Lane == "RevisionCompaction").AffectedItems);
        Assert.Equal("Succeeded", compacted.Lanes.Single(
            item => item.Lane == "ObjectGc").Status);
    }

    [Fact]
    public async Task ArtifactCleanup_RemovesOnlyTopLevelStagingTemporaryFiles()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var staging = Path.Combine(repositoryPath, "staging");
        await File.WriteAllTextAsync(Path.Combine(staging, "incomplete.tmp"), "temporary");
        await File.WriteAllTextAsync(Path.Combine(staging, "keep.bin"), "keep");
        var quarantine = Path.Combine(staging, "quarantine");
        Directory.CreateDirectory(quarantine);
        await File.WriteAllTextAsync(Path.Combine(quarantine, "crashed.tmp"), "partial");
        await File.WriteAllTextAsync(Path.Combine(quarantine, "unknown.bin"), "keep");
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);

        var result = await repository.CleanupArtifactsAsync(lease);

        Assert.Equal(2, result.DeletedTemporaryFiles);
        Assert.Empty(result.FilesThatCouldNotBeDeleted);
        Assert.False(File.Exists(Path.Combine(staging, "incomplete.tmp")));
        Assert.True(File.Exists(Path.Combine(staging, "keep.bin")));
        Assert.False(File.Exists(Path.Combine(quarantine, "crashed.tmp")));
        Assert.True(File.Exists(Path.Combine(quarantine, "unknown.bin")));
    }

    [Fact]
    public async Task Retention_CountsOnlyActiveRevisionsAndCompactsInBoundedBatch()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(
            lease, "main", temp.GetPath("source"));
        for (var index = 1; index <= 105; index++)
        {
            await CommitDirectoriesAsync(repository, lease, source.SourceId,
                [EntryDirectory("value", DateTimeOffset.UnixEpoch.AddSeconds(index))]);
        }

        var retained = await repository.MarkRevisionsForRetentionAsync(
            lease, source.SourceId, keepLatest: 100);
        Assert.Equal(5, retained.MarkedDeleted);
        Assert.Equal(100, retained.ActiveRevisionCount);
        Assert.Equal(6, retained.OldestActiveRevision);
        var compacted = await repository.CompactDeletedRevisionsAsync(
            lease, source.SourceId, maximumRevisions: 3);
        Assert.Equal(3, compacted.CompactedRevisions);
        await Assert.ThrowsAsync<KeyNotFoundException>(
            () => repository.ReadRevisionEntriesAsync(source.SourceId, 1));
        Assert.Single(await repository.ReadRevisionEntriesAsync(source.SourceId, 6));
        Assert.Single(await repository.ReadRevisionEntriesAsync(source.SourceId, 105));
    }

    [Fact]
    public async Task MiddleRevisionDeletion_IsInvisibleAndCompactionPreservesActiveCatalogs()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(
            lease, "main", temp.GetPath("source"));
        var now = DateTimeOffset.UtcNow;
        await CommitDirectoriesAsync(repository, lease, source.SourceId, [EntryDirectory("a", now)]);
        await CommitDirectoriesAsync(repository, lease, source.SourceId, [EntryDirectory("b", now)]);
        await CommitDirectoriesAsync(repository, lease, source.SourceId, [EntryDirectory("c", now)]);
        var revision1 = await repository.ReadRevisionEntriesAsync(source.SourceId, 1);
        var revision3 = await repository.ReadRevisionEntriesAsync(source.SourceId, 3);

        await repository.MarkRevisionDeletedAsync(lease, source.SourceId, 2);
        await Assert.ThrowsAsync<KeyNotFoundException>(
            () => repository.ReadRevisionEntriesAsync(source.SourceId, 2));
        var compacted = await repository.CompactDeletedRevisionsAsync(
            lease, source.SourceId, maximumRevisions: 20);

        Assert.Equal(1, compacted.CompactedRevisions);
        Assert.Equal(revision1.Select(item => item.RelativePath),
            (await repository.ReadRevisionEntriesAsync(source.SourceId, 1)).Select(item => item.RelativePath));
        Assert.Equal(revision3.Select(item => item.RelativePath),
            (await repository.ReadRevisionEntriesAsync(source.SourceId, 3)).Select(item => item.RelativePath));
        await repository.MarkRevisionDeletedAsync(lease, source.SourceId, 3);
        await Assert.ThrowsAsync<KeyNotFoundException>(
            () => repository.ReadRevisionEntriesAsync(source.SourceId, 3));
        Assert.Equal(0, (await repository.CompactDeletedRevisionsAsync(lease, source.SourceId)).CompactedRevisions);
        Assert.Equal(1, await repository.CountDeletedRevisionsAsync(source.SourceId));
    }

    [Fact]
    public async Task PruneRevisions_RebasesOldestRetainedCatalog()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(
            lease,
            "main",
            temp.GetPath("source"));
        var now = DateTimeOffset.UtcNow;

        await CommitDirectoriesAsync(repository, lease, source.SourceId, [EntryDirectory("a", now), EntryDirectory("b", now)]);
        await CommitDirectoriesAsync(repository, lease, source.SourceId, [EntryDirectory("a", now.AddSeconds(1))]);
        await CommitDirectoriesAsync(
            repository,
            lease,
            source.SourceId,
            [EntryDirectory("b", now, tombstone: true), EntryDirectory("c", now)]);
        var revision2Before = await repository.ReadRevisionEntriesAsync(source.SourceId, 2);
        var revision3Before = await repository.ReadRevisionEntriesAsync(source.SourceId, 3);

        var result = await repository.PruneRevisionsAsync(lease, source.SourceId, keepLatest: 2);

        Assert.Equal(1, result.DeletedRevisions);
        Assert.Equal(2, result.OldestRetainedRevision);
        await Assert.ThrowsAsync<KeyNotFoundException>(
            () => repository.ReadRevisionEntriesAsync(source.SourceId, 1));
        Assert.Equal(
            revision2Before.Select(item => item.RelativePath),
            (await repository.ReadRevisionEntriesAsync(source.SourceId, 2))
            .Select(item => item.RelativePath));
        Assert.Equal(
            revision3Before.Select(item => item.RelativePath),
            (await repository.ReadRevisionEntriesAsync(source.SourceId, 3))
            .Select(item => item.RelativePath));
    }

    [Fact]
    public async Task GarbageCollection_RemovesObjectsAndPacksNoLongerReferenced()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var filePath = Path.Combine(sourcePath, "data.txt");
        await File.WriteAllTextAsync(filePath, "version-one");
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var metadata = new WindowsFileMetadataReader();
        var storage = new StorageOptions(
            ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None,
            ContentDeduplication: false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        await new InitialBackupRunner(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata),
            new FixedBoundaryProvider())
            .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        await File.WriteAllTextAsync(filePath, "version-two-is-different");
        await new IncrementalBackupRunner(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata),
            metadata,
            new ChangedJournal(),
            new UsnDeltaPlanner())
            .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        Assert.Equal(2, (await repository.ReadPacksAsync()).Count);

        await repository.MarkRevisionDeletedAsync(lease, source.SourceId, 1);
        await repository.CompactDeletedRevisionsAsync(lease, source.SourceId);
        var collected = await repository.CollectGarbageAsync(lease);

        Assert.Equal(1, collected.DeletedObjects);
        Assert.Equal(1, collected.DeletedPacks);
        Assert.Empty(collected.FilesThatCouldNotBeDeleted);
        Assert.Single(await repository.ReadPacksAsync());
        var restorePath = temp.GetPath("restore");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 2, restorePath);
        Assert.Equal(
            "version-two-is-different",
            await File.ReadAllTextAsync(Path.Combine(restorePath, "data.txt")));
    }

    [Fact]
    public async Task PackCompaction_RelocatesLiveObjectsBeforeDeletingOldPacks()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var filePath = Path.Combine(sourcePath, "data.txt");
        await File.WriteAllTextAsync(filePath, "first-version");
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var metadata = new WindowsFileMetadataReader();
        var storage = new StorageOptions(
            ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None,
            ContentDeduplication: false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        await new InitialBackupRunner(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata),
            new FixedBoundaryProvider())
            .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        await File.WriteAllTextAsync(filePath, "second-version");
        await new IncrementalBackupRunner(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata),
            metadata,
            new ChangedJournal(),
            new UsnDeltaPlanner())
            .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);

        var result = await new PackCompactor().RewriteAsync(
            repository, lease, await repository.ReadPacksAsync());

        Assert.Equal(2, result.SourcePacks);
        Assert.Equal(2, result.RelocatedObjects);
        Assert.NotNull(result.NewPackId);
        Assert.Empty(result.FilesThatCouldNotBeDeleted);
        var packs = await repository.ReadPacksAsync();
        Assert.Single(packs, item => item.Status == "Committed");
        Assert.Equal(2, packs.Count(item => item.Status == "Superseded"));
        var restore1 = temp.GetPath("restore-1");
        var restore2 = temp.GetPath("restore-2");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 1, restore1);
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 2, restore2);
        Assert.Equal("first-version", await File.ReadAllTextAsync(Path.Combine(restore1, "data.txt")));
        Assert.Equal("second-version", await File.ReadAllTextAsync(Path.Combine(restore2, "data.txt")));
        var collected = await repository.CollectGarbageAsync(lease);
        Assert.Equal(2, collected.DeletedPacks);
        Assert.Single(await repository.ReadPacksAsync());
    }

    [Fact]
    public async Task PackSpaceReclamation_RewritesAMostlyDeadPack_AndKeepsEveryRetainedBackupRestorable()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var bigPath = Path.Combine(sourcePath, "big.bin");
        byte[] Version(int seed) { var bytes = new byte[1_500_000]; new Random(seed).NextBytes(bytes); return bytes; }
        await File.WriteAllBytesAsync(bigPath, Version(1));
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "keep.txt"), "never changes");
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var metadata = new WindowsFileMetadataReader();
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, ContentDeduplication: false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
            new FixedBoundaryProvider()).RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        foreach (var seed in new[] { 2, 3 })
        {
            await File.WriteAllBytesAsync(bigPath, Version(seed));
            await new IncrementalBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
                metadata, new FullScanJournal(), new UsnDeltaPlanner())
                .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        }
        // Backups 2 and 3 still need keep.txt from the first pack; its large file is no longer needed.
        await repository.MarkRevisionDeletedAsync(lease, source.SourceId, 1);
        await repository.CompactDeletedRevisionsAsync(lease, source.SourceId);
        await repository.CollectGarbageAsync(lease);
        Assert.Equal(3, (await repository.ReadPacksAsync()).Count);
        long PackBytes() => Directory.GetFiles(Path.Combine(repositoryPath, "packs"), "*.pzpack").Sum(path => new FileInfo(path).Length);
        var before = PackBytes();
        var options = new PackReclamationOptions(MinimumReclaimMib: 1);
        var announced = 0;

        var result = await new PackSpaceReclaimer().RunAsync(repository, lease, options, plan =>
        {
            announced++;
            Assert.Single(plan.Packs);
            return Task.CompletedTask;
        });

        Assert.Equal("Succeeded", result.Status);
        Assert.Equal(1, announced);
        Assert.Equal(1, result.RewrittenPacks);
        Assert.Equal(1, result.RelocatedObjects);
        Assert.Empty(result.FilesThatCouldNotBeDeleted);
        Assert.True(result.ReclaimedBytes > 1_400_000, result.ReclaimedBytes.ToString());
        Assert.Equal(before - result.ReclaimedBytes, PackBytes());
        var packs = await repository.ReadPacksAsync();
        Assert.Equal(3, packs.Count);
        Assert.All(packs, item => Assert.Equal("Committed", item.Status));
        foreach (var (revision, seed) in new[] { (2L, 2), (3L, 3) })
        {
            var restore = temp.GetPath($"restore-{revision}");
            await new RevisionRestorer().RestoreAsync(repository, source.SourceId, revision, restore);
            Assert.Equal(Version(seed), await File.ReadAllBytesAsync(Path.Combine(restore, "big.bin")));
            Assert.Equal("never changes", await File.ReadAllTextAsync(Path.Combine(restore, "keep.txt")));
        }
        Assert.Empty((await new RepositoryVerifier().VerifyAsync(repository)).Issues);
        // The rewritten pack is fully live, so nothing is copied again.
        Assert.Equal("below-threshold", (await new PackSpaceReclaimer().RunAsync(repository, lease, options)).Status);
    }

    [Fact]
    public void PackSpaceReclamation_PlansSparsestPacksFirst_WithinItsThresholdsAndBudget()
    {
        const long mib = 1048576;
        PackUsage Pack(int id, long size, long live) =>
            new(new RepositoryPack(new Guid(id, 0, 0, new byte[8]), $"packs/{id}.pzpack", size, "Committed", id), live);
        var halfLive = Pack(1, 40 * mib, 20 * mib);   // Not below 50%.
        var sparse = Pack(2, 40 * mib, 10 * mib);
        var sparser = Pack(3, 40 * mib, 2 * mib);
        var dead = Pack(4, 40 * mib, 0);              // Garbage collection's job, not a rewrite.
        PackUsage[] usage = [halfLive, sparse, sparser, dead];

        var plan = PackSpaceReclaimer.Plan(usage, new PackReclamationOptions())!;
        Assert.Equal([sparser.Pack, sparse.Pack], plan.Packs);
        Assert.Equal(80 * mib, plan.PackBytes);
        Assert.Equal(12 * mib, plan.LiveBytes);

        // The copy budget stops a pass; the sparsest pack is taken even when it alone exceeds it.
        Assert.Equal([sparser.Pack], PackSpaceReclaimer.Plan(usage, new PackReclamationOptions(MaximumCopyMib: 5))!.Packs);
        Assert.Equal([sparser.Pack], PackSpaceReclaimer.Plan(usage, new PackReclamationOptions(MaximumCopyMib: 1))!.Packs);
        // Too little to recover is not worth copying anything.
        Assert.Null(PackSpaceReclaimer.Plan(usage, new PackReclamationOptions(MinimumReclaimMib: 100)));
        Assert.Null(PackSpaceReclaimer.Plan(usage, new PackReclamationOptions(Enabled: false)));
        Assert.Null(PackSpaceReclaimer.Plan([halfLive, dead], new PackReclamationOptions(MinimumReclaimMib: 1)));
    }

    private static EntryVersionRegistration EntryDirectory(
        string path,
        DateTimeOffset timestamp,
        bool tombstone = false) =>
        new(
            path,
            CatalogEntryKind.Directory,
            tombstone,
            0,
            timestamp,
            timestamp,
            FileAttributes.Directory,
            FileId: null,
            ParentFileId: null,
            ObjectId: null);

    private static async Task CommitDirectoriesAsync(
        RepositoryDatabase repository,
        RepositoryWriterLease lease,
        long sourceId,
        IReadOnlyList<EntryVersionRegistration> entries)
    {
        var workflow = await repository.ReserveWorkflowAsync("backup-maintenance", sourceId, "backup-scheduler");
        var run = await repository.StartRunAsync(lease, sourceId, workflow.RunIndex);
        await repository.CommitRevisionAsync(
            lease,
            new RevisionCommitRequest(run.RunIndex, sourceId, null, [], [], entries));
    }

    private sealed class FixedBoundaryProvider : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) =>
            new(new SourceCheckpoint("0000000000000001", "0000000000000002", 100), null);
    }

    private sealed class ChangedJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => new(1, 3, 0, 200, 0);

        public IEnumerable<UsnRecord> ReadRange(
            string sourcePath,
            UsnCheckpoint checkpoint,
            long upperUsnExclusive,
            CancellationToken cancellationToken = default) => [];
    }

    private sealed class FullScanJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new PlatformNotSupportedException("test full scan");

        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("Full scan must not read journal records.");
    }
}
