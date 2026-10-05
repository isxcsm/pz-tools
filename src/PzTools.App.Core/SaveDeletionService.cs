using System.Diagnostics;

namespace PzTools.App.Core;

public sealed record SaveDeletionResult(string SourcePath);
public enum SaveDeletionPhase { Discovering, Validating, DeletingFiles, DeletingBackups }
public sealed record SaveDeletionProgress(SaveDeletionPhase Phase, long CompletedItems = 0, long? TotalItems = null);

public sealed class SaveBackupDeletionFailedException(string sourcePath, Exception innerException)
    : IOException($"The save folder '{sourcePath}' was deleted, but backup deletion could not be committed.", innerException);

public static class SaveDeletionService
{
    // Permanently deletes one checked save folder and nothing else. The coordinator marks its backups deleted.
    // Without an interval every step is reported: the window samples them at the configured
    // ExportProgressIntervalMs, which a default AppRuntimeOptions here could not know.
    public static SaveDeletionResult DeletePermanently(
        string savesRoot, string saveId, CancellationToken cancellationToken = default,
        IProgress<SaveDeletionProgress>? progress = null, TimeSpan? progressInterval = null)
    {
        var interval = progressInterval ?? TimeSpan.Zero;
        var lastReport = Stopwatch.GetTimestamp();
        void Report(SaveDeletionPhase phase, long completed = 0, long? total = null, bool force = false)
        {
            if (progress is null || (!force && Stopwatch.GetElapsedTime(lastReport) < interval)) return;
            progress.Report(new(phase, completed, total));
            lastReport = Stopwatch.GetTimestamp();
        }
        Report(SaveDeletionPhase.Discovering, force: true);
        var parts = saveId.Replace('\\', '/').Split('/');
        if (parts.Length != 2 || parts.Any(part => string.IsNullOrWhiteSpace(part)
            || part is "." or ".." || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
            || part != part.TrimEnd(' ', '.')))
            throw new ArgumentException("A save ID must contain exactly a mode and a save name.", nameof(saveId));
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(savesRoot));
        if (Path.GetDirectoryName(root) is null)
            throw new ArgumentException("The saves root must not be a volume root.", nameof(savesRoot));
        var source = Path.GetFullPath(Path.Combine(root, parts[0], parts[1]));
        if (!source.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("The save must be inside the configured saves root.");
        RejectLinkedAncestors(source);
        var players = Path.Combine(source, "players.db");
        if (!File.Exists(players))
            throw new InvalidDataException("The target is not an existing save (players.db is missing).");

        // Keep SQLite from opening the save after preflight. Delete sharing lets us
        // remove players.db while still denying readers and writers; delete it last.
        using var playersGuard = File.OpenHandle(players, FileMode.Open, FileAccess.Read, FileShare.Delete);
        // Enumerate once. Keep the full preflight so a known locked file prevents any deletion.
        var files = new List<string>();
        var directories = new List<string>();
        Discover(new DirectoryInfo(source));
        Report(SaveDeletionPhase.Validating, 0, files.Count, force: true);
        for (var i = 0; i < files.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsPlayersDatabase(files[i]))
                using (var exclusive = File.OpenHandle(files[i], FileMode.Open, FileAccess.Read, FileShare.None)) { }
            Report(SaveDeletionPhase.Validating, i + 1, files.Count, force: i + 1 == files.Count);
        }

        cancellationToken.ThrowIfCancellationRequested();
        RejectLinkedAncestors(source);
        // No recycle bin or holding folder. If Windows stops it with an error, some files may already be gone.
        var total = files.Count + directories.Count;
        long deleted = 0;
        Report(SaveDeletionPhase.DeletingFiles, 0, total, force: true);
        foreach (var group in files.GroupBy(Path.GetDirectoryName, StringComparer.OrdinalIgnoreCase))
        {
            cancellationToken.ThrowIfCancellationRequested();
            // Validate the parent once per directory, not once per chunk file.
            RejectLinkedAncestors(group.Key!);
            foreach (var file in group)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (IsPlayersDatabase(file)) continue;
                File.Delete(file);
                Report(SaveDeletionPhase.DeletingFiles, ++deleted, total);
            }
        }
        for (var i = directories.Count - 1; i > 0; i--)
        {
            cancellationToken.ThrowIfCancellationRequested();
            RejectLinkedAncestors(directories[i]);
            // A newly created, unvalidated child must stop deletion, not be recursively removed.
            Directory.Delete(directories[i], recursive: false);
            Report(SaveDeletionPhase.DeletingFiles, ++deleted, total, force: deleted == total);
        }
        cancellationToken.ThrowIfCancellationRequested();
        RejectLinkedAncestors(source);
        File.Delete(players);
        // Finish the pending deletion before removing its parent directory.
        playersGuard.Dispose();
        Report(SaveDeletionPhase.DeletingFiles, ++deleted, total);
        Directory.Delete(source, recursive: false);
        Report(SaveDeletionPhase.DeletingFiles, ++deleted, total, force: true);
        return new SaveDeletionResult(source);

        bool IsPlayersDatabase(string path) => path.Equals(players, StringComparison.OrdinalIgnoreCase);

        void Discover(DirectoryInfo directory)
        {
            directories.Add(directory.FullName);
            foreach (var entry in directory.EnumerateFileSystemInfos())
            {
                cancellationToken.ThrowIfCancellationRequested();
                var attributes = entry.Attributes;
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("Saves containing linked files cannot be deleted.");
                if (entry is DirectoryInfo child) Discover(child);
                else
                {
                    if ((attributes & FileAttributes.ReadOnly) != 0)
                        throw new IOException("Saves containing read-only files cannot be deleted.");
                    files.Add(entry.FullName);
                }
                Report(SaveDeletionPhase.Discovering, files.Count + directories.Count);
            }
        }
    }

    private static void RejectLinkedAncestors(string path)
    {
        for (var current = new DirectoryInfo(path); current is not null; current = current.Parent)
            if ((current.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Linked save directories cannot be deleted.");
    }

}
