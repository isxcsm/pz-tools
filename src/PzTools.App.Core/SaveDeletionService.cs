using System.Diagnostics;

namespace PzTools.App.Core;

public sealed record SaveDeletionResult(string SourcePath);
public enum SaveDeletionPhase { Discovering, Validating, DeletingFiles, DeletingBackups }
public sealed record SaveDeletionProgress(SaveDeletionPhase Phase, long CompletedItems = 0, long? TotalItems = null);

public sealed class SaveBackupDeletionFailedException(string sourcePath, Exception innerException)
    : IOException($"The save folder '{sourcePath}' was deleted, but backup deletion could not be committed.", innerException);

public static class SaveDeletionService
{
    // 검증한 단일 세이브 폴더만 영구 삭제합니다. 백업 삭제 마킹은 coordinator가 처리합니다.
    public static SaveDeletionResult DeletePermanently(
        string savesRoot, string saveId, CancellationToken cancellationToken = default,
        IProgress<SaveDeletionProgress>? progress = null, TimeSpan? progressInterval = null)
    {
        var interval = progressInterval ?? TimeSpan.FromMilliseconds(new AppRuntimeOptions().ExportProgressIntervalMs);
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

        // Enumerate once. Keep the full preflight so a known locked file prevents any deletion.
        var files = new List<string>();
        var directories = new List<string>();
        Discover(new DirectoryInfo(source));
        Report(SaveDeletionPhase.Validating, 0, files.Count, force: true);
        for (var i = 0; i < files.Count; i++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using (var exclusive = File.OpenHandle(files[i], FileMode.Open, FileAccess.Read, FileShare.None)) { }
            Report(SaveDeletionPhase.Validating, i + 1, files.Count, force: i + 1 == files.Count);
        }

        cancellationToken.ThrowIfCancellationRequested();
        RejectLinkedAncestors(source);
        // 휴지통이나 별도 보관 폴더를 거치지 않습니다. OS 오류로 중단되면 일부 파일은 이미 삭제됐을 수 있습니다.
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
                File.Delete(file);
                Report(SaveDeletionPhase.DeletingFiles, ++deleted, total);
            }
        }
        for (var i = directories.Count - 1; i >= 0; i--)
        {
            cancellationToken.ThrowIfCancellationRequested();
            RejectLinkedAncestors(directories[i]);
            // A newly created, unvalidated child must stop deletion, not be recursively removed.
            Directory.Delete(directories[i], recursive: false);
            Report(SaveDeletionPhase.DeletingFiles, ++deleted, total, force: deleted == total);
        }
        return new SaveDeletionResult(source);

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
