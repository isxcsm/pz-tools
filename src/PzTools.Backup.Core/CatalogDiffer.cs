namespace PzTools.Backup.Core;

public static class CatalogDiffer
{
    public static IReadOnlyList<CatalogChange> Diff(FileCatalog previous, FileCatalog current)
    {
        ArgumentNullException.ThrowIfNull(previous);
        ArgumentNullException.ThrowIfNull(current);

        var previousEntries = ToPathDictionary(previous.Entries);
        var currentEntries = ToPathDictionary(current.Entries);
        var allPaths = new HashSet<string>(previousEntries.Keys, StringComparer.OrdinalIgnoreCase);
        allPaths.UnionWith(currentEntries.Keys);

        var changes = new List<CatalogChange>();

        foreach (var path in allPaths.Order(StringComparer.OrdinalIgnoreCase))
        {
            var hadPrevious = previousEntries.TryGetValue(path, out var previousEntry);
            var hasCurrent = currentEntries.TryGetValue(path, out var currentEntry);

            if (!hadPrevious)
            {
                changes.Add(new CatalogChange(CatalogChangeKind.Added, currentEntry!.RelativePath, null, currentEntry));
                continue;
            }

            if (!hasCurrent)
            {
                changes.Add(new CatalogChange(CatalogChangeKind.Deleted, previousEntry!.RelativePath, previousEntry, null));
                continue;
            }

            if (!StringComparer.Ordinal.Equals(previousEntry!.RelativePath, currentEntry!.RelativePath))
            {
                changes.Add(new CatalogChange(CatalogChangeKind.Renamed, currentEntry.RelativePath, previousEntry, currentEntry));
                continue;
            }

            if (!MetadataEquals(previousEntry, currentEntry))
            {
                changes.Add(new CatalogChange(CatalogChangeKind.Modified, currentEntry.RelativePath, previousEntry, currentEntry));
            }
        }

        return changes;
    }

    private static Dictionary<string, CatalogEntry> ToPathDictionary(IEnumerable<CatalogEntry> entries)
    {
        var result = new Dictionary<string, CatalogEntry>(StringComparer.OrdinalIgnoreCase);

        foreach (var entry in entries)
        {
            if (!result.TryAdd(entry.RelativePath, entry))
            {
                throw new InvalidDataException($"The catalog contains a duplicate path: '{entry.RelativePath}'.");
            }
        }

        return result;
    }

    private static bool MetadataEquals(CatalogEntry left, CatalogEntry right)
    {
        return left.Kind == right.Kind
            && left.Size == right.Size
            && left.LastWriteTimeUtc.UtcTicks == right.LastWriteTimeUtc.UtcTicks
            && left.Attributes == right.Attributes
            && StringComparer.Ordinal.Equals(left.FileSystemId, right.FileSystemId)
            && StringComparer.Ordinal.Equals(left.ContentId, right.ContentId);
    }
}

