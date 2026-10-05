using System.IO.Compression;
using System.IO.Hashing;
using System.Text.Json;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Zomboid.State;

namespace PzTools.Zomboid.Archive;

public sealed class ZomboidArchiveService(long maximumPreviewPlayersDatabaseBytes = 64L * 1024 * 1024,
    long maximumPreviewThumbnailBytes = 16L * 1024 * 1024)
{
    public const string ManifestEntryName = "pztools-manifest.json";
    public const string FormatMarker = "pztools-zomboid-save";
    public const int CurrentVersion = 2;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    public async Task<ArchiveInspection> InspectAsync(
        string archivePath,
        CancellationToken cancellationToken = default,
        ArchiveSafetyOptions? safetyOptions = null)
    {
        var fullPath = Path.GetFullPath(archivePath);
        await using var stream = new FileStream(
            fullPath, FileMode.Open, FileAccess.Read, FileShare.Read,
            64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: false);
        var entries = ValidateEntries(archive, safetyOptions ?? new ArchiveSafetyOptions());
        var entry = archive.GetEntry(ManifestEntryName);
        if (entry is null)
        {
            var nested = entries.Where(item => item.FullName.Replace('\\', '/')
                .EndsWith("/" + ManifestEntryName, StringComparison.OrdinalIgnoreCase)).ToArray();
            if (nested.Length != 1)
                throw new InvalidDataException("PzTools archive manifest is missing or ambiguous.");
            entry = nested[0];
        }
        var manifest = await ReadManifestAsync(entry, cancellationToken);
        ValidateLayout(entries, manifest, entry);

        byte[]? thumbnail = null;
        var savePrefix = manifest.Version == 1 ? "" : SavePrefix(manifest);
        var thumbEntry = archive.GetEntry(savePrefix + "thumb.png");
        if (thumbEntry is not null && thumbEntry.Length > 0 && thumbEntry.Length <= maximumPreviewThumbnailBytes)
        {
            await using var thumb = thumbEntry.Open();
            thumbnail = new byte[checked((int)thumbEntry.Length)];
            await thumb.ReadExactlyAsync(thumbnail, cancellationToken);
            if (!IsPng(thumbnail)) thumbnail = null;
        }
        var playersEntry = entries.FirstOrDefault(item => item.FullName.Equals(
            savePrefix + "players.db", StringComparison.OrdinalIgnoreCase));
        var character = await ReadPreviewCharacterAsync(playersEntry, cancellationToken);
        return new ArchiveInspection(manifest, thumbnail, new FileInfo(fullPath).Length,
            character?.Name, character?.HoursSurvived);
    }

    private static async Task<ZomboidArchiveManifest> ReadManifestAsync(
        ZipArchiveEntry entry, CancellationToken cancellationToken)
    {
        if (entry.Length is <= 0 or > 1024 * 1024)
            throw new InvalidDataException("PzTools archive manifest has an invalid size.");
        await using var input = entry.Open();
        using var content = new MemoryStream(checked((int)entry.Length));
        await CopyEntryBoundedAsync(input, content, entry.Length, cancellationToken,
            expectedCrc32: entry.Crc32);
        content.Position = 0;
        var manifest = await JsonSerializer.DeserializeAsync<ZomboidArchiveManifest>(
            content, JsonOptions, cancellationToken);
        ValidateManifest(manifest);
        return manifest!;
    }

    private async Task<CharacterSnapshot?> ReadPreviewCharacterAsync(
        ZipArchiveEntry? entry, CancellationToken cancellationToken)
    {
        if (entry is null || entry.Length <= 0 || entry.Length > maximumPreviewPlayersDatabaseBytes)
            return null;
        var tempPath = Path.Combine(Path.GetTempPath(), $"pztools-archive-preview-{Guid.NewGuid():N}.db");
        try
        {
            await using (var source = entry.Open())
            await using (var target = new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write,
                             FileShare.None, 64 * 1024, FileOptions.Asynchronous))
            {
                var buffer = new byte[64 * 1024];
                long copied = 0;
                int read;
                while ((read = await source.ReadAsync(buffer, cancellationToken)) != 0)
                {
                    copied += read;
                    if (copied > maximumPreviewPlayersDatabaseBytes) return null;
                    await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                }
            }
            return await new CharacterNameReader().ReadSnapshotAsync(tempPath, cancellationToken);
        }
        finally
        {
            if (File.Exists(tempPath)) File.Delete(tempPath);
        }
    }

    public async Task<ArchiveExportResult> ExportAsync(
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        string outputPath,
        Func<ArchiveProgress, CancellationToken, Task>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var output = Path.GetFullPath(outputPath);
        var parent = Path.GetDirectoryName(output)
            ?? throw new ArgumentException("Archive output must have a parent.", nameof(outputPath));
        Directory.CreateDirectory(parent);
        // Earlier versions restored the revision into a folder here first; remove what an
        // interrupted export of theirs left behind.
        var stagingRoot = Path.Combine(repository.RepositoryPath, ".pztools");
        if (Directory.Exists(stagingRoot)) CleanupDirectories(stagingRoot, "archive-export-");

        var source = await repository.GetSourceByIdAsync(sourceId, cancellationToken);
        var (mode, saveName) = SplitSaveId(source.SourceKey);
        var savePrefix = $"{mode}/{saveName}/";
        DateTime? playersModified = null;
        // The revision is read from the repository straight into the archive. Restoring it to a
        // folder first would write, flush and read back every one of the save's many small files.
        return await WriteArchiveAsync(output, mode, savePrefix, async (archive, token) =>
            {
                async Task ReportAsync(RestoreProgress value, CancellationToken reportToken)
                {
                    if (progress is not null && value.Event is "workload.discovered" or "file.restore.progress" or "file.restore.completed")
                        await progress(new ArchiveProgress(
                            "archive.compress", value.CompletedItems, value.TotalItems,
                            value.CompletedBytes, value.TotalBytes,
                            value.RelativePath is null ? null : savePrefix + value.RelativePath), reportToken);
                }
                var restored = await new RevisionRestorer().ReadAsync(repository, sourceId, revision,
                    (directory, _) =>
                    {
                        if (!IsRootManifest(directory.RelativePath))
                            archive.CreateEntry(savePrefix + directory.RelativePath + "/", CompressionLevel.NoCompression);
                        return Task.CompletedTask;
                    },
                    (file, _) =>
                    {
                        if (StringComparer.OrdinalIgnoreCase.Equals(file.RelativePath, "players.db"))
                            playersModified = file.ModifiedUtc.UtcDateTime;
                        // The archive's own manifest takes that name; a stored file with it is left out.
                        if (IsRootManifest(file.RelativePath)) return Task.FromResult(Stream.Null);
                        var zipEntry = archive.CreateEntry(savePrefix + file.RelativePath, CompressionLevel.Optimal);
                        Stamp(zipEntry, file.ModifiedUtc.UtcDateTime);
                        return Task.FromResult(zipEntry.Open());
                    },
                    ReportAsync, token);
                return restored.Files;
            },
            () => new ZomboidArchiveManifest(
                FormatMarker, CurrentVersion, source.SourceKey, mode, saveName,
                playersModified, sourceId, revision, DateTimeOffset.UtcNow, TimeZoneInfo.Local.Id),
            progress, cancellationToken);
    }

    public async Task<ArchiveExportResult> ExportLiveAsync(
        string sourcePath, string saveId, string outputPath,
        Func<ArchiveProgress, CancellationToken, Task>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var source = Path.TrimEndingDirectorySeparator(Path.GetFullPath(sourcePath));
        var output = Path.GetFullPath(outputPath);
        if (output.Equals(source, StringComparison.OrdinalIgnoreCase)
            || output.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Archive output must be outside the current save directory.");
        var (mode, name) = SplitSaveId(saveId);
        var manifest = new ZomboidArchiveManifest(FormatMarker, CurrentVersion, saveId, mode, name,
            File.GetLastWriteTimeUtc(Path.Combine(source, "players.db")), 0, 0, DateTimeOffset.UtcNow, TimeZoneInfo.Local.Id);
        ValidateManifest(manifest);
        var original = ReadSnapshot(source);
        if (!original.Any(item => item.RelativePath.Equals("players.db", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("Current save does not contain players.db.");
        void ValidateUnchanged()
        {
            if (!original.SequenceEqual(ReadSnapshot(source)))
                throw new IOException("export-save-changed: The current save changed during export. Stop playing and try again.");
        }
        // The save is compressed straight into the archive. A private copy first would write every
        // one of its many small files twice, and would add nothing: the save is compared with the
        // listing taken above once the archive is complete, and any change discards the archive.
        var savePrefix = SavePrefix(manifest);
        var entries = original.Where(item => !IsRootManifest(item.RelativePath)).ToArray();
        var files = entries.Where(entry => !entry.IsDirectory).ToArray();
        long totalItems = files.LongLength;
        long totalBytes = files.Sum(file => file.Length);
        async Task<int> WriteContentAsync(ZipArchive archive, CancellationToken token)
        {
            if (progress is not null)
                await progress(new ArchiveProgress("archive.compress", 0, totalItems, 0, totalBytes, null), token);
            foreach (var directory in entries.Where(entry => entry.IsDirectory))
                archive.CreateEntry(savePrefix + directory.RelativePath.Replace('\\', '/') + "/", CompressionLevel.NoCompression);
            long completedItems = 0;
            long completedBytes = 0;
            foreach (var file in files)
            {
                token.ThrowIfCancellationRequested();
                var relative = savePrefix + file.RelativePath.Replace('\\', '/');
                var zipEntry = archive.CreateEntry(relative, CompressionLevel.Optimal);
                Stamp(zipEntry, file.LastWriteUtc);
                // No FileStream buffer: the copy reads in large blocks itself, and a buffer per
                // file would be allocated for each of a save's many small files.
                await using var input = new FileStream(
                    Path.Combine(source, file.RelativePath), FileMode.Open, FileAccess.Read, FileShare.Read,
                    0, FileOptions.SequentialScan);
                await using var destination = zipEntry.Open();
                await CopyEntryBoundedAsync(input, destination, file.Length, token,
                    progress is null ? null : (copied, reportToken) => progress(new ArchiveProgress(
                        "archive.compress", completedItems, totalItems, completedBytes + copied,
                        totalBytes, relative), reportToken));
                completedItems++;
                completedBytes += file.Length;
                if (progress is not null)
                    await progress(new ArchiveProgress(
                        "archive.compress", completedItems, totalItems, completedBytes, totalBytes, relative), token);
            }
            return files.Length;
        }
        try
        {
            return await WriteArchiveAsync(output, manifest.Mode, savePrefix, WriteContentAsync,
                () => manifest, progress, cancellationToken, ValidateUnchanged);
        }
        catch (InvalidDataException exception) when (exception.Message.StartsWith("Archive entry ", StringComparison.Ordinal))
        {
            // A file that grew or shrank after it was listed.
            throw new IOException("export-save-changed: The current save changed during export. Stop playing and try again.", exception);
        }
    }


    private static bool IsRootManifest(string relativePath) =>
        StringComparer.OrdinalIgnoreCase.Equals(relativePath.Replace('\\', '/'), ManifestEntryName);

    // A save's file times say when it was last played; kept through export and import, they are not the
    // time it was unpacked. A zip holds local dates from 1980 to 2107 only, and stores the clock time it is
    // given whatever its offset: given local time, whose zone the manifest names for an import on another PC.
    // A date outside keeps the time of writing.
    private static void Stamp(ZipArchiveEntry entry, DateTime modifiedUtc)
    {
        if (modifiedUtc.Year is >= 1981 and <= 2106)
            entry.LastWriteTime = new DateTimeOffset(modifiedUtc, TimeSpan.Zero).ToLocalTime();
    }

    // The zone an archive's entry times were written in: the exporting PC's, which another PC may not share. An
    // archive without one, or with a zone this PC does not know, is read in this PC's own.
    private static TimeZoneInfo ExportZone(string? id)
    {
        if (string.IsNullOrEmpty(id)) return TimeZoneInfo.Local;
        try { return TimeZoneInfo.FindSystemTimeZoneById(id); }
        catch (Exception error) when (error is TimeZoneNotFoundException or InvalidTimeZoneException) { return TimeZoneInfo.Local; }
    }

    /// <summary>An entry's clock time, as written in <paramref name="zone"/>, as UTC; each date with its own daylight saving.</summary>
    internal static DateTime EntryTimeUtc(DateTime clock, TimeZoneInfo zone)
    {
        var local = DateTime.SpecifyKind(clock, DateTimeKind.Unspecified);
        // A time the clocks skipped never came from a file; it is read an hour on, as the clock then showed.
        if (zone.IsInvalidTime(local)) local = local.AddHours(1);
        return TimeZoneInfo.ConvertTimeToUtc(local, zone);
    }

    private sealed record SnapshotEntry(string RelativePath, bool IsDirectory, long Length, DateTime LastWriteUtc);

    private static SnapshotEntry[] ReadSnapshot(string root)
    {
        var entries = new List<SnapshotEntry>();
        void Visit(string directory)
        {
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Current save must not contain reparse points.");
            foreach (var path in Directory.EnumerateFileSystemEntries(directory))
            {
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Current save must not contain reparse points.");
                var isDirectory = (attributes & FileAttributes.Directory) != 0;
                entries.Add(new SnapshotEntry(Path.GetRelativePath(root, path), isDirectory,
                    isDirectory ? 0 : new FileInfo(path).Length, File.GetLastWriteTimeUtc(path)));
                if (isDirectory) Visit(path);
            }
        }
        Visit(root);
        return entries.OrderBy(item => item.RelativePath, StringComparer.Ordinal).ToArray();
    }

    /// <summary>
    /// Writes an archive to a temporary file next to the output: the mode and save folders,
    /// the content, then the manifest. The output is replaced only when all of it succeeded.
    /// </summary>
    private static async Task<ArchiveExportResult> WriteArchiveAsync(
        string output, string mode, string savePrefix,
        Func<ZipArchive, CancellationToken, Task<int>> writeContent,
        Func<ZomboidArchiveManifest> manifest,
        Func<ArchiveProgress, CancellationToken, Task>? progress,
        CancellationToken cancellationToken, Action? validateBeforePublish = null)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        var temporary = output + $".{Guid.NewGuid():N}.tmp";
        try
        {
            int files;
            ZomboidArchiveManifest written;
            await using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None,
                1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
            {
                archive.CreateEntry(mode + "/", CompressionLevel.NoCompression);
                archive.CreateEntry(savePrefix, CompressionLevel.NoCompression);
                files = await writeContent(archive, cancellationToken);
                if (progress is not null)
                    await progress(new ArchiveProgress(
                        "archive.finalize", 0, 0, 0, 0, null), cancellationToken);
                written = manifest();
                var manifestEntry = archive.CreateEntry(savePrefix + ManifestEntryName, CompressionLevel.Optimal);
                await using var manifestStream = manifestEntry.Open();
                await JsonSerializer.SerializeAsync(
                    manifestStream, written, JsonOptions, cancellationToken);
            }
            cancellationToken.ThrowIfCancellationRequested();
            validateBeforePublish?.Invoke();
            File.Move(temporary, output, overwrite: true);
            return new ArchiveExportResult(
                output, written.SourceId, written.Revision, files, new FileInfo(output).Length);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public async Task<ArchiveImportResult> ImportAsync(
        string archivePath,
        string savesRoot,
        Func<ArchiveProgress, CancellationToken, Task>? progress = null,
        CancellationToken cancellationToken = default,
        ArchiveSafetyOptions? safetyOptions = null)
    {
        var safety = safetyOptions ?? new ArchiveSafetyOptions();
        safety.Validate();
        var inspection = await InspectAsync(archivePath, cancellationToken, safety);
        var root = Path.GetFullPath(savesRoot);
        Directory.CreateDirectory(root);
        CleanupDirectories(root, ".pztools-import-");
        var modeDirectory = SafeChild(root, inspection.Manifest.Mode);
        if (Directory.Exists(modeDirectory)
            && (File.GetAttributes(modeDirectory) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("The archive mode directory is a reparse point.");
        Directory.CreateDirectory(modeDirectory);
        var finalName = ChooseAvailableName(modeDirectory, inspection.Manifest.SaveName);
        var destination = SafeChild(modeDirectory, finalName);
        var staging = Path.Combine(root, $".pztools-import-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        try
        {
            await using var stream = new FileStream(
                Path.GetFullPath(archivePath), FileMode.Open, FileAccess.Read, FileShare.Read,
                1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var archive = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: false);
            var entries = ValidateEntries(archive, safety);
            var manifestPath = inspection.Manifest.Version == 1
                ? ManifestEntryName : SavePrefix(inspection.Manifest) + ManifestEntryName;
            var manifestEntry = archive.GetEntry(manifestPath)
                ?? throw new InvalidDataException("PzTools archive manifest is missing.");
            if (await ReadManifestAsync(manifestEntry, cancellationToken) != inspection.Manifest)
                throw new InvalidDataException("Archive manifest changed after inspection.");
            ValidateLayout(entries, inspection.Manifest, manifestEntry);
            var fileEntries = entries.Where(item =>
                    !item.FullName.EndsWith('/')
                    && !StringComparer.OrdinalIgnoreCase.Equals(item.FullName, manifestPath))
                .ToArray();
            var totalBytes = fileEntries.Sum(item => item.Length);
            var exportZone = ExportZone(inspection.Manifest.EntryTimeZone);
            EnsureImportSpace(root, totalBytes, safety);
            if (progress is not null)
                await progress(new ArchiveProgress(
                    "import", 0, fileEntries.LongLength, 0, totalBytes, null), cancellationToken);
            var files = 0;
            long completedBytes = 0;
            foreach (var entry in entries.Where(item =>
                         !StringComparer.OrdinalIgnoreCase.Equals(item.FullName, manifestPath)))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var output = SafeChild(staging, entry.FullName.Replace('/', Path.DirectorySeparatorChar));
                if (entry.FullName.EndsWith('/'))
                {
                    Directory.CreateDirectory(output);
                    continue;
                }
                Directory.CreateDirectory(Path.GetDirectoryName(output)!);
                await using (var input = entry.Open())
                await using (var target = new FileStream(
                    output, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
                {
                    await CopyEntryBoundedAsync(input, target, entry.Length, cancellationToken,
                        progress is null ? null : (copied, token) => progress(new ArchiveProgress(
                            "import", files, fileEntries.LongLength, completedBytes + copied,
                            totalBytes, entry.FullName), token), expectedCrc32: entry.Crc32);
                }
                // The time the file was last written in the save, not the time it was unpacked.
                File.SetLastWriteTimeUtc(output, EntryTimeUtc(entry.LastWriteTime.DateTime, exportZone));
                files++;
                completedBytes += entry.Length;
                if (progress is not null)
                    await progress(new ArchiveProgress(
                        "import", files, fileEntries.LongLength, completedBytes,
                        totalBytes, entry.FullName), cancellationToken);
            }
            var stagedSave = inspection.Manifest.Version == 1 ? staging :
                SafeChild(staging, SavePrefix(inspection.Manifest)
                    .Replace('/', Path.DirectorySeparatorChar)
                    .TrimEnd(Path.DirectorySeparatorChar));
            var players = Path.Combine(stagedSave, "players.db");
            if (!File.Exists(players))
                throw new InvalidDataException("Archive does not contain players.db.");
            // The manifest keeps the exact time of the last play, also for archives whose entries carry the
            // time they were written instead.
            if (inspection.Manifest.LastPlayedUtc is { } played)
                File.SetLastWriteTimeUtc(players, played.UtcDateTime);
            Directory.Move(stagedSave, destination);
            return new ArchiveImportResult(destination, inspection.Manifest.Mode, finalName, files);
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    private static IReadOnlyList<ZipArchiveEntry> ValidateEntries(
        ZipArchive archive,
        ArchiveSafetyOptions safety)
    {
        safety.Validate();
        if (archive.Entries.Count > safety.MaximumEntries)
            throw new InvalidDataException(
                $"Archive contains too many entries ({archive.Entries.Count:N0}).");
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries)
        {
            var normalized = entry.FullName.Replace('\\', '/');
            if (string.IsNullOrWhiteSpace(normalized)
                || normalized.StartsWith('/')
                || normalized.Contains(':')
                || normalized.Split('/').Any(segment => segment is ".." or ".")
                || !names.Add(normalized))
                throw new InvalidDataException($"Unsafe or duplicate archive path '{entry.FullName}'.");
            var unixMode = (entry.ExternalAttributes >> 16) & 0xF000;
            if (unixMode == 0xA000)
                throw new InvalidDataException($"Archive link '{entry.FullName}' is not allowed.");
            if (entry.Length > safety.MaximumSingleFileBytes)
                throw new InvalidDataException($"Archive entry '{entry.FullName}' is too large.");
            if (entry.Length >= safety.CompressionRatioMinimumBytes
                && (entry.CompressedLength == 0
                    || (double)entry.Length / Math.Max(1, entry.CompressedLength)
                    > safety.MaximumCompressionRatio))
                throw new InvalidDataException(
                    $"archive-unsafe-ratio: Archive entry '{entry.FullName}' has an unsafe compression ratio.");
        }
        return archive.Entries;
    }

    private static async Task CopyEntryBoundedAsync(
        Stream input, Stream target, long expectedBytes, CancellationToken cancellationToken,
        Func<long, CancellationToken, Task>? progress = null, uint? expectedCrc32 = null)
    {
        var checksum = expectedCrc32.HasValue ? new Crc32() : null;
        var buffer = System.Buffers.ArrayPool<byte>.Shared.Rent(1024 * 1024);
        try
        {
            var remaining = expectedBytes;
            while (remaining > 0)
            {
                var read = await input.ReadAsync(
                    buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), cancellationToken);
                if (read == 0) throw new InvalidDataException("Archive entry is shorter than its declared length.");
                checksum?.Append(buffer.AsSpan(0, read));
                await target.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                remaining -= read;
                if (progress is not null) await progress(expectedBytes - remaining, cancellationToken);
            }
            // Compressed data that lies about its size in the header cannot write past the limit checked up front.
            if (await input.ReadAsync(buffer.AsMemory(0, 1), cancellationToken) != 0)
                throw new InvalidDataException("Archive entry exceeds its declared length.");
            if (checksum is not null && checksum.GetCurrentHashAsUInt32() != expectedCrc32!.Value)
                throw new InvalidDataException("Archive entry failed CRC-32 verification.");
        }
        finally
        {
            System.Buffers.ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private static void EnsureImportSpace(
        string destinationRoot,
        long requiredBytes,
        ArchiveSafetyOptions safety)
    {
        var root = Path.GetPathRoot(Path.GetFullPath(destinationRoot))
            ?? throw new InvalidOperationException("Cannot determine the destination drive.");
        var drive = new DriveInfo(root);
        var percentReserve = checked(
            requiredBytes / 100 * safety.MinimumFreeSpaceReservePercent
            + requiredBytes % 100 * safety.MinimumFreeSpaceReservePercent / 100);
        var reserve = Math.Max(safety.MinimumFreeSpaceReserveBytes, percentReserve);
        if (requiredBytes > drive.AvailableFreeSpace - reserve)
            throw new IOException(
                $"Archive import needs {requiredBytes:N0} bytes while preserving "
                + $"{reserve:N0} bytes of free space.");
    }

    private static void ValidateManifest(ZomboidArchiveManifest? manifest)
    {
        if (manifest is null
            || manifest.Format != FormatMarker
            || manifest.Version is not (1 or CurrentVersion)
            || string.IsNullOrWhiteSpace(manifest.Mode)
            || string.IsNullOrWhiteSpace(manifest.SaveName)
            || manifest.Mode.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
            || manifest.SaveName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
            || manifest.Mode is "." or ".."
            || manifest.SaveName is "." or "..")
            throw new InvalidDataException("Unsupported or invalid PzTools Zomboid archive manifest.");
    }

    private static string SavePrefix(ZomboidArchiveManifest manifest) =>
        $"{manifest.Mode}/{manifest.SaveName}/";

    private static void ValidateLayout(
        IReadOnlyList<ZipArchiveEntry> entries,
        ZomboidArchiveManifest manifest,
        ZipArchiveEntry manifestEntry)
    {
        var prefix = manifest.Version == 1 ? "" : SavePrefix(manifest);
        var expectedManifest = prefix + ManifestEntryName;
        if (!manifestEntry.FullName.Equals(expectedManifest, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Archive manifest path does not match its save identity.");
        if (!entries.Any(item => item.FullName.Equals(prefix + "players.db", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("Archive does not contain players.db.");
        if (manifest.Version == 1) return;
        foreach (var entry in entries)
        {
            var path = entry.FullName.Replace('\\', '/');
            if (path.Equals(manifest.Mode + "/", StringComparison.OrdinalIgnoreCase)
                || path.Equals(prefix, StringComparison.OrdinalIgnoreCase)
                || path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                continue;
            throw new InvalidDataException($"Archive entry '{entry.FullName}' is outside the save directory.");
        }
    }

    private static string SafeChild(string root, string relative)
    {
        var fullRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var result = Path.GetFullPath(Path.Combine(fullRoot, relative));
        if (!result.StartsWith(fullRoot + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException($"Path '{relative}' escapes its root.");
        return result;
    }

    private static string ChooseAvailableName(string parent, string requested)
    {
        var existing = Directory.EnumerateFileSystemEntries(parent)
            .Select(Path.GetFileName)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!existing.Contains(requested)) return requested;
        for (var suffix = 1; ; suffix++)
        {
            var candidate = $"{requested}({suffix})";
            if (!existing.Contains(candidate)) return candidate;
        }
    }

    private static (string Mode, string SaveName) SplitSaveId(string saveId)
    {
        var normalized = saveId.Replace('\\', '/').Trim('/');
        var separator = normalized.IndexOf('/');
        return separator <= 0 || separator == normalized.Length - 1
            ? ("Unknown", normalized)
            : (normalized[..separator], normalized[(separator + 1)..]);
    }

    private static bool IsPng(byte[] value) => value.Length >= 8
        && value.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });

    private static void CleanupDirectories(string parent, string prefix)
    {
        foreach (var path in Directory.EnumerateDirectories(
                     parent, prefix + "*", SearchOption.TopDirectoryOnly))
        {
            var full = Path.GetFullPath(path);
            if (Path.GetDirectoryName(full)?.Equals(
                    Path.GetFullPath(parent), StringComparison.OrdinalIgnoreCase) == true
                && Path.GetFileName(full).StartsWith(prefix, StringComparison.Ordinal))
                Directory.Delete(full, recursive: true);
        }
    }
}
