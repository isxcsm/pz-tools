using PzTools.Backup.Core;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record RestoreResult(long SourceId, long Revision, int Files, int Directories);
public sealed record RestoreProgress(
    string Event,
    long CompletedItems,
    long TotalItems,
    long CompletedBytes,
    long TotalBytes,
    string? RelativePath = null,
    long Bytes = 0);

public sealed class RevisionRestorer
{
    public Task<RestoreResult> RestoreAsync(
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        string targetPath,
        CancellationToken cancellationToken = default) =>
        RestoreCoreAsync(repository, sourceId, revision, targetPath, null, cancellationToken);

    public Task<RestoreResult> RestoreAsync(
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        string targetPath,
        Func<RestoreProgress, CancellationToken, Task> observer,
        CancellationToken cancellationToken = default) =>
        RestoreCoreAsync(repository, sourceId, revision, targetPath, observer, cancellationToken);

    private async Task<RestoreResult> RestoreCoreAsync(
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        string targetPath,
        Func<RestoreProgress, CancellationToken, Task>? observer,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentException.ThrowIfNullOrWhiteSpace(targetPath);
        var root = ValidateEmptyTarget(targetPath);
        var entries = await repository.ReadRevisionEntriesAsync(
            sourceId,
            revision,
            cancellationToken);
        var planned = Preflight(root, entries);
        var files = planned.Where(item => item.Entry.EntryKind == "File").ToArray();
        var totalBytes = files.Sum(item => item.Entry.ByteLength);
        if (observer is not null)
            await observer(new RestoreProgress(
                "workload.discovered", 0, files.LongLength, 0, totalBytes), cancellationToken);
        long completedItems = 0;
        long completedBytes = 0;
        var readers = new Dictionary<Guid, PackReader>();
        Directory.CreateDirectory(root);
        try
        {

            foreach (var item in planned.Where(item => item.Entry.EntryKind == "Directory"))
            {
                cancellationToken.ThrowIfCancellationRequested();
                EnsureNoReparseAncestor(root, item.FullPath);
                Directory.CreateDirectory(item.FullPath);
            }

            foreach (var item in planned.Where(item => item.Entry.EntryKind == "File"))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (observer is not null)
                    await observer(new RestoreProgress(
                        "file.restore.started", completedItems, files.LongLength,
                        completedBytes, totalBytes, item.Entry.RelativePath), cancellationToken);
                if (item.Entry.ObjectId is null
                    || item.Entry.PackId is null
                    || item.Entry.PackRelativePath is null
                    || item.Entry.PackOffset is null)
                {
                    throw new InvalidDataException(
                        $"File '{item.Entry.RelativePath}' has no stored object.");
                }

                var parent = Path.GetDirectoryName(item.FullPath)!;
                Directory.CreateDirectory(parent);
                EnsureNoReparseAncestor(root, item.FullPath);
                if (!readers.TryGetValue(item.Entry.PackId.Value, out var reader))
                {
                    var packPath = ResolveRepositoryPath(
                        repository.RepositoryPath,
                        item.Entry.PackRelativePath);
                    reader = await PackReader.OpenForLocatedReadsAsync(
                        packPath,
                        item.Entry.PackId.Value,
                        cancellationToken);

                    readers.Add(reader.PackId, reader);
                }

                var temporary = Path.Combine(parent, $".pztools-restore-{Guid.NewGuid():N}.tmp");
                try
                {
                    await using (var destination = new FileStream(
                        temporary,
                        FileMode.CreateNew,
                        FileAccess.Write,
                        FileShare.None,
                        1,
                        FileOptions.Asynchronous | FileOptions.SequentialScan))
                    {
                        await reader.CopyObjectAtAsync(
                            item.Entry.ObjectId.Value,
                            item.Entry.PackOffset.Value,
                            destination,
                            cancellationToken,
                            observer is null ? null : (bytes, token) => observer(new RestoreProgress(
                                "file.restore.progress", completedItems, files.LongLength,
                                completedBytes + bytes, totalBytes, item.Entry.RelativePath), token));
                        await destination.FlushAsync(cancellationToken);
                        destination.Flush(flushToDisk: true);
                    }

                    File.Move(temporary, item.FullPath, overwrite: false);
                    ApplyMetadata(item.FullPath, item.Entry);
                    completedItems++;
                    completedBytes += item.Entry.ByteLength;
                    if (observer is not null)
                        await observer(new RestoreProgress(
                            "file.restore.completed", completedItems, files.LongLength,
                            completedBytes, totalBytes, item.Entry.RelativePath,
                            item.Entry.ByteLength), cancellationToken);
                }
                finally
                {
                    if (File.Exists(temporary))
                    {
                        File.Delete(temporary);
                    }
                }
            }

            foreach (var item in planned
                         .Where(item => item.Entry.EntryKind == "Directory")
                         .OrderByDescending(item => item.Entry.RelativePath.Count(character => character == '/')))
            {
                ApplyMetadata(item.FullPath, item.Entry);
            }

            return new RestoreResult(
                sourceId,
                revision,
                planned.Count(item => item.Entry.EntryKind == "File"),
                planned.Count(item => item.Entry.EntryKind == "Directory"));
        }
        finally
        {
            foreach (var reader in readers.Values)
            {
                await reader.DisposeAsync();
            }
        }
    }

    private static string ValidateEmptyTarget(string targetPath)
    {
        var root = Path.GetFullPath(targetPath);
        if (File.Exists(root))
        {
            throw new IOException($"Restore target '{root}' is a file.");
        }

        if (Directory.Exists(root))
        {
            if ((File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException($"Restore target '{root}' is a reparse point.");
            }

            if (Directory.EnumerateFileSystemEntries(root).Any())
            {
                throw new IOException($"Restore target '{root}' is not empty.");
            }
        }
        return Path.TrimEndingDirectorySeparator(root);
    }

    private static IReadOnlyList<PlannedEntry> Preflight(
        string root,
        IReadOnlyList<RevisionEntry> entries)
    {
        var planned = new List<PlannedEntry>(entries.Count);
        var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var rootPrefix = root + Path.DirectorySeparatorChar;
        foreach (var entry in entries)
        {
            var normalized = BackupPath.NormalizeRelative(entry.RelativePath);
            if (!keys.Add(normalized))
            {
                throw new InvalidDataException($"Duplicate restore path '{normalized}'.");
            }

            if (entry.EntryKind is not ("File" or "Directory"))
            {
                throw new InvalidDataException(
                    $"Unsupported entry kind '{entry.EntryKind}' for '{normalized}'.");
            }

            var fullPath = Path.GetFullPath(Path.Combine(
                root,
                normalized.Replace('/', Path.DirectorySeparatorChar)));
            if (!fullPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException($"Restore path '{normalized}' escapes the target.");
            }

            planned.Add(new PlannedEntry(entry with { RelativePath = normalized }, fullPath));
        }

        var kinds = planned.ToDictionary(
            item => item.Entry.RelativePath,
            item => item.Entry.EntryKind,
            StringComparer.OrdinalIgnoreCase);
        foreach (var item in planned)
        {
            var path = item.Entry.RelativePath;
            var separator = path.IndexOf('/');
            while (separator >= 0)
            {
                var ancestor = path[..separator];
                if (kinds.TryGetValue(ancestor, out var kind) && kind == "File")
                {
                    throw new InvalidDataException(
                        $"Restore path '{path}' is nested under file '{ancestor}'.");
                }

                separator = path.IndexOf('/', separator + 1);
            }
        }

        return planned;
    }

    private static string ResolveRepositoryPath(string repositoryPath, string relativePath)
    {
        var normalized = BackupPath.NormalizeRelative(relativePath);
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(repositoryPath));
        var resolved = Path.GetFullPath(Path.Combine(
            root,
            normalized.Replace('/', Path.DirectorySeparatorChar)));
        if (!resolved.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"Repository path '{relativePath}' escapes its root.");
        }

        return resolved;
    }

    private static void EnsureNoReparseAncestor(string root, string path)
    {
        var current = Path.GetDirectoryName(path);
        while (current is not null
               && current.Length >= root.Length
               && current.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            if (Directory.Exists(current)
                && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException($"Restore path ancestor '{current}' is a reparse point.");
            }

            if (StringComparer.OrdinalIgnoreCase.Equals(current, root))
            {
                break;
            }

            current = Path.GetDirectoryName(current);
        }
    }

    private static void ApplyMetadata(string path, RevisionEntry entry)
    {
        if (entry.EntryKind == "Directory")
        {
            Directory.SetLastWriteTimeUtc(path, entry.ModifiedUtc.UtcDateTime);
        }
        else
        {
            File.SetLastWriteTimeUtc(path, entry.ModifiedUtc.UtcDateTime);
        }

        var restorableAttributes = entry.Attributes
            & ~(FileAttributes.ReparsePoint | FileAttributes.Device | FileAttributes.Offline);
        File.SetAttributes(path, restorableAttributes);
    }

    private sealed record PlannedEntry(RevisionEntry Entry, string FullPath);
}
