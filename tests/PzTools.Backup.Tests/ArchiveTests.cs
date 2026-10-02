using PzTools.Process.Contracts;
using System.IO.Compression;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Zomboid.Archive;

namespace PzTools.Backup.Tests;

public sealed class ArchiveTests
{
    [Fact]
    public async Task LiveExportAndImport_ReportBytesWithinOneLargeFile()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        var content = new byte[4 * 1024 * 1024];
        new Random(42).NextBytes(content);
        await File.WriteAllBytesAsync(Path.Combine(source, "players.db"), content);
        var service = new ZomboidArchiveService();
        var progress = new List<ArchiveProgress>();
        Task Report(ArchiveProgress value, CancellationToken _) { progress.Add(value); return Task.CompletedTask; }
        await service.ExportLiveAsync(source, "Sandbox/Current", temp.GetPath("save.zip"), Report);
        var imported = await service.ImportAsync(temp.GetPath("save.zip"), temp.GetPath("Imported"), Report);
        // The current save goes straight into the archive; there is no separate copy phase.
        Assert.DoesNotContain(progress, value => value.Phase == "archive.snapshot");
        foreach (var phase in new[] { "archive.compress", "import" })
        {
            var updates = progress.Where(value => value.Phase == phase).ToArray();
            Assert.Contains(updates, value => value.CompletedItems == 0
                && value.CompletedBytes > 0 && value.CompletedBytes < value.TotalBytes);
            Assert.Equal(updates.Select(value => value.CompletedBytes).Order(), updates.Select(value => value.CompletedBytes));
            Assert.Equal(content.Length, updates[^1].CompletedBytes);
            Assert.Equal(1, updates[^1].CompletedItems);
        }
        Assert.Equal(content, await File.ReadAllBytesAsync(Path.Combine(imported.DestinationPath, "players.db")));
    }

    [Fact]
    public async Task Inspect_ReportsCharacterFromArchivedPlayersDatabase()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("Sandbox", "CharacterSave");
        Directory.CreateDirectory(source);
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                     { DataSource = Path.Combine(source, "players.db"), Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER, name TEXT, isDead INTEGER); "
                + "INSERT INTO localPlayers VALUES(1, 'Archived Character', 0);";
            await command.ExecuteNonQueryAsync();
        }

        var service = new ZomboidArchiveService();
        var archive = temp.GetPath("character.zip");
        await service.ExportLiveAsync(source, "Sandbox/CharacterSave", archive);

        var inspection = await service.InspectAsync(archive);

        Assert.Equal("Archived Character", inspection.CharacterName);
        Assert.Null(inspection.HoursSurvived);
    }

    [Fact]
    public async Task BackupService_UsesConfiguredLanguageForStoredDefaultName()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        await File.WriteAllTextAsync(Path.Combine(source, "players.db"), "player");
        var repositoryPath = temp.GetPath("repository");
        var options = new BackupOptions(
            BackupConfiguration.CurrentFormatVersion,
            repositoryPath,
            [new BackupSourceOptions("Sandbox/Save", source)],
            new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false),
            new TelemetryOptions(TelemetryMode.Off, 16, 10, 10, 32),
            NameLanguage: SupportedLanguage.English);

        await new OneShotBackupService(new NoJournal()).RunAsync(options, "Sandbox/Save");
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var revision = Assert.Single(Assert.Single(
            (await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        Assert.Equal("Manual backup 1", revision.DisplayName);
    }

    [Fact]
    public async Task ExportLive_WithoutBackup_RoundTripsCurrentFilesAndEmptyDirectories()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("Sandbox", "Current");
        Directory.CreateDirectory(Path.Combine(source, "empty"));
        Directory.CreateDirectory(Path.Combine(source, "nested"));
        await File.WriteAllTextAsync(Path.Combine(source, "players.db"), "current-player");
        await File.WriteAllTextAsync(Path.Combine(source, "nested", "map.bin"), "latest-map");
        var service = new ZomboidArchiveService();
        var progress = new List<ArchiveProgress>();
        var archive = temp.GetPath("current.zip");

        var exported = await service.ExportLiveAsync(source, "Sandbox/Current", archive,
            (value, _) => { progress.Add(value); return Task.CompletedTask; });
        using (var zip = ZipFile.OpenRead(archive))
        {
            Assert.NotNull(zip.GetEntry("Sandbox/"));
            Assert.NotNull(zip.GetEntry("Sandbox/Current/"));
            Assert.NotNull(zip.GetEntry("Sandbox/Current/players.db"));
            Assert.NotNull(zip.GetEntry("Sandbox/Current/nested/map.bin"));
            Assert.NotNull(zip.GetEntry("Sandbox/Current/pztools-manifest.json"));
            Assert.Null(zip.GetEntry("players.db"));
            Assert.Null(zip.GetEntry("pztools-manifest.json"));
        }
        var inspected = await service.InspectAsync(archive);
        var imported = await service.ImportAsync(archive, temp.GetPath("Imported"));

        Assert.Equal(0, inspected.Manifest.SourceId);
        Assert.Equal(2, inspected.Manifest.Version);
        Assert.Equal(0, inspected.Manifest.Revision);
        Assert.Equal("Sandbox/Current", inspected.Manifest.SaveId);
        Assert.Equal(2, exported.Files);
        Assert.Equal("current-player", await File.ReadAllTextAsync(Path.Combine(imported.DestinationPath, "players.db")));
        Assert.Equal("latest-map", await File.ReadAllTextAsync(Path.Combine(imported.DestinationPath, "nested", "map.bin")));
        Assert.True(Directory.Exists(Path.Combine(imported.DestinationPath, "empty")));
        var events = progress.Where(value => value.Phase == "archive.compress").ToArray();
        Assert.Equal(new long[] { 0, 1, 2 }, events.Select(value => value.CompletedItems).Distinct());
        Assert.Equal(events[^1].TotalBytes, events[^1].CompletedBytes);
        Assert.Equal(["archive.compress", "archive.finalize"], progress.Select(value => value.Phase).Distinct());
        Assert.Equal(2, Directory.GetFiles(source, "*", SearchOption.AllDirectories).Length);
    }

    [Theory]
    [InlineData("archive.compress")]
    [InlineData("archive.finalize")]
    public async Task ExportLive_RejectsChangedSourceWithoutReplacingExistingArchive(string phase)
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        var player = Path.Combine(source, "players.db");
        await File.WriteAllTextAsync(player, "before");
        var archive = temp.GetPath("existing.zip");
        await File.WriteAllTextAsync(archive, "existing-output");

        await Assert.ThrowsAsync<IOException>(() => new ZomboidArchiveService().ExportLiveAsync(
            source, "Sandbox/Current", archive, async (value, _) =>
            {
                if (value.Phase == phase && (phase == "archive.finalize" || value.CompletedItems == 1))
                    await File.WriteAllTextAsync(player, "changed-during-export");
            }));

        Assert.Equal("existing-output", await File.ReadAllTextAsync(archive));
        Assert.Empty(Directory.GetFiles(temp.Path, "*.tmp"));
    }

    [Fact]
    public async Task ExportLive_RejectsAFileThatGrowsBeforeItIsRead()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        await File.WriteAllTextAsync(Path.Combine(source, "players.db"), "player");
        var map = Path.Combine(source, "zz-map.bin");
        await File.WriteAllTextAsync(map, "short");
        var archive = temp.GetPath("existing.zip");
        await File.WriteAllTextAsync(archive, "existing-output");

        // The file is longer than when the save was listed by the time it is compressed.
        var error = await Assert.ThrowsAsync<IOException>(() => new ZomboidArchiveService().ExportLiveAsync(
            source, "Sandbox/Current", archive, async (value, _) =>
            {
                // Right after players.db is done, before zz-map.bin is opened.
                if (value.Phase == "archive.compress" && value.CompletedItems == 1
                    && value.RelativePath!.EndsWith("players.db", StringComparison.Ordinal))
                    await File.WriteAllTextAsync(map, "much longer than before");
            }));

        Assert.True(error.Message.Contains("changed during export"), error.ToString());
        Assert.Equal("existing-output", await File.ReadAllTextAsync(archive));
        Assert.Empty(Directory.GetFiles(temp.Path, "*.tmp"));
    }

    [Fact]
    public async Task ExportLive_RejectsOutputInsideSaveAndInvalidSave()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        var service = new ZomboidArchiveService();
        await Assert.ThrowsAsync<ArgumentException>(() => service.ExportLiveAsync(
            source, "Sandbox/Current", Path.Combine(source, "save.zip")));
        await Assert.ThrowsAsync<InvalidDataException>(() => service.ExportLiveAsync(
            source, "Sandbox/Current", temp.GetPath("outside.zip")));
        Assert.Empty(Directory.GetFiles(source));
        Assert.False(File.Exists(temp.GetPath("outside.zip")));
    }

    [Fact]
    public async Task ExportInspectImport_RoundTripsAndResolvesNameCollision()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        await File.WriteAllBytesAsync(Path.Combine(source, "thumb.png"),
            [137, 80, 78, 71, 13, 10, 26, 10, 1]);
        await File.WriteAllTextAsync(Path.Combine(source, "players.db"), "player");
        await File.WriteAllTextAsync(Path.Combine(source, "map.bin"), "map");
        // 실제 map_visited.bin처럼 반복 바이트가 많은 파일은 정상 ZIP에서도 1000:1을 넘습니다.
        var visited = new byte[8 * 1024 * 1024];
        await File.WriteAllBytesAsync(Path.Combine(source, "map_visited.bin"), visited);
        var repositoryPath = temp.GetPath("repository");
        var options = new BackupOptions(
            BackupConfiguration.CurrentFormatVersion,
            repositoryPath,
            [new BackupSourceOptions("Sandbox/MySave", source)],
            new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, false),
            new TelemetryOptions(TelemetryMode.Off, 16, 10, 10, 32));
        var backup = await new OneShotBackupService(new NoJournal()).RunAsync(
            options, "Sandbox/MySave");
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var sourceRow = await repository.GetSourceAsync("Sandbox/MySave");
        var archivePath = temp.GetPath("save.pzsave.zip");
        var service = new ZomboidArchiveService();

        var progress = new List<ArchiveProgress>();
        await service.ExportAsync(repository, sourceRow.SourceId, backup.Revision!.Value, archivePath,
            (value, _) => { progress.Add(value); return Task.CompletedTask; });
        using (var zip = ZipFile.OpenRead(archivePath))
        {
            var entry = zip.GetEntry("Sandbox/MySave/map_visited.bin")!;
            Assert.True((double)entry.Length / entry.CompressedLength > 1000);
        }
        await Assert.ThrowsAsync<InvalidDataException>(() => service.InspectAsync(
            archivePath, safetyOptions: new ArchiveSafetyOptions(
                MaximumCompressionRatio: 1000,
                CompressionRatioMinimumBytes: 1024 * 1024)));
        var inspection = await service.InspectAsync(archivePath);
        var savesRoot = temp.GetPath("Saves");
        Directory.CreateDirectory(Path.Combine(savesRoot, "Sandbox", "MySave"));
        var imported = await service.ImportAsync(archivePath, savesRoot);
        var importedAgain = await service.ImportAsync(archivePath, savesRoot);
        var importedWithRelativeReserve = await service.ImportAsync(
            archivePath, savesRoot,
            safetyOptions: new ArchiveSafetyOptions(
                MinimumFreeSpaceReserveBytes: 0,
                MinimumFreeSpaceReservePercent: 100));

        Assert.Equal("Sandbox", inspection.Manifest.Mode);
        Assert.Equal("MySave", inspection.Manifest.SaveName);
        Assert.NotNull(inspection.Thumbnail);
        Assert.Equal("MySave(1)", imported.SaveName);
        Assert.Equal("MySave(2)", importedAgain.SaveName);
        Assert.Equal("MySave(3)", importedWithRelativeReserve.SaveName);
        Assert.Equal("player", await File.ReadAllTextAsync(
            Path.Combine(imported.DestinationPath, "players.db")));
        Assert.Equal(visited, await File.ReadAllBytesAsync(
            Path.Combine(imported.DestinationPath, "map_visited.bin")));
        // The revision goes from the repository straight into the archive, in one pass.
        Assert.Equal(["archive.compress", "archive.finalize"], progress.Select(item => item.Phase).Distinct());
        var events = progress.Where(item => item.Phase == "archive.compress").ToArray();
        Assert.Equal(0, events[0].CompletedItems);
        Assert.Equal(4, events[0].TotalItems);
        Assert.Equal(events[^1].TotalItems, events[^1].CompletedItems);
        Assert.Equal(events[^1].TotalBytes, events[^1].CompletedBytes);
        Assert.Equal(new long[] { 0, 1, 2, 3, 4 }, events.Select(item => item.CompletedItems).Distinct());
        Assert.Contains(events, item => item.RelativePath == "Sandbox/MySave/map_visited.bin"
            && item.CompletedBytes > 1024 * 1024 && item.CompletedBytes < visited.Length);
        Assert.Equal("archive.finalize", progress[^1].Phase);
        // Nothing is restored to disk on the way.
        Assert.False(Directory.Exists(Path.Combine(repositoryPath, ".pztools"))
            && Directory.EnumerateDirectories(Path.Combine(repositoryPath, ".pztools"), "archive-export-*").Any());
        Assert.Equal(inspection.Manifest.LastPlayedUtc!.Value.UtcDateTime,
            File.GetLastWriteTimeUtc(Path.Combine(source, "players.db")));
    }

    [Fact]
    public async Task DamagedObject_FailsExportAndRestore_WithoutLeavingPartialOutput()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        await File.WriteAllTextAsync(Path.Combine(source, "players.db"), "player");
        var map = new byte[256 * 1024];
        new Random(7).NextBytes(map);
        await File.WriteAllBytesAsync(Path.Combine(source, "map.bin"), map);
        var repositoryPath = temp.GetPath("repository");
        var options = new BackupOptions(
            BackupConfiguration.CurrentFormatVersion,
            repositoryPath,
            [new BackupSourceOptions("Sandbox/MySave", source)],
            new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false),
            new TelemetryOptions(TelemetryMode.Off, 16, 10, 10, 32));
        var backup = await new OneShotBackupService(new NoJournal()).RunAsync(options, "Sandbox/MySave");
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var sourceRow = await repository.GetSourceAsync("Sandbox/MySave");
        // Damage the stored map data in the middle of its pack.
        var pack = Assert.Single(Directory.GetFiles(Path.Combine(repositoryPath, "packs"), "*", SearchOption.AllDirectories));
        var bytes = await File.ReadAllBytesAsync(pack);
        var at = bytes.AsSpan().IndexOf(map.AsSpan(1000, 64));
        Assert.True(at > 0);
        bytes[at] ^= 0xFF;
        await File.WriteAllBytesAsync(pack, bytes);
        var archivePath = temp.GetPath("existing.zip");
        await File.WriteAllTextAsync(archivePath, "existing-output");

        await Assert.ThrowsAnyAsync<Exception>(() => new ZomboidArchiveService().ExportAsync(
            repository, sourceRow.SourceId, backup.Revision!.Value, archivePath));

        Assert.Equal("existing-output", await File.ReadAllTextAsync(archivePath));
        Assert.Empty(Directory.GetFiles(temp.Path, "*.tmp"));

        // The same damage stops a restore. A file that could not be written completely is not
        // left behind, and a save being replaced stays exactly as it was.
        var direct = temp.GetPath("direct");
        await Assert.ThrowsAnyAsync<Exception>(() => new RevisionRestorer().RestoreAsync(
            repository, sourceRow.SourceId, backup.Revision!.Value, direct));
        Assert.False(File.Exists(Path.Combine(direct, "map.bin")));
        var save = temp.GetPath("Saves", "Sandbox", "MySave");
        Directory.CreateDirectory(save);
        await File.WriteAllTextAsync(Path.Combine(save, "players.db"), "current");
        await Assert.ThrowsAnyAsync<Exception>(() => new SafeRevisionRestoreService().RestoreReplacingAsync(
            repository, sourceRow.SourceId, backup.Revision!.Value, save));
        Assert.Equal("current", await File.ReadAllTextAsync(Path.Combine(save, "players.db")));
        Assert.Equal(["players.db"], Directory.GetFileSystemEntries(save).Select(Path.GetFileName));
        Assert.Equal(["MySave"], Directory.GetFileSystemEntries(Path.GetDirectoryName(save)!).Select(Path.GetFileName));
    }

    [Fact]
    public async Task Import_AcceptsLegacyRootLayout()
    {
        using var temp = new TempDirectory();
        var archivePath = temp.GetPath("legacy.zip");
        var manifest = new ZomboidArchiveManifest(
            ZomboidArchiveService.FormatMarker, 1, "Sandbox/Legacy", "Sandbox", "Legacy",
            null, 0, 0, DateTimeOffset.UtcNow);
        await using (var stream = File.Create(archivePath))
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create))
        {
            await using (var player = zip.CreateEntry("players.db").Open())
                await player.WriteAsync("old-save"u8.ToArray());
            await using var manifestStream = zip.CreateEntry(ZomboidArchiveService.ManifestEntryName).Open();
            await JsonSerializer.SerializeAsync(manifestStream, manifest);
        }

        var service = new ZomboidArchiveService();
        var inspection = await service.InspectAsync(archivePath);
        var result = await service.ImportAsync(archivePath, temp.GetPath("Saves"));
        Assert.Equal(1, inspection.Manifest.Version);
        Assert.Equal("Sandbox", result.Mode);
        Assert.Equal("Legacy", result.SaveName);
        Assert.Equal("old-save", await File.ReadAllTextAsync(
            Path.Combine(result.DestinationPath, "players.db")));
        Assert.False(File.Exists(Path.Combine(result.DestinationPath,
            ZomboidArchiveService.ManifestEntryName)));
    }

    [Fact]
    public async Task Inspect_RejectsNewArchiveEntriesOutsideDeclaredSave()
    {
        using var temp = new TempDirectory();
        var archivePath = temp.GetPath("mixed.zip");
        var manifest = new ZomboidArchiveManifest(
            ZomboidArchiveService.FormatMarker, 2, "Sandbox/Save", "Sandbox", "Save",
            null, 0, 0, DateTimeOffset.UtcNow);
        await using (var stream = File.Create(archivePath))
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create))
        {
            await using (var player = zip.CreateEntry("Sandbox/Save/players.db").Open())
                await player.WriteAsync("player"u8.ToArray());
            await using (var manifestStream = zip.CreateEntry(
                             "Sandbox/Save/pztools-manifest.json").Open())
                await JsonSerializer.SerializeAsync(manifestStream, manifest);
            zip.CreateEntry("Other/Save/extra.bin");
        }

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            new ZomboidArchiveService().InspectAsync(archivePath));
    }

    [Fact]
    public async Task Inspect_RejectsTraversalBeforeExtraction()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("unsafe.zip");
        await using (var stream = File.Create(path))
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create))
        {
            archive.CreateEntry("../escape.txt");
        }

        await Assert.ThrowsAsync<InvalidDataException>(
            () => new ZomboidArchiveService().InspectAsync(path));
    }

    [Fact]
    public async Task Inspect_RejectsConfiguredEntryAndFileLimits()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("oversized.zip");
        await using (var stream = File.Create(path))
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create))
        {
            await using (var first = archive.CreateEntry("players.db").Open())
                await first.WriteAsync(new byte[] { 1, 2 });
            archive.CreateEntry("extra.bin");
        }

        var service = new ZomboidArchiveService();
        await Assert.ThrowsAsync<InvalidDataException>(() => service.InspectAsync(
            path,
            safetyOptions: new ArchiveSafetyOptions(MaximumEntries: 1)));
        await Assert.ThrowsAsync<InvalidDataException>(() => service.InspectAsync(
            path,
            safetyOptions: new ArchiveSafetyOptions(MaximumSingleFileBytes: 1)));
    }

    private sealed class NoJournal : PzTools.Backup.ChangeTracking.Windows.IUsnJournalSource
    {
        public PzTools.Backup.ChangeTracking.Windows.UsnJournalState Query(string sourcePath) =>
            new(1, 2, 0, 100, 0);
        public IEnumerable<PzTools.Backup.ChangeTracking.Windows.UsnRecord> ReadRange(
            string sourcePath,
            PzTools.Backup.ChangeTracking.Windows.UsnCheckpoint checkpoint,
            long upperUsnExclusive,
            CancellationToken cancellationToken = default) => [];
    }
}
