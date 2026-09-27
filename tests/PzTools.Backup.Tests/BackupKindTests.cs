using PzTools.Process.Contracts;
using Microsoft.Data.Sqlite;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class BackupKindTests
{
    [Fact]
    public async Task MixedHistory_RetainsAllManualSnapshotsThroughCompactionAndGc()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repository.RepositoryPath);
        var metadata = new WindowsFileMetadataReader();
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, ContentDeduplication: false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        // Manual rows on both sides of deleted automatic rows, plus consecutive manual rows.
        BackupKind[] kinds = [BackupKind.Automatic, BackupKind.Manual, BackupKind.Automatic,
            BackupKind.Manual, BackupKind.Manual, BackupKind.Automatic, BackupKind.Automatic];
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
            sourceId = source.SourceId;
            for (var index = 0; index < kinds.Length; index++)
            {
                await File.WriteAllTextAsync(Path.Combine(sourcePath, "data.txt"), $"snapshot {index + 1}");
                if (index == 0)
                    await File.WriteAllTextAsync(Path.Combine(sourcePath, "unchanged.txt"), "shared content");
                var automatic = kinds[index] == BackupKind.Automatic;
                var workflow = await repository.ReserveWorkflowAsync(
                    automatic ? "backup-maintenance" : "manual-backup", sourceId,
                    automatic ? "backup-scheduler" : "backup-worker");
                // Mix languages within one history instead of repeating all storage I/O per locale.
                var language = LanguageCatalog.All[index % LanguageCatalog.All.Count].Id;
                var execution = new BackupExecutionOptions(workflow.RunIndex, NameLanguage: language);
                if (index == 0)
                    await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
                        new Boundary()).RunAsync(repository, telemetry, lease, source, storage, telemetryOptions, execution);
                else
                    await new IncrementalBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
                        metadata, new FullScanJournal(), new UsnDeltaPlanner())
                        .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions, execution);
            }
            var catalog = Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources);
            foreach (var revision in catalog.Revisions)
            {
                Assert.Equal(kinds[revision.Revision - 1], revision.Kind);
                var names = LanguageCatalog.All[(int)((revision.Revision - 1) % LanguageCatalog.All.Count)];
                var prefix = revision.Kind == BackupKind.Automatic ? names.AutomaticBackupName : names.ManualBackupName;
                Assert.Equal($"{prefix} {revision.Revision}", revision.DisplayName);
            }
            // User naming does not affect retention classification.
            await repository.RenameRevisionAsync(lease, sourceId, 4, "My checkpoint");
            var retained = await repository.MarkRevisionsForRetentionAsync(lease, sourceId, keepLatest: 2);
            Assert.Equal(2, retained.MarkedDeleted);
            Assert.Equal(5, retained.ActiveRevisionCount);
            Assert.Equal(0, (await repository.MarkRevisionsForRetentionAsync(lease, sourceId, 2)).MarkedDeleted);
            Assert.Equal(2, (await repository.CompactDeletedRevisionsAsync(lease, sourceId)).CompactedRevisions);
            await repository.CollectGarbageAsync(lease);
            await new PackCompactor().CompactAsync(repository, lease, maximumSourcePackBytes: long.MaxValue);
            await repository.CollectGarbageAsync(lease);
        }

        var reopened = await RepositoryDatabase.OpenExistingAsync(repository.RepositoryPath);
        var remaining = Assert.Single((await reopened.ReadCatalogIfChangedAsync(-1)).Sources).Revisions;
        Assert.Equal(new long[] { 7, 6, 5, 4, 2 }, remaining.Select(item => item.Revision));
        Assert.Equal("My checkpoint", remaining.Single(item => item.Revision == 4).DisplayName);
        foreach (var revision in remaining)
        {
            var target = temp.GetPath($"restored-{revision.Revision}");
            await new RevisionRestorer().RestoreAsync(reopened, sourceId, revision.Revision, target);
            Assert.Equal($"snapshot {revision.Revision}", await File.ReadAllTextAsync(Path.Combine(target, "data.txt")));
            Assert.Equal("shared content", await File.ReadAllTextAsync(Path.Combine(target, "unchanged.txt")));
        }
        var views = new RevisionedViewStore();
        await new BackupProjector(reopened, views).ProjectOnceAsync();
        var projected = Assert.Single(views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0).Snapshot!.Sources);
        Assert.Equal(remaining.Select(item => item.Kind), projected.Revisions.Select(item => item.Kind));

        await using var deleteLease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        await reopened.MarkRevisionDeletedAsync(deleteLease, sourceId, 4);
        Assert.DoesNotContain(Assert.Single((await reopened.ReadCatalogIfChangedAsync(-1)).Sources).Revisions,
            item => item.Revision == 4);
    }

    private sealed class Boundary : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) =>
            new(new SourceCheckpoint("0000000000000001", "0000000000000002", 100), null);
    }

    private sealed class FullScanJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new PlatformNotSupportedException();
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException();
    }
}
