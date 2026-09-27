using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class RevisionRestoreTests
{
    [Fact]
    public async Task BackupTimes_UseHistoricalPlayerTimestampSeparatelyFromRecordedTime()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var players = Path.Combine(sourcePath, "players.db");
        await File.WriteAllTextAsync(players, "fixture");
        var played = new DateTimeOffset(2025, 1, 2, 3, 4, 6, TimeSpan.Zero);
        File.SetLastWriteTimeUtc(players, played.UtcDateTime);
        var context = await CreateRevisionAsync(temp, sourcePath);
        var original = Assert.Single(await context.Repository.ReadRevisionEntriesAsync(context.Source.SourceId, 1));
        await using (var lease = RepositoryWriterLease.Acquire(context.Repository.RepositoryPath))
        {
            var entries = new[]
            {
                new EntryVersionRegistration("directory", PzTools.Backup.Core.CatalogEntryKind.Directory, false, 0,
                    played, played, FileAttributes.Directory, null, null, null),
                new EntryVersionRegistration("players.db", PzTools.Backup.Core.CatalogEntryKind.File, false,
                    original.ByteLength, played.AddDays(1), played.AddDays(1), original.Attributes,
                    original.FileId, original.ParentFileId, original.ObjectId),
                new EntryVersionRegistration("players.db", PzTools.Backup.Core.CatalogEntryKind.File, true, 0,
                    played.AddDays(2), played.AddDays(2), FileAttributes.Normal, null, null, null),
            };
            foreach (var entry in entries)
            {
                var run = await context.Repository.StartRunAsync(lease, context.Source.SourceId);
                await context.Repository.CommitRevisionAsync(lease,
                    new RevisionCommitRequest(run.RunIndex, context.Source.SourceId, null, [], [], [entry]));
            }
        }
        // 현재 파일 시각이 바뀌어도 과거 백업의 마지막 플레이 시각에는 영향이 없습니다.
        File.SetLastWriteTimeUtc(players, DateTime.UtcNow);
        var views = new RevisionedViewStore();
        var projector = new BackupProjector(context.Repository, views);
        await projector.ProjectOnceAsync();
        var revisions = Assert.Single(views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0).Snapshot!.Sources)
            .Revisions.ToDictionary(item => item.Revision);
        Assert.Equal(played, revisions[1].LastPlayedUtc);
        Assert.Equal(played, revisions[2].LastPlayedUtc);
        Assert.Equal(played.AddDays(1), revisions[3].LastPlayedUtc);
        Assert.Null(revisions[4].LastPlayedUtc);
        var stored = Assert.Single((await context.Repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions;
        foreach (var revision in stored)
        {
            Assert.Equal(revision.CreatedUtc, revisions[revision.Revision].CreatedUtc);
            Assert.NotEqual(revisions[revision.Revision].LastPlayedUtc, revisions[revision.Revision].CreatedUtc);
        }

        await using (var lease = RepositoryWriterLease.Acquire(context.Repository.RepositoryPath))
        {
            await context.Repository.MarkRevisionDeletedAsync(lease, context.Source.SourceId, 1);
            await context.Repository.CompactDeletedRevisionsAsync(lease, context.Source.SourceId);
        }
        await projector.ProjectOnceAsync();
        var retained = Assert.Single(views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0).Snapshot!.Sources).Revisions;
        Assert.DoesNotContain(retained, revision => revision.Revision == 1);
        Assert.Equal(played, Assert.Single(retained, revision => revision.Revision == 2).LastPlayedUtc);
    }

    [Fact]
    public async Task Restore_RecreatesFilesDirectoriesAndMetadata()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        var nested = Path.Combine(sourcePath, "folder");
        Directory.CreateDirectory(nested);
        Directory.CreateDirectory(Path.Combine(sourcePath, "empty"));
        var filePath = Path.Combine(nested, "data.txt");
        await File.WriteAllTextAsync(filePath, "restorable-content");
        var expectedWrite = new DateTime(2025, 1, 2, 3, 4, 6, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(filePath, expectedWrite);
        var context = await CreateRevisionAsync(temp, sourcePath);
        var target = temp.GetPath("restore");

        var result = await new RevisionRestorer().RestoreAsync(
            context.Repository,
            context.Source.SourceId,
            revision: 1,
            target);

        Assert.Equal(1, result.Files);
        Assert.Equal(2, result.Directories);
        Assert.Equal("restorable-content", await File.ReadAllTextAsync(
            Path.Combine(target, "folder", "data.txt")));
        Assert.True(Directory.Exists(Path.Combine(target, "empty")));
        Assert.Equal(expectedWrite, File.GetLastWriteTimeUtc(
            Path.Combine(target, "folder", "data.txt")));
    }

    [Fact]
    public async Task Restore_RejectsNonEmptyTargetBeforeWriting()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "data.txt"), "data");
        var context = await CreateRevisionAsync(temp, sourcePath);
        var target = temp.GetPath("restore");
        Directory.CreateDirectory(target);
        await File.WriteAllTextAsync(Path.Combine(target, "keep.txt"), "keep");

        await Assert.ThrowsAsync<IOException>(() => new RevisionRestorer().RestoreAsync(
            context.Repository,
            context.Source.SourceId,
            revision: 1,
            target));

        Assert.Equal("keep", await File.ReadAllTextAsync(Path.Combine(target, "keep.txt")));
    }

    [Fact]
    public async Task SafeRestore_ReplacesExistingDirectoryWithoutExposingPartialFiles()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "new.txt"), "new");
        var context = await CreateRevisionAsync(temp, sourcePath);
        var target = temp.GetPath("restore");
        Directory.CreateDirectory(target);
        await File.WriteAllTextAsync(Path.Combine(target, "old.txt"), "old");

        var result = await new SafeRevisionRestoreService().RestoreReplacingAsync(
            context.Repository, context.Source.SourceId, 1, target);

        Assert.Equal(target, result.TargetPath);
        Assert.False(File.Exists(Path.Combine(target, "old.txt")));
        Assert.Equal("new", await File.ReadAllTextAsync(Path.Combine(target, "new.txt")));
        Assert.Empty(Directory.EnumerateFileSystemEntries(
            temp.Path, ".restore.pztools-*", SearchOption.TopDirectoryOnly));
    }

    [Fact]
    public async Task SafeRestore_DiscoveryNeverPublishesItsStagingCopy()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "map_ver.bin"), "new");
        var context = await CreateRevisionAsync(temp, sourcePath);
        var root = temp.GetPath("Saves");
        var target = Path.Combine(root, "Sandbox", "Save");
        Directory.CreateDirectory(target);
        await File.WriteAllTextAsync(Path.Combine(target, "map_ver.bin"), "old");
        var discovery = new PzTools.Zomboid.State.SaveDiscoveryLane();
        Assert.Single(discovery.Collect(root).Saves);
        var observedStagedMarker = false;

        await new SafeRevisionRestoreService().RestoreReplacingAsync(
            context.Repository, context.Source.SourceId, 1, target, (_, _) =>
            {
                var result = discovery.Collect(root);
                Assert.False(result.Complete);
                Assert.Empty(result.Saves);
                observedStagedMarker |= Directory.EnumerateDirectories(Path.GetDirectoryName(target)!)
                    .Where(path => !StringComparer.OrdinalIgnoreCase.Equals(path, target))
                    .Any(path => File.Exists(Path.Combine(path, "map_ver.bin")));
                return Task.CompletedTask;
            });

        Assert.True(observedStagedMarker);
        var completed = discovery.Collect(root);
        Assert.True(completed.Complete);
        Assert.Equal("Save", Assert.Single(completed.Saves).DisplayName);
    }

    [Theory]
    [InlineData("prepared", true, false, "old")]
    [InlineData("original-moved", false, true, "old")]
    [InlineData("installed", true, true, "new")]
    [InlineData("original-moved", true, true, "new")]
    public async Task SafeRestore_RecoversEveryDirectorySwapBoundary(
        string phase,
        bool targetExists,
        bool rollbackExists,
        string expected)
    {
        using var temp = new TempDirectory();
        var target = temp.GetPath("Save");
        var token = Guid.NewGuid().ToString("N");
        var staging = temp.GetPath($".Save.pztools-staging-{token}");
        var rollback = temp.GetPath($".Save.pztools-rollback-{token}");
        if (targetExists && expected == "old")
        {
            Directory.CreateDirectory(target);
            await File.WriteAllTextAsync(
                Path.Combine(target, "value.txt"), phase == "installed" ? "new" : "old");
        }
        Directory.CreateDirectory(staging);
        await File.WriteAllTextAsync(Path.Combine(staging, "value.txt"), "new");
        var stagingIdentity = new WindowsFileMetadataReader().ReadPath(staging).Identity;
        if (targetExists && expected == "new") Directory.Move(staging, target);
        if (rollbackExists)
        {
            Directory.CreateDirectory(rollback);
            await File.WriteAllTextAsync(Path.Combine(rollback, "value.txt"), "old");
        }
        var journal = temp.GetPath(".Save.pztools-restore.json");
        await File.WriteAllTextAsync(journal, System.Text.Json.JsonSerializer.Serialize(new
        {
            Version = 2,
            TargetPath = target,
            StagingPath = staging,
            RollbackPath = rollback,
            Phase = phase,
            StagingIdentity = stagingIdentity,
        }));

        await new SafeRevisionRestoreService().RecoverAsync(target);

        Assert.Equal(expected, await File.ReadAllTextAsync(Path.Combine(target, "value.txt")));
        Assert.False(Directory.Exists(staging));
        Assert.False(Directory.Exists(rollback));
        Assert.False(File.Exists(journal));
    }

    [Theory]
    [InlineData("prepared", 2, true)]
    [InlineData("original-moved", 2, true)]
    [InlineData("original-moved", 2, false)]
    [InlineData("installed", 2, false)]
    [InlineData("installed", 1, false)]
    public async Task SafeRestore_PreservesOriginalWhenAnUnrelatedTargetAppears(
        string phase, int version, bool stagingExists)
    {
        using var temp = new TempDirectory();
        var target = temp.GetPath("Save");
        var token = Guid.NewGuid().ToString("N");
        var staging = temp.GetPath($".Save.pztools-staging-{token}");
        var rollback = temp.GetPath($".Save.pztools-rollback-{token}");
        Directory.CreateDirectory(rollback);
        await File.WriteAllTextAsync(Path.Combine(rollback, "original.txt"), "irreplaceable-original");
        Directory.CreateDirectory(staging);
        await File.WriteAllTextAsync(Path.Combine(staging, "restored.txt"), "restored");
        var identity = new WindowsFileMetadataReader().ReadPath(staging).Identity;
        if (!stagingExists) Directory.Move(staging, temp.GetPath("moved-installed-save"));
        Directory.CreateDirectory(target); // An external actor recreates the save path after the crash.
        var journal = temp.GetPath(".Save.pztools-restore.json");
        await File.WriteAllTextAsync(journal, System.Text.Json.JsonSerializer.Serialize(new
        {
            Version = version, TargetPath = target, StagingPath = staging,
            RollbackPath = rollback, Phase = phase,
            StagingIdentity = version == 2 ? identity : null,
        }));

        for (var attempt = 0; attempt < 2; attempt++)
        {
            var error = await Assert.ThrowsAsync<IOException>(
                () => new SafeRevisionRestoreService().RecoverAsync(target));
            Assert.Contains("restore-target-conflict", error.Message);
            Assert.Equal("irreplaceable-original", await File.ReadAllTextAsync(Path.Combine(rollback, "original.txt")));
            Assert.Equal(stagingExists, Directory.Exists(staging));
            Assert.Empty(Directory.GetFileSystemEntries(target));
            Assert.True(File.Exists(journal));
        }
    }

    [Fact]
    public async Task SafeRestore_MissingTargetAndRollbackPreservesTheOnlyStagedCopy()
    {
        using var temp = new TempDirectory();
        var target = temp.GetPath("Save");
        var token = Guid.NewGuid().ToString("N");
        var staging = temp.GetPath($".Save.pztools-staging-{token}");
        var rollback = temp.GetPath($".Save.pztools-rollback-{token}");
        Directory.CreateDirectory(staging);
        await File.WriteAllTextAsync(Path.Combine(staging, "data.txt"), "only-copy");
        var journal = temp.GetPath(".Save.pztools-restore.json");
        await File.WriteAllTextAsync(journal, System.Text.Json.JsonSerializer.Serialize(new
        {
            Version = 2, TargetPath = target, StagingPath = staging,
            RollbackPath = rollback, Phase = "original-moved",
            StagingIdentity = new WindowsFileMetadataReader().ReadPath(staging).Identity,
        }));

        await Assert.ThrowsAsync<IOException>(() => new SafeRevisionRestoreService().RecoverAsync(target));
        Assert.Equal("only-copy", await File.ReadAllTextAsync(Path.Combine(staging, "data.txt")));
        Assert.True(File.Exists(journal));
    }

    [Fact]
    public async Task SafeRestore_ResumesRecoveryAfterOriginalWasMovedBack()
    {
        using var temp = new TempDirectory();
        var target = temp.GetPath("Save");
        var token = Guid.NewGuid().ToString("N");
        var staging = temp.GetPath($".Save.pztools-staging-{token}");
        var rollback = temp.GetPath($".Save.pztools-rollback-{token}");
        Directory.CreateDirectory(staging);
        Directory.CreateDirectory(rollback);
        await File.WriteAllTextAsync(Path.Combine(rollback, "data.txt"), "original");
        var reader = new WindowsFileMetadataReader();
        var journal = temp.GetPath(".Save.pztools-restore.json");
        await File.WriteAllTextAsync(journal, System.Text.Json.JsonSerializer.Serialize(new
        {
            Version = 2, TargetPath = target, StagingPath = staging,
            RollbackPath = rollback, Phase = "original-moved",
            StagingIdentity = reader.ReadPath(staging).Identity,
            OriginalIdentity = reader.ReadPath(rollback).Identity,
        }));
        Directory.Move(rollback, target); // Crash after returning the original, before cleanup.

        var service = new SafeRevisionRestoreService();
        await service.RecoverAsync(target);
        await service.RecoverAsync(target);
        Assert.Equal("original", await File.ReadAllTextAsync(Path.Combine(target, "data.txt")));
        Assert.False(Directory.Exists(staging));
        Assert.False(File.Exists(journal));
    }

    [Fact]
    public async Task SafeRestore_RejectsJournalInventoryOutsideTargetParent()
    {
        using var temp = new TempDirectory();
        var target = temp.GetPath("Save");
        Directory.CreateDirectory(target);
        var outside = temp.GetPath("outside");
        Directory.CreateDirectory(outside);
        var token = Guid.NewGuid().ToString("N");
        var journal = temp.GetPath(".Save.pztools-restore.json");
        await File.WriteAllTextAsync(journal, System.Text.Json.JsonSerializer.Serialize(new
        {
            Version = 1,
            TargetPath = target,
            StagingPath = outside,
            RollbackPath = temp.GetPath($".Save.pztools-rollback-{token}"),
            Phase = "prepared",
        }));

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new SafeRevisionRestoreService().RecoverAsync(target));

        Assert.True(Directory.Exists(outside));
    }

    [Fact]
    public async Task Verify_ReportsCorruptPackAndAffectedRevision()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "data.txt"), "data");
        var context = await CreateRevisionAsync(temp, sourcePath);
        var packPath = Directory.GetFiles(
            Path.Combine(context.Repository.RepositoryPath, "packs"),
            "*.pzpack").Single();
        await using (var stream = new FileStream(packPath, FileMode.Open, FileAccess.Write))
        {
            stream.SetLength(stream.Length - 1);
        }

        var result = await new RepositoryVerifier().VerifyAsync(context.Repository);

        var issue = Assert.Single(result.Issues);
        Assert.False(result.IsValid);
        Assert.Contains(new RevisionReference(context.Source.SourceId, 1), issue.AffectedRevisions);
    }

    [Fact]
    public async Task Restore_RejectsFileAncestorBeforeCreatingTarget()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "parent"), "file");
        var context = await CreateRevisionAsync(temp, sourcePath);
        await using (var connection = await context.Repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText =
                """
                INSERT INTO paths(path_key) VALUES('PARENT/CHILD');
                INSERT INTO path_spellings(path_id,spelling_id,display_path)
                    SELECT path_id,0,'parent/child' FROM paths WHERE path_key='PARENT/CHILD';
                INSERT INTO entry_versions(
                    source_id, path_id, spelling_id, valid_from_revision,
                    entry_kind, tombstone, byte_length, modified_utc, changed_utc,
                    attributes, file_id, parent_file_id, object_id)
                VALUES (
                    $sourceId, (SELECT path_id FROM paths WHERE path_key='PARENT/CHILD'), 0, 1,
                    'Directory', 0, 0, $now, $now, $attributes, NULL, NULL, NULL);
                """;
            command.Parameters.AddWithValue("$sourceId", context.Source.SourceId);
            command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.UtcTicks);
            command.Parameters.AddWithValue("$attributes", (long)FileAttributes.Directory);
            await command.ExecuteNonQueryAsync();
        }

        var target = temp.GetPath("restore-invalid");
        await Assert.ThrowsAsync<InvalidDataException>(() => new RevisionRestorer().RestoreAsync(
            context.Repository,
            context.Source.SourceId,
            1,
            target));
        Assert.False(Directory.Exists(target));
    }

    [Fact]
    public async Task RevisionFileReader_ReadsInheritedThumbnailWithoutRestoringRevision()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var png = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4 };
        await File.WriteAllBytesAsync(Path.Combine(sourcePath, "thumb.png"), png);
        var context = await CreateRevisionAsync(temp, sourcePath);
        await using (var lease = RepositoryWriterLease.Acquire(context.Repository.RepositoryPath))
        {
            var run = await context.Repository.StartRunAsync(lease, context.Source.SourceId);
            var now = DateTimeOffset.UtcNow;
            await context.Repository.CommitRevisionAsync(
                lease,
                new RevisionCommitRequest(
                    run.RunIndex, context.Source.SourceId, null, [], [],
                    [new EntryVersionRegistration(
                        "new-directory", PzTools.Backup.Core.CatalogEntryKind.Directory,
                        false, 0, now, now, FileAttributes.Directory,
                        null, null, null)]));
        }

        var locator = await context.Repository.TryLocateRevisionFileAsync(
            context.Source.SourceId, 2, "thumb.png");
        Assert.NotNull(locator);
        var reader = new RevisionFileReader(context.Repository);
        Assert.Equal(png, await reader.ReadBytesAsync(locator, 1024));
        await using var temporary = await reader.MaterializeTemporaryAsync(
            locator, temp.GetPath("materialized"));
        Assert.True((File.GetAttributes(temporary.Path) & FileAttributes.ReadOnly) != 0);
        Assert.Equal(png, await File.ReadAllBytesAsync(temporary.Path));

        var cache = new ThumbnailCache(1024);
        var key = $"revision:{context.Source.SourceId}:2";
        Assert.Equal(png, await cache.ReadRevisionThumbnailAsync(
            key, context.Repository, context.Source.SourceId, 2));
    }

    private static async Task<BackupContext> CreateRevisionAsync(
        TempDirectory temp,
        string sourcePath)
    {
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var metadata = new WindowsFileMetadataReader();
        var runner = new InitialBackupRunner(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata),
            new NullBoundaryProvider());
        await runner.RunAsync(
            repository,
            telemetry,
            lease,
            source,
            new StorageOptions(
                ChecksumAlgorithm.Sha256,
                CompressionAlgorithm.Brotli,
                ContentDeduplication: false),
            new TelemetryOptions(
                TelemetryMode.Off,
                BatchSize: 16,
                FlushIntervalMilliseconds: 10,
                RetainRuns: 10,
                MaxDatabaseMib: 32));
        return new BackupContext(repository, source);
    }

    private sealed record BackupContext(
        RepositoryDatabase Repository,
        RepositorySource Source);

    private sealed class NullBoundaryProvider : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) =>
            new(Checkpoint: null, FallbackReason: "test");
    }
}
