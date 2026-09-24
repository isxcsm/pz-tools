using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class ContentDeduplicationTests
{
    [Fact]
    public async Task Enabled_ComparesStagedBytesEvenWhenLiveSourceChangesAfterCopy()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var firstPath = temp.GetPath("first.bin");
        var secondPath = temp.GetPath("second.bin");
        byte[] original = [1, 2, 3, 4];
        await File.WriteAllBytesAsync(firstPath, original);
        await File.WriteAllBytesAsync(secondPath, original);
        var metadata = new WindowsFileMetadataReader();
        var deduplicating = new DeduplicatingFileCapturer(new StableFileCapturer(metadata));
        await using var writer = await PackWriter.CreateAsync(repositoryPath, 1);
        var first = await deduplicating.CaptureAsync(
            repository, firstPath, writer, ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None, contentDeduplication: true);
        var changed = false;

        var second = await deduplicating.CaptureAsync(
            repository, secondPath, writer, ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None, contentDeduplication: true,
            progress: async copy =>
            {
                if (copy.CopiedBytes != original.Length || changed) return;
                changed = true;
                await using var source = new FileStream(secondPath, FileMode.Open,
                    FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                await source.WriteAsync(new byte[] { 5, 6, 7, 8 });
                await source.FlushAsync();
            });

        Assert.True(changed);
        Assert.True(second.Reused);
        Assert.Equal(first.Capture.Object.ObjectId, second.Capture.Object.ObjectId);
        Assert.Equal(1, writer.ObjectCount);
    }

    [Fact]
    public async Task Enabled_ReusesVerifiedObjectWithinInitialRun()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "first.txt"), "same-content");
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "second.txt"), "same-content");
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = TelemetryStore.CreateDisabled(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var metadata = new WindowsFileMetadataReader();
        var stable = new StableFileCapturer(metadata);
        var storage = new StorageOptions(
            ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None,
            ContentDeduplication: true);

        await new InitialBackupRunner(
            new StreamingFullScanner(metadata),
            stable,
            new FixedBoundaryProvider(),
            deduplicatingCapturer: new DeduplicatingFileCapturer(stable))
            .RunAsync(
                repository,
                telemetry,
                lease,
                source,
                storage,
                new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32));

        var entries = await repository.ReadRevisionEntriesAsync(source.SourceId, 1);
        var files = entries.Where(item => item.EntryKind == "File").ToArray();
        Assert.Equal(2, files.Length);
        Assert.Equal(files[0].ObjectId, files[1].ObjectId);
        var packPath = Directory.GetFiles(Path.Combine(repositoryPath, "packs"), "*.pzpack").Single();
        await using var pack = await PackReader.OpenAsync(packPath);
        Assert.Single(pack.Objects);
    }

    [Fact]
    public async Task Enabled_ReusesVerifiedCommittedObject()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        const string content = "identical-content-for-deduplication";
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "first.txt"), content);
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var metadata = new WindowsFileMetadataReader();
        var stable = new StableFileCapturer(metadata);
        var deduplicating = new DeduplicatingFileCapturer(stable);
        var storage = new StorageOptions(
            ChecksumAlgorithm.Sha256,
            CompressionAlgorithm.None,
            ContentDeduplication: true);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        await new InitialBackupRunner(
            new StreamingFullScanner(metadata),
            stable,
            new FixedBoundaryProvider(),
            deduplicatingCapturer: deduplicating)
            .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "second.txt"), content);

        await new IncrementalBackupRunner(
            new StreamingFullScanner(metadata),
            stable,
            metadata,
            new ChangedJournal(),
            new UsnDeltaPlanner(),
            deduplicatingCapturer: deduplicating)
            .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);

        Assert.Single(await repository.ReadPacksAsync());
        var entries = await repository.ReadRevisionEntriesAsync(source.SourceId, 2);
        var files = entries.Where(item => item.EntryKind == "File").ToArray();
        Assert.Equal(2, files.Length);
        Assert.Equal(files[0].ObjectId, files[1].ObjectId);
        var restore = temp.GetPath("restore");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 2, restore);
        Assert.Equal(content, await File.ReadAllTextAsync(Path.Combine(restore, "first.txt")));
        Assert.Equal(content, await File.ReadAllTextAsync(Path.Combine(restore, "second.txt")));
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
}
