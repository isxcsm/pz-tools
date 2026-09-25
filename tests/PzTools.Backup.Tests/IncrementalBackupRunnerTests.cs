using System.Globalization;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class IncrementalBackupRunnerTests
{
    private static readonly StorageOptions Storage = new(
        ChecksumAlgorithm.Sha256,
        CompressionAlgorithm.None,
        ContentDeduplication: false);

    private static readonly TelemetryOptions Telemetry = new(
        TelemetryMode.Off,
        BatchSize: 16,
        FlushIntervalMilliseconds: 10,
        RetainRuns: 10,
        MaxDatabaseMib: 32);

    [Fact]
    public async Task Run_UsesJournalAndCommitsOnlyEffectiveChanges()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var changedPath = Path.Combine(sourcePath, "changed.txt");
        var deletedPath = Path.Combine(sourcePath, "deleted.txt");
        await File.WriteAllTextAsync(changedPath, "before");
        await File.WriteAllTextAsync(deletedPath, "delete-me");
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        var metadata = new WindowsFileMetadataReader();
        var rootReference = Decode(metadata.ReadPath(sourcePath).Identity);
        var changedReference = Decode(metadata.ReadPath(changedPath).Identity);
        var deletedReference = Decode(metadata.ReadPath(deletedPath).Identity);

        await File.WriteAllTextAsync(changedPath, "after-and-longer");
        File.Delete(deletedPath);
        var addedPath = Path.Combine(sourcePath, "added.txt");
        await File.WriteAllTextAsync(addedPath, "added");
        var addedReference = Decode(metadata.ReadPath(addedPath).Identity);
        var journal = new FakeJournal(
            new UsnJournalState(1, 2, 0, 200, 0),
            [
                Record(changedReference, rootReference, 110, UsnReason.DataOverwrite, "changed.txt"),
                Record(deletedReference, rootReference, 120, UsnReason.FileDelete, "deleted.txt"),
                Record(addedReference, rootReference, 130, UsnReason.FileCreate, "added.txt"),
            ]);
        var runner = CreateIncrementalRunner(metadata, journal);

        var result = await runner.RunAsync(
            setup.Repository,
            setup.Telemetry,
            setup.Lease,
            setup.Source,
            Storage,
            Telemetry);

        Assert.Equal(BackupScanMode.Journal, result.ScanMode);
        Assert.Equal(2, result.Revision);
        Assert.Equal(3, result.ChangedEntries);
        Assert.Equal(200, result.Checkpoint?.NextUsn);
        var restore = temp.GetPath("restore");
        await new RevisionRestorer().RestoreAsync(
            setup.Repository,
            setup.Source.SourceId,
            revision: 2,
            restore);
        Assert.Equal("after-and-longer", await File.ReadAllTextAsync(
            Path.Combine(restore, "changed.txt")));
        Assert.Equal("added", await File.ReadAllTextAsync(Path.Combine(restore, "added.txt")));
        Assert.False(File.Exists(Path.Combine(restore, "deleted.txt")));
    }

    [Fact]
    public async Task Run_NoJournalChangesAdvancesCheckpointWithoutRevision()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "stable.txt"), "stable");
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        var metadata = new WindowsFileMetadataReader();
        var runner = CreateIncrementalRunner(
            metadata,
            new FakeJournal(new UsnJournalState(1, 2, 0, 250, 0), []));

        var result = await runner.RunAsync(
            setup.Repository,
            setup.Telemetry,
            setup.Lease,
            setup.Source,
            Storage,
            Telemetry);

        Assert.Null(result.Revision);
        Assert.Equal(0, result.ChangedEntries);
        var state = await setup.Repository.GetSourceStateAsync(setup.Source.SourceId);
        Assert.Equal(1, state.CurrentRevision);
        Assert.Equal(250, state.Checkpoint?.NextUsn);
    }

    [Fact]
    public async Task Run_InvalidJournalFallsBackToFullScan()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var filePath = Path.Combine(sourcePath, "file.txt");
        await File.WriteAllTextAsync(filePath, "before");
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        await File.WriteAllTextAsync(filePath, "after");
        var metadata = new WindowsFileMetadataReader();
        var runner = CreateIncrementalRunner(
            metadata,
            new FakeJournal(new UsnJournalState(1, 999, 0, 300, 0), []));

        var result = await runner.RunAsync(
            setup.Repository,
            setup.Telemetry,
            setup.Lease,
            setup.Source,
            Storage,
            Telemetry);

        Assert.Equal(BackupScanMode.FullScan, result.ScanMode);
        Assert.Equal(2, result.Revision);
        Assert.NotNull(result.FullScanReason);
        Assert.Equal("00000000000003E7", result.Checkpoint?.JournalId);
    }

    [Fact]
    public async Task Run_MissingCatalogIdentityReportsFullScanFallback()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "file.txt"), "content");
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        await using (var connection = await setup.Repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText =
                """
                UPDATE entry_versions
                SET file_id = NULL
                WHERE source_id = $sourceId
                  AND valid_to_revision IS NULL
                  AND tombstone = 0;
                """;
            command.Parameters.AddWithValue("$sourceId", setup.Source.SourceId);
            await command.ExecuteNonQueryAsync();
        }

        var metadata = new WindowsFileMetadataReader();
        var runner = CreateIncrementalRunner(
            metadata,
            new FakeJournal(new UsnJournalState(1, 2, 0, 300, 0), []));

        var result = await runner.RunAsync(
            setup.Repository,
            setup.Telemetry,
            setup.Lease,
            setup.Source,
            Storage,
            Telemetry);

        Assert.Equal(BackupScanMode.FullScan, result.ScanMode);
        Assert.Contains("lacks file identity", result.FullScanReason, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Run_FallbackComparesContentWithUnchangedMetadataOnlyWhenEnabled(bool enabled)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var path = Path.Combine(sourcePath, "file.bin");
        await File.WriteAllTextAsync(path, "before");
        var metadata = new FrozenTimesMetadataReader();
        var storage = Storage with { Checksum = ChecksumAlgorithm.None };
        await using var setup = await CreateInitialAsync(temp, sourcePath, metadata, storage);
        Assert.Equal(SHA256.HashData("before"u8), await ReadCurrentHashAsync(setup));
        await File.WriteAllTextAsync(path, "after!");
        var runner = CreateIncrementalRunner(metadata,
            new FakeJournal(new UsnJournalState(1, 999, 0, 300, 0), []), enabled);
        var result = await runner.RunAsync(setup.Repository, setup.Telemetry, setup.Lease,
            setup.Source, storage, Telemetry);
        Assert.Equal(BackupScanMode.FullScan, result.ScanMode);
        if (enabled)
        {
            Assert.Equal(2, result.Revision);
            var target = temp.GetPath("restore");
            await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, 2, target);
            Assert.Equal("after!", await File.ReadAllTextAsync(Path.Combine(target, "file.bin")));
            Assert.Equal(SHA256.HashData("after!"u8), await ReadCurrentHashAsync(setup));
        }
        else
        {
            Assert.Null(result.Revision);
            Assert.Equal(SHA256.HashData("before"u8), await ReadCurrentHashAsync(setup));
        }
    }

    [Fact]
    public async Task Run_JournalContentChangeIsCapturedEvenWhenMetadataMatchesAndHashComparisonIsOff()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var path = Path.Combine(sourcePath, "file.bin");
        await File.WriteAllTextAsync(path, "before");
        var metadata = new FrozenTimesMetadataReader();
        await using var setup = await CreateInitialAsync(temp, sourcePath, metadata);
        await File.WriteAllTextAsync(path, "after!");
        var journal = new FakeJournal(new UsnJournalState(1, 2, 0, 200, 0),
            [Record(Decode(metadata.ReadPath(path).Identity), Decode(metadata.ReadPath(sourcePath).Identity),
                110, UsnReason.DataOverwrite, "file.bin")]);
        var result = await CreateIncrementalRunner(metadata, journal, false).RunAsync(
            setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);
        Assert.Equal(BackupScanMode.Journal, result.ScanMode);
        Assert.Equal(2, result.Revision);
        var target = temp.GetPath("restore");
        await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, 2, target);
        Assert.Equal("after!", await File.ReadAllTextAsync(Path.Combine(target, "file.bin")));
        Assert.Null(await ReadCurrentHashAsync(setup));
        await using var connection = await setup.Repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM stored_objects WHERE content_hash IS NOT NULL";
        Assert.Equal(1L, await command.ExecuteScalarAsync());
    }

    [Theory]
    [InlineData(ChecksumAlgorithm.None, true)]
    [InlineData(ChecksumAlgorithm.Sha256, false)]
    public async Task Run_FallbackBuildsMissingBaselineOnceOrReusesCompatibleChecksum(
        ChecksumAlgorithm checksum, bool needsBaseline)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "file.bin"), "stable");
        var metadata = new FrozenTimesMetadataReader();
        var storage = Storage with { Checksum = checksum };
        await using var setup = await CreateInitialAsync(temp, sourcePath, metadata, storage, false);
        Assert.Null(await ReadCurrentHashAsync(setup));
        var journal = new UnavailableJournal();
        var runner = CreateIncrementalRunner(metadata, journal);
        var first = await runner.RunAsync(setup.Repository, setup.Telemetry, setup.Lease,
            setup.Source, storage, Telemetry);
        Assert.Equal(needsBaseline ? 2L : (long?)null, first.Revision);
        var second = await runner.RunAsync(setup.Repository, setup.Telemetry, setup.Lease,
            setup.Source, storage, Telemetry);
        Assert.Null(second.Revision);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Run_AlwaysIncludeOverridesFallbackModeAndSkipsNeverExistingFiles(bool enabled)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var path = Path.Combine(sourcePath, "file.bin");
        await File.WriteAllTextAsync(path, "before");
        var metadata = new FrozenTimesMetadataReader();
        await using var setup = await CreateInitialAsync(temp, sourcePath, metadata);
        await File.WriteAllTextAsync(path, "after!");
        var result = await CreateIncrementalRunner(metadata, new UnavailableJournal(), enabled).RunAsync(
            setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry,
            executionOptions: null, alwaysIncludePaths: ["file.bin", "not-created.db"]);
        Assert.Equal(2, result.Revision);
        Assert.Equal(1, result.ChangedEntries);
    }

    private static async Task<byte[]?> ReadCurrentHashAsync(Setup setup)
    {
        await using var connection = await setup.Repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT object.content_hash FROM entry_versions entry
            JOIN stored_objects object ON object.object_id = entry.object_id
            WHERE entry.valid_to_revision IS NULL AND entry.tombstone = 0
                AND entry.display_path = 'file.bin'
            """;
        return await command.ExecuteScalarAsync() as byte[];
    }

    [Fact]
    public async Task Run_FallbackSkipsUnchangedFileWithRealMetadata()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "file.bin"), "unchanged");
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        var result = await CreateIncrementalRunner(new WindowsFileMetadataReader(),
            new UnavailableJournal()).RunAsync(setup.Repository, setup.Telemetry, setup.Lease,
                setup.Source, Storage, Telemetry with { Mode = TelemetryMode.Phase });
        Assert.Equal(BackupScanMode.FullScan, result.ScanMode);
        Assert.Null(result.Revision);
        var events = await setup.Telemetry.ReadEventsAsync(result.RunIndex);
        Assert.Contains(events, item => item.Name == "progress.snapshot"
            && item.PayloadJson?.Contains("\"phase\":\"scan\"") == true);
        Assert.Contains(events, item => item.Name == "progress.snapshot"
            && item.PayloadJson?.Contains("\"phase\":\"hash\"") == true);
    }

    [Fact]
    public async Task Run_FailedFallbackHashReadDoesNotAdvanceRevisionOrCheckpoint()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var path = Path.Combine(sourcePath, "file.bin");
        await File.WriteAllTextAsync(path, "unchanged");
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        var before = await setup.Repository.GetSourceStateAsync(setup.Source.SourceId);
        // Metadata remains readable, but content reads are denied by the open writer.
        await using var blocker = new FileStream(path, FileMode.Open, FileAccess.Write,
            FileShare.Write | FileShare.Delete);
        var runner = CreateIncrementalRunner(new WindowsFileMetadataReader(),
            new FakeJournal(new UsnJournalState(1, 999, 0, 300, 0), []));
        await Assert.ThrowsAnyAsync<IOException>(() => runner.RunAsync(setup.Repository,
            setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry));
        var after = await setup.Repository.GetSourceStateAsync(setup.Source.SourceId);
        Assert.Equal(before.CurrentRevision, after.CurrentRevision);
        Assert.Equal(before.Checkpoint, after.Checkpoint);
        Assert.Equal(SHA256.HashData("unchanged"u8), await ReadCurrentHashAsync(setup));
    }

    [Theory]
    [InlineData(5, false)]
    [InlineData(32, false)]
    [InlineData(1117, false)]
    [InlineData(2, false)]
    [InlineData(3, false)]
    [InlineData(5, true)]
    [InlineData(2, true)]
    public async Task Run_UnreadableEntryDoesNotPublishDeletionOrAdvanceCheckpoint(int errorCode, bool alwaysInclude)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("source");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "file.bin");
        await File.WriteAllTextAsync(path, "original");
        await using var setup = await CreateInitialAsync(temp, root);
        var before = await setup.Repository.GetSourceStateAsync(setup.Source.SourceId);
        var real = new WindowsFileMetadataReader();
        var fault = new FailingPathMetadataReader(path, errorCode);
        var records = alwaysInclude ? Array.Empty<UsnRecord>() : new[]
        {
            Record(Decode(real.ReadPath(path).Identity), Decode(real.ReadPath(root).Identity),
                110, UsnReason.DataOverwrite, "file.bin"),
        };
        var runner = CreateIncrementalRunner(fault, new FakeJournal(new(1, 2, 0, 200, 0), records));

        var error = await Xunit.Record.ExceptionAsync(() => runner.RunAsync(setup.Repository, setup.Telemetry,
            setup.Lease, setup.Source, Storage, Telemetry, executionOptions: null,
            alwaysIncludePaths: alwaysInclude ? ["file.bin"] : []));
        Assert.NotNull(error);
        Assert.True(error is IOException or System.ComponentModel.Win32Exception);
        var after = await setup.Repository.GetSourceStateAsync(setup.Source.SourceId);
        Assert.Equal(before.CurrentRevision, after.CurrentRevision);
        Assert.Equal(before.Checkpoint, after.Checkpoint);
        Assert.Equal(SHA256.HashData("original"u8), await ReadCurrentHashAsync(setup));
    }

    [Fact]
    public async Task Run_DisconnectedSourceIsNotTreatedAsDeletedAlwaysIncludedFiles()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("source");
        Directory.CreateDirectory(root);
        await File.WriteAllTextAsync(Path.Combine(root, "file.bin"), "original");
        await using var setup = await CreateInitialAsync(temp, root);
        var before = await setup.Repository.GetSourceStateAsync(setup.Source.SourceId);
        var journal = new FakeJournal(new(1, 2, 0, 200, 0), [],
            () => Directory.Move(root, temp.GetPath("disconnected-source")));
        var runner = CreateIncrementalRunner(new WindowsFileMetadataReader(), journal);

        await Assert.ThrowsAnyAsync<IOException>(() => runner.RunAsync(setup.Repository, setup.Telemetry,
            setup.Lease, setup.Source, Storage, Telemetry, executionOptions: null,
            alwaysIncludePaths: ["file.bin"]));
        var after = await setup.Repository.GetSourceStateAsync(setup.Source.SourceId);
        Assert.Equal(before.CurrentRevision, after.CurrentRevision);
        Assert.Equal(before.Checkpoint, after.Checkpoint);
        Assert.Equal(SHA256.HashData("original"u8), await ReadCurrentHashAsync(setup));
    }

    private sealed class FailingPathMetadataReader(string failingPath, int errorCode) : IFileMetadataReader
    {
        private readonly WindowsFileMetadataReader inner = new();
        public FileCaptureMetadata ReadPath(string path) =>
            StringComparer.OrdinalIgnoreCase.Equals(path, failingPath)
                ? throw new System.ComponentModel.Win32Exception(errorCode)
                : inner.ReadPath(path);
        public FileCaptureMetadata ReadHandle(SafeFileHandle handle) => inner.ReadHandle(handle);
    }

    private sealed class FrozenTimesMetadataReader : IFileMetadataReader
    {
        private readonly WindowsFileMetadataReader inner = new();
        private static FileCaptureMetadata Freeze(FileCaptureMetadata item) => item with
        {
            ModifiedUtc = DateTimeOffset.UnixEpoch,
            ChangedUtc = DateTimeOffset.UnixEpoch,
            Usn = null,
        };
        public FileCaptureMetadata ReadPath(string path) => Freeze(inner.ReadPath(path));
        public FileCaptureMetadata ReadHandle(SafeFileHandle handle) => Freeze(inner.ReadHandle(handle));
    }

    private sealed class UnavailableJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) =>
            throw new System.ComponentModel.Win32Exception(50, "USN is not supported");
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("Must use full scan");
    }

    private static async Task<Setup> CreateInitialAsync(TempDirectory temp, string sourcePath,
        IFileMetadataReader? metadata = null, StorageOptions? storage = null, bool recordContentHash = true)
    {
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        metadata ??= new WindowsFileMetadataReader();
        await new InitialBackupRunner(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata, recordContentHash: recordContentHash),
            new FixedBoundaryProvider(new SourceCheckpoint("0000000000000001", "0000000000000002", 100)))
            .RunAsync(repository, telemetry, lease, source, storage ?? Storage, Telemetry);
        return new Setup(repository, telemetry, lease, source);
    }

    private static IncrementalBackupRunner CreateIncrementalRunner(
        IFileMetadataReader metadata,
        IUsnJournalSource journal,
        bool fullScanHashComparison = true) =>
        new(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata, recordContentHash: fullScanHashComparison),
            metadata,
            journal,
            new UsnDeltaPlanner(), fullScanHashComparison: fullScanHashComparison);

    private static UInt128 Decode(string identity)
    {
        var value = identity[(identity.LastIndexOf(':') + 1)..];
        return UInt128.Parse(value, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);
    }

    private static UsnRecord Record(
        UInt128 file,
        UInt128 parent,
        long usn,
        UsnReason reason,
        string name) =>
        new(
            3,
            0,
            file,
            parent,
            usn,
            DateTimeOffset.UtcNow,
            reason,
            0,
            FileAttributes.Normal,
            name);

    private sealed record Setup(
        RepositoryDatabase Repository,
        TelemetryStore Telemetry,
        RepositoryWriterLease Lease,
        RepositorySource Source) : IAsyncDisposable
    {
        public ValueTask DisposeAsync() => Lease.DisposeAsync();
    }

    private sealed class FixedBoundaryProvider(SourceCheckpoint checkpoint)
        : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(checkpoint, null);
    }

    private sealed class FakeJournal(
        UsnJournalState state,
        IReadOnlyList<UsnRecord> records,
        Action? onRead = null) : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => state;

        public IEnumerable<UsnRecord> ReadRange(
            string sourcePath,
            UsnCheckpoint checkpoint,
            long upperUsnExclusive,
            CancellationToken cancellationToken = default)
        {
            onRead?.Invoke();
            return records;
        }
    }
}
