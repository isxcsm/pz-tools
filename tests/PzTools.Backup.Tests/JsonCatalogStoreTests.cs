using PzTools.Backup.Core;
using PzTools.Backup.Storage;

namespace PzTools.Backup.Tests;

public sealed class JsonCatalogStoreTests
{
    [Fact]
    public async Task SaveAndLoad_RoundTripsCatalog()
    {
        using var temporary = new TempDirectory();
        var catalogPath = temporary.GetPath("catalogs", "baseline.json");
        var timestamp = new DateTimeOffset(2026, 9, 21, 1, 2, 3, TimeSpan.Zero);
        var catalog = FileCatalog.Create(
            temporary.Path,
            timestamp,
            [new CatalogEntry("file.bin", CatalogEntryKind.File, 42, timestamp, FileAttributes.Archive)]);
        var store = new JsonCatalogStore();

        await store.SaveAsync(catalogPath, catalog);
        var loaded = await store.LoadAsync(catalogPath);

        Assert.Equal(catalog.FormatVersion, loaded.FormatVersion);
        Assert.Equal(catalog.SourceRoot, loaded.SourceRoot);
        Assert.Equal(catalog.ScannedAtUtc, loaded.ScannedAtUtc);
        Assert.Equal<CatalogEntry>(catalog.Entries, loaded.Entries);
        Assert.False(Directory.EnumerateFiles(temporary.GetPath("catalogs"), "*.tmp").Any());
    }
}
