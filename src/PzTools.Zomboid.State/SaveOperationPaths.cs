using PzTools.Process.Hosting;

namespace PzTools.Zomboid.State;

// On-disk names used by SafeRevisionRestoreService and ZomboidArchiveService.
// Match the operation token as well as the prefix; ordinary dot-prefixed saves are valid.
internal static class SaveOperationPaths
{
    private const string JournalSuffix = ".pztools-restore.json";
    private const string ImportPrefix = ".pztools-import-";

    public static bool IsTemporaryDirectory(string path)
    {
        var name = Path.GetFileName(path);
        if (name.StartsWith(ImportPrefix, StringComparison.OrdinalIgnoreCase)
            && Guid.TryParseExact(name[ImportPrefix.Length..], "N", out _)) return true;
        if (!name.StartsWith('.')) return false;
        if (name.EndsWith(".pztools-file-edit", StringComparison.OrdinalIgnoreCase)) return true;
        foreach (var marker in new[] { ".pztools-staging-", ".pztools-rollback-" })
        {
            var index = name.LastIndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (index > 1 && Guid.TryParseExact(name[(index + marker.Length)..], "N", out _))
                return true;
        }
        return false;
    }

    public static IEnumerable<string> RestoringTargets(string modePath)
    {
        foreach (var directory in Directory.EnumerateDirectories(modePath, ".*.pztools-file-edit"))
        {
            var name = Path.GetFileName(directory);
            if (name.Length > ".pztools-file-edit".Length + 1)
                yield return Normalize(Path.Combine(modePath, name[1..^".pztools-file-edit".Length]));
        }
        foreach (var target in JournalTargets(modePath))
            if (IsSaveLocked(target)) yield return target;
    }

    // A journal without its save directory may still hold the original in rollback.
    public static bool HasJournalWithoutSave(string modePath) =>
        JournalTargets(modePath).Any(target => !Directory.Exists(target));

    public static bool IsRestoring(string savePath) => (File.Exists(Path.Combine(
        Path.GetDirectoryName(savePath)!, $".{Path.GetFileName(savePath)}{JournalSuffix}")) && IsSaveLocked(savePath))
        || Directory.Exists(Path.Combine(Path.GetDirectoryName(savePath)!, $".{Path.GetFileName(savePath)}.pztools-file-edit"));

    private static IEnumerable<string> JournalTargets(string modePath)
    {
        foreach (var journal in Directory.EnumerateFiles(modePath, ".*" + JournalSuffix))
        {
            var name = Path.GetFileName(journal);
            if (name.Length > JournalSuffix.Length + 1)
                yield return Normalize(Path.Combine(modePath, name[1..^JournalSuffix.Length]));
        }
    }

    // The restore worker holds the save lock for as long as it owns its journal. A journal
    // nobody owns was left by a failed or crashed restore and must not hide a playable save.
    private static bool IsSaveLocked(string savePath) =>
        OperationMutexSet.IsInUse(new OperationMutexRequest(OperationMutexScope.SaveWrite, savePath));

    private static string Normalize(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)).ToUpperInvariant();
}
