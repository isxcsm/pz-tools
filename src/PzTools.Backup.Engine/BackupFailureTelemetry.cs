using PzTools.Backup.Core.Capture;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Engine;

internal static class BackupFailureTelemetry
{
    public static string Create(
        RepositorySource source,
        RunStatus status,
        string failureCode,
        Exception exception,
        string phase,
        string? currentFile)
    {
        var unstable = exception as UnstableFileException;
        var path = currentFile;
        if (unstable is not null)
        {
            var relative = Path.GetRelativePath(source.RootPath, unstable.Path);
            if (!Path.IsPathRooted(relative)
                && relative != ".."
                && !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                path = relative.Replace(Path.DirectorySeparatorChar, '/');
        }

        return FailureTelemetry.FromException(
            failureCode,
            exception,
            status: status.ToString(),
            phase: phase,
            path: path,
            reason: unstable?.Reason,
            operation: "backup",
            saveId: source.SourceKey,
            messageOverride: unstable?.Reason,
            redactPathPrefix: source.RootPath);
    }
}
