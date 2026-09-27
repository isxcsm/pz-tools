using PzTools.Process.Contracts;
using PzTools.Projections;

namespace PzTools.App.Core;

/// <summary>Retire disposable telemetry only after its logs have reached the durable inbox.</summary>
public sealed class OperationTelemetryCleanup(string operationsRoot)
{
    public bool TryRemove(TelemetrySourceRegistration source)
    {
        if (!source.Transient || source.CurrentWorkflow is null
            || source.CurrentWorkflow.Status is OperationStatus.Running or OperationStatus.Waiting)
            return false;
        var prefix = source.Component switch
        {
            "archive-worker" => "archive-",
            "restore-worker" => "restore-",
            "character-recovery" => "character-recovery-",
            _ => null,
        };
        var suffix = source.SourceId[(source.SourceId.LastIndexOf('-') + 1)..];
        if (prefix is null || !source.SourceId.StartsWith(prefix, StringComparison.Ordinal)
            || source.SourceId.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
            || !(Guid.TryParseExact(suffix, "N", out _)
                || long.TryParse(suffix, System.Globalization.NumberStyles.None,
                    System.Globalization.CultureInfo.InvariantCulture, out var runIndex) && runIndex > 0))
            return false;
        var root = Path.GetFullPath(operationsRoot);
        var componentRoot = Path.Combine(root, source.Component);
        var identity = Path.Combine(componentRoot, source.SourceId);
        var runtime = Path.Combine(identity, ".pztools");
        var directory = ComponentRuntimePaths.GetComponentDirectory(identity, source.Component);
        var database = Path.Combine(directory, "telemetry.db");
        if (!Path.GetFullPath(source.Identity).Equals(identity, StringComparison.OrdinalIgnoreCase)
            || !Path.GetFullPath(source.DatabasePath).Equals(database, StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            // Never recurse through links or remove unknown user files. Delete only known files,
            // then empty directories; an unexpected addition therefore stops cleanup safely.
            foreach (var path in new[] { root, componentRoot, identity, runtime, directory })
                if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return false;
            if (!Directory.Exists(identity)) return true;
            var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
                { runtime, directory, database, database + "-wal", database + "-shm", database + "-journal",
                    Path.Combine(directory, PzTools.Process.Telemetry.ProcessTelemetryActivity.FileName) };
            var entries = new List<string>();
            foreach (var parent in new[] { identity, runtime, directory })
            {
                if (!Directory.Exists(parent)) continue;
                foreach (var path in Directory.EnumerateFileSystemEntries(parent))
                {
                    if (!allowed.Contains(path) || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) return false;
                    if (File.Exists(path)) entries.Add(path);
                }
            }
            foreach (var file in entries)
                using (new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
            foreach (var file in entries) File.Delete(file);
            foreach (var path in new[] { directory, runtime, identity })
                if (Directory.Exists(path)) Directory.Delete(path, recursive: false);
            return true;
        }
        catch (IOException) { return false; } // Retry on the next projection/startup after handles close.
        catch (UnauthorizedAccessException) { return false; }
    }
}
