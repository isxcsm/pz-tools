using System.Threading.Channels;
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
/// <summary>One folder or file of a revision, by its normalized relative path.</summary>
public sealed record RevisionItem(string RelativePath, long ByteLength, DateTimeOffset ModifiedUtc);

public sealed class RevisionRestorer
{
    private readonly Func<string, Guid, CancellationToken, Task<PackReader>> openPackReader;

    public RevisionRestorer() : this(PackReader.OpenForLocatedReadsAsync) { }

    internal RevisionRestorer(Func<string, Guid, CancellationToken, Task<PackReader>> openPackReader) =>
        this.openPackReader = openPackReader ?? throw new ArgumentNullException(nameof(openPackReader));

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
        PackReader? reader = null;
        Directory.CreateDirectory(root);
        // Every file reaches the disk before the restore reports success, so the save that is put
        // in place afterwards is complete even after a power cut. Finished files are flushed by a
        // few background workers while later ones are still being written, instead of one flush
        // at a time inside the write loop.
        await using var flush = new BackgroundFlush(cancellationToken);
        var preparedParents = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var item in planned.Where(item => item.Entry.EntryKind == "Directory"))
            {
                cancellationToken.ThrowIfCancellationRequested();
                EnsureNoReparseAncestor(root, item.FullPath);
                Directory.CreateDirectory(item.FullPath);
            }

            foreach (var item in files.OrderBy(item => item.Entry.PackId).ThenBy(item => item.Entry.PackOffset))
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
                // Each folder is created and checked once, not again for every file in it.
                if (preparedParents.Add(parent))
                {
                    Directory.CreateDirectory(parent);
                    EnsureNoReparseAncestor(root, item.FullPath);
                }
                if (reader is null || reader.PackId != item.Entry.PackId.Value)
                {
                    if (reader is not null) await reader.DisposeAsync();
                    reader = null;
                    var packPath = ResolveRepositoryPath(
                        repository.RepositoryPath,
                        item.Entry.PackRelativePath);
                    reader = await openPackReader(
                        packPath,
                        item.Entry.PackId.Value,
                        cancellationToken);

                }

                // Written under its final name. The target is empty and owned by this restore (the
                // safe restore uses a private staging folder that is only put in place afterwards),
                // so a temporary name and a rename per file would add nothing but time.
                var completed = false;
                try
                {
                    await using (var destination = new FileStream(
                        item.FullPath,
                        FileMode.CreateNew,
                        FileAccess.Write,
                        FileShare.None,
                        0,
                        FileOptions.SequentialScan))
                    {
                        await reader.CopyObjectAtAsync(
                            item.Entry.ObjectId.Value,
                            item.Entry.PackOffset.Value,
                            destination,
                            cancellationToken,
                            observer is null ? null : (bytes, token) => observer(new RestoreProgress(
                                "file.restore.progress", completedItems, files.LongLength,
                                completedBytes + bytes, totalBytes, item.Entry.RelativePath), token));
                        File.SetLastWriteTimeUtc(destination.SafeFileHandle, item.Entry.ModifiedUtc.UtcDateTime);
                    }
                    completed = true;
                }
                finally
                {
                    // A file that was not written completely is not left behind.
                    if (!completed && File.Exists(item.FullPath)) File.Delete(item.FullPath);
                }

                flush.Add(item.FullPath);
                completedItems++;
                completedBytes += item.Entry.ByteLength;
                if (observer is not null)
                    await observer(new RestoreProgress(
                        "file.restore.completed", completedItems, files.LongLength,
                        completedBytes, totalBytes, item.Entry.RelativePath,
                        item.Entry.ByteLength), cancellationToken);
            }

            await flush.CompleteAsync();
            // Only now: a read-only attribute would stop a file from being opened for its flush.
            foreach (var item in files)
                ApplyAttributes(item.FullPath, item.Entry);

            foreach (var item in planned
                         .Where(item => item.Entry.EntryKind == "Directory")
                         .OrderByDescending(item => item.Entry.RelativePath.Count(character => character == '/')))
            {
                ApplyMetadata(item.FullPath, item.Entry);
            }

            // Everything is on disk with its final times and attributes.
            if (observer is not null)
                await observer(new RestoreProgress(
                    "workload.completed", completedItems, files.LongLength,
                    completedBytes, totalBytes), cancellationToken);

            return new RestoreResult(
                sourceId,
                revision,
                planned.Count(item => item.Entry.EntryKind == "File"),
                planned.Count(item => item.Entry.EntryKind == "Directory"));
        }
        finally
        {
            if (reader is not null) await reader.DisposeAsync();
        }
    }

    /// <summary>
    /// Hands a revision's folders and file contents to the caller instead of writing them to
    /// disk, for example straight into an archive. Paths are checked exactly as for a restore,
    /// and each object is verified as it is read.
    /// </summary>
    public async Task<RestoreResult> ReadAsync(
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        Func<RevisionItem, CancellationToken, Task> addDirectory,
        Func<RevisionItem, CancellationToken, Task<Stream>> openFile,
        Func<RestoreProgress, CancellationToken, Task>? observer = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(addDirectory);
        ArgumentNullException.ThrowIfNull(openFile);
        var entries = await repository.ReadRevisionEntriesAsync(sourceId, revision, cancellationToken);
        // The same path rules as a restore, checked against a folder that is never created.
        var planned = Preflight(VirtualRoot, entries);
        var directories = planned.Where(item => item.Entry.EntryKind == "Directory")
            .OrderBy(item => item.Entry.RelativePath, StringComparer.Ordinal).ToArray();
        var files = planned.Where(item => item.Entry.EntryKind == "File").ToArray();
        var totalBytes = files.Sum(item => item.Entry.ByteLength);
        if (observer is not null)
            await observer(new RestoreProgress(
                "workload.discovered", 0, files.LongLength, 0, totalBytes), cancellationToken);
        foreach (var item in directories)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await addDirectory(ToItem(item.Entry), cancellationToken);
        }

        long completedItems = 0;
        long completedBytes = 0;
        PackReader? reader = null;
        try
        {
            foreach (var item in files.OrderBy(item => item.Entry.PackId).ThenBy(item => item.Entry.PackOffset))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (item.Entry.ObjectId is null
                    || item.Entry.PackId is null
                    || item.Entry.PackRelativePath is null
                    || item.Entry.PackOffset is null)
                {
                    throw new InvalidDataException(
                        $"File '{item.Entry.RelativePath}' has no stored object.");
                }

                if (reader is null || reader.PackId != item.Entry.PackId.Value)
                {
                    if (reader is not null) await reader.DisposeAsync();
                    reader = null;
                    reader = await openPackReader(
                        ResolveRepositoryPath(repository.RepositoryPath, item.Entry.PackRelativePath),
                        item.Entry.PackId.Value,
                        cancellationToken);
                }

                await using (var destination = await openFile(ToItem(item.Entry), cancellationToken))
                {
                    await reader.CopyObjectAtAsync(
                        item.Entry.ObjectId.Value,
                        item.Entry.PackOffset.Value,
                        destination,
                        cancellationToken,
                        observer is null ? null : (bytes, token) => observer(new RestoreProgress(
                            "file.restore.progress", completedItems, files.LongLength,
                            completedBytes + bytes, totalBytes, item.Entry.RelativePath), token));
                }

                completedItems++;
                completedBytes += item.Entry.ByteLength;
                if (observer is not null)
                    await observer(new RestoreProgress(
                        "file.restore.completed", completedItems, files.LongLength,
                        completedBytes, totalBytes, item.Entry.RelativePath,
                        item.Entry.ByteLength), cancellationToken);
            }
        }
        finally
        {
            if (reader is not null) await reader.DisposeAsync();
        }

        return new RestoreResult(sourceId, revision, files.Length, directories.Length);

        static RevisionItem ToItem(RevisionEntry entry) =>
            new(entry.RelativePath, entry.ByteLength, entry.ModifiedUtc);
    }

    private static readonly string VirtualRoot =
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.Combine(Path.GetTempPath(), "pztools-revision")));

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

    /// <summary>Flushes written files to disk on a few workers, in the background.</summary>
    private sealed class BackgroundFlush : IAsyncDisposable
    {
        private readonly Channel<string> queue = Channel.CreateUnbounded<string>(
            new UnboundedChannelOptions { SingleWriter = true });
        private readonly CancellationTokenSource stop;
        private readonly Task[] workers;

        public BackgroundFlush(CancellationToken cancellationToken)
        {
            stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            workers = Enumerable.Range(0, Math.Clamp(Environment.ProcessorCount, 1, 8))
                .Select(_ => Task.Run(WorkAsync))
                .ToArray();
        }

        public void Add(string path) => queue.Writer.TryWrite(path);

        /// <summary>Returns once every added file is on disk; throws if any flush failed.</summary>
        public Task CompleteAsync()
        {
            queue.Writer.TryComplete();
            return Task.WhenAll(workers);
        }

        private async Task WorkAsync()
        {
            await foreach (var path in queue.Reader.ReadAllAsync(stop.Token))
            {
                using var handle = File.OpenHandle(path, FileMode.Open, FileAccess.Write, FileShare.Read);
                RandomAccess.FlushToDisk(handle);
            }
        }

        public async ValueTask DisposeAsync()
        {
            // After a failure the remaining flushes are pointless: the restore is discarded.
            queue.Writer.TryComplete();
            await stop.CancelAsync();
            try { await Task.WhenAll(workers); }
            catch (Exception exception) when (exception is OperationCanceledException or IOException or UnauthorizedAccessException) { }
            stop.Dispose();
        }
    }

    private static void ApplyAttributes(string path, RevisionEntry entry)
    {
        var restorableAttributes = entry.Attributes
            & ~(FileAttributes.ReparsePoint | FileAttributes.Device | FileAttributes.Offline);
        // A new file already carries Archive; setting only that again is a wasted call per file.
        if (restorableAttributes != FileAttributes.Archive)
            File.SetAttributes(path, restorableAttributes);
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
