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
    public async Task FullScanOnLocalNtfs_TrustsMetadataThatSettledBeforeTheLastRevision()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var lockedPath = Path.Combine(sourcePath, "map_1_1.bin");
        await File.WriteAllBytesAsync(lockedPath, [1, 2, 3]);
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        Assert.True(LocalVolume.IsLocalNtfs(sourcePath), "The test folder must be on local NTFS.");
        // As if the file had been written well before the run that made revision 1.
        await MoveLatestRevisionRunStartAsync(setup.Repository, TimeSpan.FromMinutes(5));
        var runner = CreateIncrementalRunner(new WindowsFileMetadataReader(), new UnavailableJournal());

        // Locked so that it cannot be read: a content comparison would fail the run.
        await using (new FileStream(lockedPath, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var result = await runner.RunAsync(setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);
            Assert.Equal(BackupScanMode.FullScan, result.ScanMode);
            Assert.Null(result.Revision);
        }
    }

    [Fact]
    public async Task FullScanOnLocalNtfs_StillComparesFilesWrittenAroundTheLastRun()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var lockedPath = Path.Combine(sourcePath, "map_1_1.bin");
        await File.WriteAllBytesAsync(lockedPath, [1, 2, 3]);
        // Written moments before the run began: inside the margin, so its content is compared.
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        var runner = CreateIncrementalRunner(new WindowsFileMetadataReader(), new UnavailableJournal());

        await using (new FileStream(lockedPath, FileMode.Open, FileAccess.Read, FileShare.None))
            await Assert.ThrowsAnyAsync<IOException>(() =>
                runner.RunAsync(setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry));
    }

    [Fact]
    public async Task FullScanOnLocalNtfs_ASameSizeRewriteWithItsOldTimeRestoredIsStillCaptured()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var path = Path.Combine(sourcePath, "map_1_1.bin");
        await File.WriteAllBytesAsync(path, [1, 2, 3]);
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        await MoveLatestRevisionRunStartAsync(setup.Repository, TimeSpan.FromMinutes(5));
        var written = File.GetLastWriteTimeUtc(path);
        await File.WriteAllBytesAsync(path, [9, 9, 9]);
        File.SetLastWriteTimeUtc(path, written); // The change time still moves.
        var runner = CreateIncrementalRunner(new WindowsFileMetadataReader(), new UnavailableJournal());

        var result = await runner.RunAsync(setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);

        Assert.Equal(2, result.Revision);
        var restore = temp.GetPath("restore");
        await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, revision: 2, restore);
        Assert.Equal([9, 9, 9], await File.ReadAllBytesAsync(Path.Combine(restore, "map_1_1.bin")));
    }

    [Fact]
    public async Task RewriteWithTheSameBytes_ReusesItsObject_ButAMatchingFingerprintAloneDoesNot()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var same = Path.Combine(sourcePath, "map_1_1.bin");
        var changed = Path.Combine(sourcePath, "map_1_2.bin");
        await File.WriteAllBytesAsync(same, [1, 2, 3, 4]);
        await File.WriteAllBytesAsync(changed, [5, 6, 7, 8]);
        await using var setup = await CreateInitialAsync(temp, sourcePath);
        var objectsBefore = await CountObjectsAsync(setup.Repository);
        var sameObject = await CurrentObjectAsync(setup.Repository, "map_1_1.bin");

        // As the game saves: the same bytes written again, and new bytes of the same length.
        await File.WriteAllBytesAsync(same, [1, 2, 3, 4]);
        await File.WriteAllBytesAsync(changed, [9, 9, 9, 9]);
        File.SetLastWriteTimeUtc(same, DateTime.UtcNow.AddMinutes(1));
        // Make the changed file's old object claim the new fingerprint: only the byte comparison can tell.
        await using (var connection = await setup.Repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText =
                """
                UPDATE stored_objects SET content_hash=$hash WHERE object_id=(
                    SELECT entry.object_id FROM current_entry_catalog AS entry WHERE entry.path_key='MAP_1_2.BIN');
                """;
            command.Parameters.AddWithValue("$hash", ContentFingerprint.FromSha256(SHA256.HashData(new byte[] { 9, 9, 9, 9 })));
            Assert.Equal(1, await command.ExecuteNonQueryAsync());
        }
        var metadata = new WindowsFileMetadataReader();
        var capturer = new StableFileCapturer(metadata);
        await using var deduplicating = new DeduplicatingFileCapturer(capturer);
        var runner = new IncrementalBackupRunner(new StreamingFullScanner(metadata), capturer, metadata,
            new UnavailableJournal(), new UsnDeltaPlanner(), deduplicatingCapturer: deduplicating);

        var result = await runner.RunAsync(setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);

        Assert.Equal(2, result.Revision);
        Assert.Equal(2, result.ChangedEntries);
        Assert.Equal(objectsBefore + 1, await CountObjectsAsync(setup.Repository));
        Assert.Equal(sameObject, await CurrentObjectAsync(setup.Repository, "map_1_1.bin"));
        var restore = temp.GetPath("restore");
        await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, revision: 2, restore);
        Assert.Equal([1, 2, 3, 4], await File.ReadAllBytesAsync(Path.Combine(restore, "map_1_1.bin")));
        Assert.Equal([9, 9, 9, 9], await File.ReadAllBytesAsync(Path.Combine(restore, "map_1_2.bin")));
        var previous = temp.GetPath("previous");
        await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, revision: 1, previous);
        Assert.Equal([5, 6, 7, 8], await File.ReadAllBytesAsync(Path.Combine(previous, "map_1_2.bin")));
    }

    private static async Task<long> CountObjectsAsync(RepositoryDatabase repository)
    {
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM stored_objects;";
        return Convert.ToInt64(await command.ExecuteScalarAsync(), CultureInfo.InvariantCulture);
    }

    private static async Task<Guid> CurrentObjectAsync(RepositoryDatabase repository, string relativePath)
    {
        var current = await repository.ReadCurrentFileObjectsAsync(1, [relativePath]);
        return Assert.Single(current).Value.Object.ObjectId;
    }

    [FatVolumeFact]
    public async Task FullScanOnFat_BacksUpAndCapturesASameSizeRewriteWithItsOldTimeRestored()
    {
        using var temp = new TempDirectory();
        var sourcePath = Path.Combine(Environment.GetEnvironmentVariable("PZTOOLS_TEST_FAT_DIR")!, "pz-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(sourcePath);
        try
        {
            var path = Path.Combine(sourcePath, "map_1_1.bin");
            await File.WriteAllBytesAsync(path, [1, 2, 3]);
            Assert.False(LocalVolume.IsLocalNtfs(sourcePath), "PZTOOLS_TEST_FAT_DIR must not be on NTFS.");
            // FAT32 refuses the newer file-ID query; reading metadata must still work.
            Assert.Equal(FileIdentityCodec.EncodedLength, FileIdentityCodec.Encode(new WindowsFileMetadataReader().ReadPath(path).Identity).Length);
            await using var setup = await CreateInitialAsync(temp, sourcePath);
            await MoveLatestRevisionRunStartAsync(setup.Repository, TimeSpan.FromMinutes(5));
            var written = File.GetLastWriteTimeUtc(path);
            await File.WriteAllBytesAsync(path, [9, 9, 9]);
            File.SetLastWriteTimeUtc(path, written); // FAT keeps no change time: only the content differs.
            var runner = CreateIncrementalRunner(new WindowsFileMetadataReader(), new UnavailableJournal());

            var result = await runner.RunAsync(setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);

            Assert.Equal(2, result.Revision);
            var restore = temp.GetPath("restore");
            await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, revision: 2, restore);
            Assert.Equal([9, 9, 9], await File.ReadAllBytesAsync(Path.Combine(restore, "map_1_1.bin")));
        }
        finally
        {
            Directory.Delete(sourcePath, recursive: true);
        }
    }

    private sealed class FatVolumeFactAttribute : FactAttribute
    {
        public FatVolumeFactAttribute()
        {
            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("PZTOOLS_TEST_FAT_DIR")))
            {
                Skip = "Set PZTOOLS_TEST_FAT_DIR to a folder on a FAT32 or exFAT drive.";
            }
        }
    }

    private static async Task MoveLatestRevisionRunStartAsync(RepositoryDatabase repository, TimeSpan later)
    {
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "UPDATE workflow_stages SET started_utc=$started WHERE producer='backup-worker' AND run_index=(SELECT MAX(run_index) FROM revisions);";
        command.Parameters.AddWithValue("$started", DateTimeOffset.UtcNow.Add(later).ToString("O"));
        Assert.Equal(1, await command.ExecuteNonQueryAsync());
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
        Assert.Equal(SHA256.HashData("before"u8)[..16], await ReadCurrentHashAsync(setup));
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
            Assert.Equal(SHA256.HashData("after!"u8)[..16], await ReadCurrentHashAsync(setup));
        }
        else
        {
            Assert.Null(result.Revision);
            Assert.Equal(SHA256.HashData("before"u8)[..16], await ReadCurrentHashAsync(setup));
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
            SELECT object.content_hash FROM entry_catalog entry
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
        Assert.Equal(SHA256.HashData("unchanged"u8)[..16], await ReadCurrentHashAsync(setup));
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
        Assert.Equal(SHA256.HashData("original"u8)[..16], await ReadCurrentHashAsync(setup));
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
        Assert.Equal(SHA256.HashData("original"u8)[..16], await ReadCurrentHashAsync(setup));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Run_DirectoryReplacedByFile_DeletesItsFormerChildren(bool fullScanWithAlwaysIncludedChild)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("source");
        var folder = Path.Combine(root, "folder");
        Directory.CreateDirectory(folder);
        var child = Path.Combine(folder, "child.bin");
        await File.WriteAllTextAsync(child, "old child");
        var metadata = new WindowsFileMetadataReader();
        var rootReference = Decode(metadata.ReadPath(root).Identity);
        var oldFolderReference = Decode(metadata.ReadPath(folder).Identity);
        var oldChildReference = Decode(metadata.ReadPath(child).Identity);
        await using var setup = await CreateInitialAsync(temp, root);
        Directory.Delete(folder, recursive: true);
        await File.WriteAllTextAsync(folder, "replacement file");
        var records = new[]
        {
            Record(oldChildReference, oldFolderReference, 110, UsnReason.FileDelete, "child.bin"),
            Record(oldFolderReference, rootReference, 120, UsnReason.FileDelete, "folder")
                with { FileAttributes = FileAttributes.Directory },
            Record(Decode(metadata.ReadPath(folder).Identity), rootReference, 130, UsnReason.FileCreate, "folder"),
        };
        IUsnJournalSource journal = fullScanWithAlwaysIncludedChild
            ? new UnavailableJournal() : new FakeJournal(new(1, 2, 0, 200, 0), records);
        var result = await CreateIncrementalRunner(metadata, journal).RunAsync(
            setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry,
            executionOptions: null, alwaysIncludePaths: fullScanWithAlwaysIncludedChild ? ["folder/child.bin"] : []);

        Assert.Equal(2, result.Revision);
        Assert.Equal(fullScanWithAlwaysIncludedChild ? BackupScanMode.FullScan : BackupScanMode.Journal, result.ScanMode);
        var entry = Assert.Single(await setup.Repository.ReadRevisionEntriesAsync(setup.Source.SourceId, 2));
        Assert.Equal("folder", entry.RelativePath);
        Assert.Equal("File", entry.EntryKind);
        var target = temp.GetPath("restored");
        await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, 2, target);
        Assert.Equal("replacement file", await File.ReadAllTextAsync(Path.Combine(target, "folder")));
    }

    [Theory]
    // A RAM disk without a volume name (ERROR_NOT_A_REPARSE_POINT), when the journal is queried.
    [InlineData(4390, false)]
    // A journal deleted or wrapped past the checkpoint while it is read (ERROR_JOURNAL_ENTRY_DELETED).
    [InlineData(1181, true)]
    public async Task Run_AJournalThatFails_FallsBackToAFullScan(int errorCode, bool whileReading)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("source");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "file.bin");
        await File.WriteAllTextAsync(path, "original");
        await using var setup = await CreateInitialAsync(temp, root);
        await File.WriteAllTextAsync(path, "changed");

        var result = await CreateIncrementalRunner(new WindowsFileMetadataReader(), new FailingJournal(errorCode, whileReading))
            .RunAsync(setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry,
                executionOptions: null, alwaysIncludePaths: []);

        Assert.Equal(2, result.Revision);
        Assert.Equal(BackupScanMode.FullScan, result.ScanMode);
        Assert.Equal(SHA256.HashData("changed"u8)[..16], await ReadCurrentHashAsync(setup));
        // Nor does taking the next checkpoint fail the backup.
        Assert.Null(new WindowsCheckpointBoundaryProvider(new FailingJournal(errorCode, false)).Capture(root).Checkpoint);
    }

    private sealed class FailingJournal(int errorCode, bool whileReading) : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) =>
            whileReading ? new(1, 2, 0, 200, 0) : throw new System.ComponentModel.Win32Exception(errorCode);
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default)
        {
            yield return Record(1, 2, 110, UsnReason.DataOverwrite, "file.bin");
            throw new System.ComponentModel.Win32Exception(errorCode);
        }
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
