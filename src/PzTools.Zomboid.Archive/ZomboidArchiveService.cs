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
        var stagingRoot = Path.Combine(repository.RepositoryPath, ".pztools");
        Directory.CreateDirectory(stagingRoot);
        CleanupDirectories(stagingRoot, "archive-export-");
        var staging = Path.Combine(stagingRoot, $"archive-export-{Guid.NewGuid():N}");
        try
        {
            var source = await repository.GetSourceByIdAsync(sourceId, cancellationToken);
            async Task ReportRestoreAsync(RestoreProgress value, CancellationToken token)
            {
                if (progress is not null && value.Event is "workload.discovered" or "file.restore.progress" or "file.restore.completed")
                    await progress(new ArchiveProgress(
                        "archive.restore", value.CompletedItems, value.TotalItems,
                        value.CompletedBytes, value.TotalBytes, value.RelativePath), token);
            }
            await new RevisionRestorer().RestoreAsync(
                repository, sourceId, revision, staging, ReportRestoreAsync, cancellationToken);
            var (mode, saveName) = SplitSaveId(source.SourceKey);
            var playersPath = Path.Combine(staging, "players.db");
            var manifest = new ZomboidArchiveManifest(
                FormatMarker, CurrentVersion, source.SourceKey, mode, saveName,
                File.Exists(playersPath) ? File.GetLastWriteTimeUtc(playersPath) : null,
                sourceId, revision, DateTimeOffset.UtcNow);

            return await CompressDirectoryAsync(staging, output, manifest, progress, cancellationToken);
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
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
            File.GetLastWriteTimeUtc(Path.Combine(source, "players.db")), 0, 0, DateTimeOffset.UtcNow);
        ValidateManifest(manifest);
        var original = ReadSnapshot(source);
        if (!original.Any(item => item.RelativePath.Equals("players.db", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("Current save does not contain players.db.");
        void ValidateUnchanged()
        {
            if (!original.SequenceEqual(ReadSnapshot(source)))
                throw new IOException("The current save changed during export. Stop playing and try again.");
        }
        var staging = Path.Combine(Path.GetTempPath(), $"pztools-live-export-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        try
        {
            var files = original.Where(item => !item.IsDirectory).ToArray();
            var totalBytes = files.Sum(item => item.Length);
            long completed = 0, bytes = 0;
            if (progress is not null)
                await progress(new ArchiveProgress("archive.snapshot", 0, files.Length, 0, totalBytes, null), cancellationToken);
            foreach (var directory in original.Where(item => item.IsDirectory))
                Directory.CreateDirectory(Path.Combine(staging, directory.RelativePath));
            foreach (var file in files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var target = Path.Combine(staging, file.RelativePath);
                await using (var input = new FileStream(Path.Combine(source, file.RelativePath),
                    FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, FileOptions.Asynchronous))
                await using (var destination = new FileStream(target, FileMode.CreateNew,
                    FileAccess.Write, FileShare.None, 1024 * 1024, FileOptions.Asynchronous))
                    await CopyEntryBoundedAsync(input, destination, file.Length, cancellationToken,
                        progress is null ? null : (copied, token) => progress(new ArchiveProgress(
                            "archive.snapshot", completed, files.Length, bytes + copied,
                            totalBytes, file.RelativePath), token));
                File.SetLastWriteTimeUtc(target, file.LastWriteUtc);
                completed++;
                bytes += file.Length;
                if (progress is not null)
                    await progress(new ArchiveProgress("archive.snapshot", completed, files.Length,
                        bytes, totalBytes, file.RelativePath), cancellationToken);
            }
            ValidateUnchanged();
            return await CompressDirectoryAsync(staging, output, manifest, progress, cancellationToken, ValidateUnchanged);
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
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

    private static async Task<ArchiveExportResult> CompressDirectoryAsync(
        string staging, string output, ZomboidArchiveManifest manifest,
        Func<ArchiveProgress, CancellationToken, Task>? progress,
        CancellationToken cancellationToken, Action? validateBeforePublish = null)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        var temporary = output + $".{Guid.NewGuid():N}.tmp";
        try
        {

            var savePrefix = SavePrefix(manifest);
            var files = EnumerateExportFiles().Select(file => new FileInfo(file)).ToArray();
            long totalItems = files.LongLength;
            long totalBytes = files.Sum(file => file.Length);
            if (progress is not null)
                await progress(new ArchiveProgress(
                    "archive.compress", 0, totalItems, 0, totalBytes, null), cancellationToken);
            long completedItems = 0;
            long completedBytes = 0;
            await using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None,
                1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
            {
                archive.CreateEntry(manifest.Mode + "/", CompressionLevel.NoCompression);
                archive.CreateEntry(savePrefix, CompressionLevel.NoCompression);
                foreach (var directory in Directory.EnumerateDirectories(
                             staging, "*", SearchOption.AllDirectories))
                {
                    var relative = savePrefix + Path.GetRelativePath(staging, directory).Replace('\\', '/') + "/";
                    archive.CreateEntry(relative, CompressionLevel.NoCompression);
                }
                foreach (var file in files)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var relative = savePrefix + Path.GetRelativePath(staging, file.FullName).Replace('\\', '/');
                    var zipEntry = archive.CreateEntry(relative, CompressionLevel.Optimal);
                    await using var input = new FileStream(
                        file.FullName, FileMode.Open, FileAccess.Read, FileShare.Read,
                        1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
                    await using var destination = zipEntry.Open();
                    await CopyEntryBoundedAsync(input, destination, input.Length, cancellationToken,
                        progress is null ? null : (copied, token) => progress(new ArchiveProgress(
                            "archive.compress", completedItems, totalItems, completedBytes + copied,
                            totalBytes, relative), token));
                    completedItems++;
                    completedBytes += input.Length;
                    if (progress is not null)
                        await progress(new ArchiveProgress(
                            "archive.compress", completedItems, totalItems,
                            completedBytes, totalBytes, relative), cancellationToken);
                }
                if (progress is not null)
                    await progress(new ArchiveProgress(
                        "archive.finalize", 0, 0, 0, 0, null), cancellationToken);
                var manifestEntry = archive.CreateEntry(savePrefix + ManifestEntryName, CompressionLevel.Optimal);
                await using var manifestStream = manifestEntry.Open();
                await JsonSerializer.SerializeAsync(
                    manifestStream, manifest, JsonOptions, cancellationToken);
            }
            cancellationToken.ThrowIfCancellationRequested();
            validateBeforePublish?.Invoke();
            File.Move(temporary, output, overwrite: true);
            return new ArchiveExportResult(
                output, manifest.SourceId, manifest.Revision, checked((int)completedItems), new FileInfo(output).Length);

            IEnumerable<string> EnumerateExportFiles() =>
                Directory.EnumerateFiles(staging, "*", SearchOption.AllDirectories)
                    .Where(file => !StringComparer.OrdinalIgnoreCase.Equals(
                        Path.GetRelativePath(staging, file).Replace('\\', '/'),
                        ManifestEntryName));
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
                await using var input = entry.Open();
                await using var target = new FileStream(
                    output, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
                await CopyEntryBoundedAsync(input, target, entry.Length, cancellationToken,
                    progress is null ? null : (copied, token) => progress(new ArchiveProgress(
                        "import", files, fileEntries.LongLength, completedBytes + copied,
                        totalBytes, entry.FullName), token), expectedCrc32: entry.Crc32);
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
            if (!File.Exists(Path.Combine(stagedSave, "players.db")))
                throw new InvalidDataException("Archive does not contain players.db.");
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
                    $"Archive entry '{entry.FullName}' has an unsafe compression ratio.");
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
            // 헤더의 용량을 위조한 압축 데이터가 사전 검사한 한도를 넘어 기록되지 않게 합니다.
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
