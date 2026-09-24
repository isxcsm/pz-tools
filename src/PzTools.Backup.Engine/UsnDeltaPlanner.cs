using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;

namespace PzTools.Backup.Engine;

public sealed record TrackedPath(
    UInt128 FileReferenceNumber,
    UInt128 ParentFileReferenceNumber,
    string RelativePath,
    bool IsDirectory);

public sealed record UsnDeltaPlan(
    IReadOnlyList<string> AffectedPaths,
    IReadOnlyList<string> SubtreeRoots,
    IReadOnlySet<UInt128> ContentChangedFileReferences);

public sealed class UsnDeltaPlanner
{
    public UsnDeltaAccumulator CreateAccumulator(UInt128 sourceRootReference) =>
        new(sourceRootReference);

    public UsnDeltaPlan Plan(
        UInt128 sourceRootReference,
        IEnumerable<TrackedPath> currentPaths,
        IEnumerable<UsnRecord> records)
    {
        ArgumentNullException.ThrowIfNull(currentPaths);
        ArgumentNullException.ThrowIfNull(records);
        var accumulator = CreateAccumulator(sourceRootReference);
        accumulator.AddTrackedPaths(currentPaths);
        accumulator.AddRecords(records.OrderBy(item => item.Usn));
        return accumulator.Build();
    }
}

public sealed class UsnDeltaAccumulator(UInt128 sourceRootReference)
{
    private readonly Dictionary<UInt128, List<TrackedPath>> paths = [];
    private readonly Dictionary<UInt128, string> oldRenamePaths = [];
    private readonly Dictionary<string, string> affected = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> subtreeRoots = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<UInt128> contentChanged = [];

    public void AddTrackedPaths(IEnumerable<TrackedPath> trackedPaths)
    {
        ArgumentNullException.ThrowIfNull(trackedPaths);
        foreach (var tracked in trackedPaths)
        {
            if (!paths.TryGetValue(tracked.FileReferenceNumber, out var links))
            {
                links = [];
                paths.Add(tracked.FileReferenceNumber, links);
            }

            if (!links.Any(item => item.RelativePath.Equals(
                    tracked.RelativePath, StringComparison.OrdinalIgnoreCase)))
            {
                links.Add(tracked);
            }
        }
    }

    public void AddRecords(IEnumerable<UsnRecord> records)
    {
        ArgumentNullException.ThrowIfNull(records);
        foreach (var record in records) AddRecord(record);
    }

    public UsnDeltaPlan Build() =>
        new(
            affected.Values.Order(StringComparer.OrdinalIgnoreCase).ToArray(),
            subtreeRoots.Values.Order(StringComparer.OrdinalIgnoreCase).ToArray(),
            contentChanged.ToHashSet());

    private void AddRecord(UsnRecord record)
    {
        const UsnReason contentReasons = UsnReason.DataOverwrite | UsnReason.DataExtend
            | UsnReason.DataTruncation | UsnReason.NamedDataOverwrite
            | UsnReason.NamedDataExtend | UsnReason.NamedDataTruncation;
        if ((record.Reason & contentReasons) != 0)
            contentChanged.Add(record.FileReferenceNumber);
        paths.TryGetValue(record.FileReferenceNumber, out var existingLinks);
        var candidate = ResolveCandidate(record.ParentFileReferenceNumber, record.FileName);
        var isDirectory = (record.FileAttributes & FileAttributes.Directory) != 0
            || existingLinks?.Any(item => item.IsDirectory) == true;

        if ((record.Reason & UsnReason.RenameOldName) != 0)
        {
            var oldPath = candidate ?? existingLinks?.FirstOrDefault()?.RelativePath;
            if (oldPath is not null)
            {
                oldRenamePaths[record.FileReferenceNumber] = oldPath;
                AddAffected(oldPath, isDirectory);
            }
        }

        if ((record.Reason & UsnReason.FileDelete) != 0)
        {
            var deletedPath = candidate
                ?? oldRenamePaths.GetValueOrDefault(record.FileReferenceNumber)
                ?? existingLinks?.FirstOrDefault()?.RelativePath;
            if (deletedPath is not null)
            {
                AddAffected(deletedPath, isDirectory);
                RemovePath(record.FileReferenceNumber, deletedPath);
            }

            oldRenamePaths.Remove(record.FileReferenceNumber);
            return;
        }

        if ((record.Reason & (UsnReason.RenameNewName | UsnReason.FileCreate)) != 0)
        {
            if (oldRenamePaths.Remove(record.FileReferenceNumber, out var oldPath))
            {
                AddAffected(oldPath, isDirectory);
                RemovePath(record.FileReferenceNumber, oldPath);
            }

            if (candidate is null)
            {
                if (existingLinks is not null)
                {
                    foreach (var existing in existingLinks.ToArray())
                        AddAffected(existing.RelativePath, existing.IsDirectory);
                    paths.Remove(record.FileReferenceNumber);
                }

                return;
            }

            AddAffected(candidate, isDirectory);
            AddTrackedPaths([
                new TrackedPath(
                    record.FileReferenceNumber,
                    record.ParentFileReferenceNumber,
                    candidate,
                    isDirectory),
            ]);
        }

        var contentOrMetadataReason = record.Reason & ~(
            UsnReason.Close
            | UsnReason.RenameOldName
            | UsnReason.RenameNewName
            | UsnReason.FileCreate
            | UsnReason.FileDelete);
        if (contentOrMetadataReason == 0) return;

        if (paths.TryGetValue(record.FileReferenceNumber, out var currentLinks))
        {
            foreach (var link in currentLinks)
                AddAffected(link.RelativePath, link.IsDirectory || isDirectory);
        }
        else if (candidate is not null)
        {
            AddAffected(candidate, isDirectory);
        }
    }

    private string? ResolveCandidate(UInt128 parentReference, string fileName)
    {
        if (parentReference == sourceRootReference)
            return BackupPath.NormalizeRelative(fileName);

        if (!paths.TryGetValue(parentReference, out var parents)) return null;
        var parent = parents.FirstOrDefault(item => item.IsDirectory);
        return parent is null
            ? null
            : BackupPath.NormalizeRelative($"{parent.RelativePath}/{fileName}");
    }

    private void RemovePath(UInt128 reference, string relativePath)
    {
        if (!paths.TryGetValue(reference, out var links)) return;
        links.RemoveAll(item => item.RelativePath.Equals(
            relativePath, StringComparison.OrdinalIgnoreCase));
        if (links.Count == 0) paths.Remove(reference);
    }

    private void AddAffected(string path, bool isDirectory)
    {
        affected[path] = path;
        if (isDirectory) subtreeRoots[path] = path;
    }
}
