using Microsoft.Win32.SafeHandles;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class CapturedLengthConsistencyTests
{
    [Theory]
    [InlineData(false, 4, 8192)]
    [InlineData(false, 8192, 4)]
    [InlineData(true, 4, 8192)]
    [InlineData(true, 8192, 4)]
    public async Task LengthChangesBeforeFirstHash_KeepCatalogObjectAndRestoredBytesConsistent(
        bool incremental, int originalLength, int updatedLength)
    {
        using var temp = new TempDirectory();
        var sourceRoot = temp.GetPath("source");
        Directory.CreateDirectory(sourceRoot);
        var path = Path.Combine(sourceRoot, "data.bin");
        await File.WriteAllBytesAsync(path, Enumerable.Repeat((byte)1, originalLength).ToArray());
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "test", sourceRoot);
        var telemetry = TelemetryStore.CreateDisabled(repository.RepositoryPath);
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 8, 10, 10, 32, false);
        var metadata = new WindowsFileMetadataReader();
        if (incremental)
        {
            await new InitialBackupRunner(new StreamingFullScanner(metadata),
                new StableFileCapturer(metadata), new NoBoundary()).RunAsync(
                    repository, telemetry, lease, source, storage, telemetryOptions);
            await File.WriteAllBytesAsync(path, Enumerable.Repeat((byte)2, originalLength).ToArray());
        }

        var expected = Enumerable.Repeat((byte)3, updatedLength).ToArray();
        var racingMetadata = new ChangeLengthAfterFirstHandleMetadataReader(path, expected);
        var capturer = new StableFileCapturer(racingMetadata, maxAttempts: 1);
        if (incremental)
        {
            await new IncrementalBackupRunner(new StreamingFullScanner(metadata), capturer, metadata,
                new NoJournal(), new UsnDeltaPlanner()).RunAsync(
                    repository, telemetry, lease, source, storage, telemetryOptions);
        }
        else
        {
            await new InitialBackupRunner(new StreamingFullScanner(metadata), capturer, new NoBoundary()).RunAsync(
                repository, telemetry, lease, source, storage, telemetryOptions);
        }

        var revision = incremental ? 2 : 1;
        var entry = Assert.Single(await repository.ReadRevisionEntriesAsync(source.SourceId, revision));
        Assert.Equal(updatedLength, entry.ByteLength);
        Assert.Equal(updatedLength, entry.OriginalLength);
        Assert.NotNull(racingMetadata.BeforeChange);
        Assert.Equal(racingMetadata.BeforeChange.ModifiedUtc, entry.ModifiedUtc);
        var locator = await repository.TryLocateRevisionFileAsync(source.SourceId, revision, "data.bin");
        Assert.NotNull(locator);
        Assert.Equal(expected, await new RevisionFileReader(repository).ReadBytesAsync(locator, 65536));
        var target = temp.GetPath("restored");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, revision, target);
        Assert.Equal(expected, await File.ReadAllBytesAsync(Path.Combine(target, "data.bin")));
    }

    private sealed class ChangeLengthAfterFirstHandleMetadataReader(string path, byte[] contents) : IFileMetadataReader
    {
        private readonly WindowsFileMetadataReader inner = new();
        internal FileCaptureMetadata? BeforeChange { get; private set; }
        public FileCaptureMetadata ReadPath(string value) => inner.ReadPath(value);
        public FileCaptureMetadata ReadHandle(SafeFileHandle handle)
        {
            var metadata = inner.ReadHandle(handle);
            if (BeforeChange is null)
            {
                BeforeChange = metadata;
                using var writer = new FileStream(path, FileMode.Open, FileAccess.Write,
                    FileShare.ReadWrite | FileShare.Delete);
                writer.Write(contents);
                writer.SetLength(contents.Length);
                writer.Flush(flushToDisk: true);
            }
            return metadata;
        }
    }

    private sealed class NoBoundary : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string path) => new(null, "isolated full scan fixture");
    }

    private sealed class NoJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new PlatformNotSupportedException();
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("This fixture requires a full scan.");
    }
}
