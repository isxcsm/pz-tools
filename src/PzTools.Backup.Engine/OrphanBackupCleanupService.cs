using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record ReclaimedSaveBackups(string SaveId, int Revisions);
public sealed record OrphanBackupCleanupResult(
    IReadOnlyList<ReclaimedSaveBackups> Removed, int DeferredSources,
    IReadOnlyList<string> FilesThatCouldNotBeDeleted);

public sealed class OrphanBackupCleanupService
{
    // RepositoryAccess must cover this entire operation, including physical GC.
    public async Task<OrphanBackupCleanupResult> RunAsync(
        RepositoryDatabase repository, RepositoryWriterLease lease, string savesRoot,
        CancellationToken cancellationToken = default,
        Func<ReclaimedSaveBackups, Task>? onReclaimed = null)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(savesRoot));
        var removed = new List<ReclaimedSaveBackups>();
        var deferred = 0;
        foreach (var source in await repository.ReadMaintenanceSourcesAsync(cancellationToken))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsConfirmedMissing(root, source)) { deferred++; continue; }
            var count = await repository.ReclaimOrphanSourceAsync(lease, source, cancellationToken);
            if (count is null) deferred++;
            else if (count > 0)
            {
                var item = new ReclaimedSaveBackups(source.SourceKey, count.Value);
                removed.Add(item);
                // Report committed deletions even when a later source or GC yields to a backup.
                if (onReclaimed is not null) await onReclaimed(item);
            }
        }
        // Also retry physical deletion after interruption or a previous sharing violation.
        var garbage = await repository.CollectGarbageAsync(lease, cancellationToken);
        return new OrphanBackupCleanupResult(removed, deferred, garbage.FilesThatCouldNotBeDeleted);
    }

    private static bool IsConfirmedMissing(string root, RepositorySource source)
    {
        var parts = source.SourceKey.Replace('\\', '/').Split('/');
        if (parts.Length != 2 || parts.Any(part => string.IsNullOrWhiteSpace(part)
            || part is "." or ".." || part.EndsWith('.') || part.EndsWith(' ')
            || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)) return false;
        var expected = Path.Combine(root, parts[0], parts[1]);
        if (!StringComparer.OrdinalIgnoreCase.Equals(expected,
                Path.TrimEndingDirectorySeparator(Path.GetFullPath(source.RootPath)))) return false;
        try
        {
            // Do not interpret disconnected roots, denied enumeration, or junctions as deletion.
            for (var ancestor = new DirectoryInfo(root); ancestor is not null; ancestor = ancestor.Parent)
                if ((File.GetAttributes(ancestor.FullName) & FileAttributes.ReparsePoint) != 0) return false;
            var rootEntries = Directory.GetFileSystemEntries(root);
            var mode = Path.Combine(root, parts[0]);
            if (!rootEntries.Contains(mode, StringComparer.OrdinalIgnoreCase)) return true;
            if ((File.GetAttributes(mode) & FileAttributes.ReparsePoint) != 0) return false;
            var entries = Directory.GetFileSystemEntries(mode);
            if (entries.Contains(expected, StringComparer.OrdinalIgnoreCase)) return false;
            var journal = Path.Combine(mode, $".{parts[1]}.pztools-restore.json");
            if (entries.Contains(journal, StringComparer.OrdinalIgnoreCase)) return false;
            if (PzTools.Process.Hosting.SaveFileEditTransaction.IsPending(expected)) return false;
            return !entries.Any(entry => new[] { "staging", "rollback" }.Any(kind =>
            {
                var prefix = $".{parts[1]}.pztools-{kind}-";
                var name = Path.GetFileName(entry);
                return name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                    && Guid.TryParseExact(name[prefix.Length..], "N", out _);
            }));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
