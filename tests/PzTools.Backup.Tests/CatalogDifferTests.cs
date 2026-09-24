using PzTools.Backup.Core;

namespace PzTools.Backup.Tests;

public sealed class CatalogDifferTests
{
    private static readonly DateTimeOffset Timestamp = new(2026, 9, 21, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Diff_ClassifiesAddedModifiedDeletedAndCaseRename()
    {
        var previous = Catalog(
            Entry("deleted.txt", 1),
            Entry("modified.txt", 1),
            Entry("Name.txt", 1),
            Entry("unchanged.txt", 1));
        var current = Catalog(
            Entry("added.txt", 1),
            Entry("modified.txt", 2),
            Entry("name.txt", 1),
            Entry("unchanged.txt", 1));

        var changes = CatalogDiffer.Diff(previous, current);

        Assert.Collection(
            changes,
            change => Assert.Equal(CatalogChangeKind.Added, change.Kind),
            change => Assert.Equal(CatalogChangeKind.Deleted, change.Kind),
            change => Assert.Equal(CatalogChangeKind.Modified, change.Kind),
            change => Assert.Equal(CatalogChangeKind.Renamed, change.Kind));
        Assert.Equal(
            ["added.txt", "deleted.txt", "modified.txt", "name.txt"],
            changes.Select(change => change.RelativePath));
    }

    [Fact]
    public void Diff_RejectsDuplicatePathsIgnoringCase()
    {
        var invalid = Catalog(Entry("same.txt", 1), Entry("SAME.txt", 1));

        Assert.Throws<InvalidDataException>(() => CatalogDiffer.Diff(invalid, Catalog()));
    }

    private static FileCatalog Catalog(params CatalogEntry[] entries)
    {
        return FileCatalog.Create("C:\\source", Timestamp, entries);
    }

    private static CatalogEntry Entry(string path, long size)
    {
        return new CatalogEntry(path, CatalogEntryKind.File, size, Timestamp, FileAttributes.Normal);
    }
}

