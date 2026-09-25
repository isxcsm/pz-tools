using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class MissingIdentityDeletionTests
{
    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task FullScanDeletion_PreservesUnknownIdentityAsNull(
        bool missingParent, bool alwaysInclude)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("source");
        Directory.CreateDirectory(root);
        var gone = Path.Combine(root, "gone.bin");
        await File.WriteAllTextAsync(gone, "removed content");
        await File.WriteAllTextAsync(Path.Combine(root, "keep.bin"), "retained content");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repository.RepositoryPath);
        var metadata = new WindowsFileMetadataReader();
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "test", root);
        await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
            new NoCheckpoint()).RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        var before = await repository.GetSourceStateAsync(source.SourceId);
        await using (var connection = await repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = missingParent
                ? "UPDATE entry_versions SET parent_file_id=NULL WHERE path_key='GONE.BIN';"
                : "UPDATE entry_versions SET file_id=NULL WHERE path_key='GONE.BIN';";
            Assert.Equal(1, await command.ExecuteNonQueryAsync());
        }
        File.Delete(gone);
        var runner = new IncrementalBackupRunner(new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata), metadata, new NoJournal(), new UsnDeltaPlanner());
        var result = await runner.RunAsync(repository, telemetry, lease, source, storage, telemetryOptions,
            executionOptions: null, alwaysIncludePaths: alwaysInclude ? ["gone.bin"] : []);
        Assert.Equal(BackupScanMode.FullScan, result.ScanMode);
        Assert.Equal(2, result.Revision);
        Assert.Equal(before.Checkpoint, (await repository.GetSourceStateAsync(source.SourceId)).Checkpoint);
        Assert.Equal("keep.bin", Assert.Single(await repository.ReadRevisionEntriesAsync(source.SourceId, 2)).RelativePath);
        await using (var connection = await repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = "SELECT file_id,parent_file_id,tombstone FROM entry_versions WHERE path_key='GONE.BIN' AND valid_to_revision IS NULL;";
            await using var reader = await command.ExecuteReaderAsync();
            Assert.True(await reader.ReadAsync());
            Assert.True(reader.IsDBNull(missingParent ? 1 : 0));
            Assert.Equal(24, ((byte[])reader.GetValue(missingParent ? 0 : 1)).Length);
            Assert.True(reader.GetBoolean(2));
        }
        var restored = temp.GetPath("restored");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 2, restored);
        Assert.Equal("retained content", await File.ReadAllTextAsync(Path.Combine(restored, "keep.bin")));
        Assert.False(File.Exists(Path.Combine(restored, "gone.bin")));
        await repository.MarkRevisionDeletedAsync(lease, source.SourceId, 1);
        Assert.Equal(1, (await repository.CompactDeletedRevisionsAsync(lease, source.SourceId)).CompactedRevisions);
        Assert.Equal(1, (await repository.CollectGarbageAsync(lease)).DeletedObjects);
        Assert.True((await new RepositoryVerifier().VerifyAsync(repository)).IsValid);
    }

    private sealed class NoCheckpoint : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(null, "full scan fixture");
    }

    private sealed class NoJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new PlatformNotSupportedException("full scan fixture");
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("The unavailable journal must not be read.");
    }
}
