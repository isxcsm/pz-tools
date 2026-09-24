using PzTools.Backup.Core;

namespace PzTools.Backup.Tests;

public sealed class FileSystemScannerTests
{
    [Fact]
    public void Scan_CapturesFilesEmptyDirectoriesAndUnicodePaths()
    {
        using var temporary = new TempDirectory();
        Directory.CreateDirectory(temporary.GetPath("empty"));
        Directory.CreateDirectory(temporary.GetPath("한글 폴더"));
        File.WriteAllText(temporary.GetPath("root.txt"), "root");
        File.WriteAllBytes(temporary.GetPath("한글 폴더", "파일.bin"), [1, 2, 3, 4]);

        var catalog = new FileSystemScanner().Scan(temporary.Path);

        Assert.Equal(FileCatalog.CurrentFormatVersion, catalog.FormatVersion);
        Assert.Equal(Path.GetFullPath(temporary.Path), catalog.SourceRoot);
        Assert.Collection(
            catalog.Entries,
            entry => AssertEntry(entry, "empty", CatalogEntryKind.Directory, 0),
            entry => AssertEntry(entry, "root.txt", CatalogEntryKind.File, 4),
            entry => AssertEntry(entry, "한글 폴더", CatalogEntryKind.Directory, 0),
            entry => AssertEntry(entry, "한글 폴더/파일.bin", CatalogEntryKind.File, 4));
    }

    [Fact]
    public void Scan_RejectsMissingRoot()
    {
        using var temporary = new TempDirectory();
        var missing = temporary.GetPath("missing");

        Assert.Throws<DirectoryNotFoundException>(() => new FileSystemScanner().Scan(missing));
    }

    private static void AssertEntry(
        CatalogEntry entry,
        string relativePath,
        CatalogEntryKind kind,
        long size)
    {
        Assert.Equal(relativePath, entry.RelativePath);
        Assert.Equal(kind, entry.Kind);
        Assert.Equal(size, entry.Size);
    }
}

