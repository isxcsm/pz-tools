namespace PzTools.Backup.Core;

public sealed record FileCatalog(
    int FormatVersion,
    string SourceRoot,
    DateTimeOffset ScannedAtUtc,
    IReadOnlyList<CatalogEntry> Entries)
{
    public const int CurrentFormatVersion = 1;

    public static FileCatalog Create(
        string sourceRoot,
        DateTimeOffset scannedAtUtc,
        IReadOnlyList<CatalogEntry> entries)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceRoot);
        ArgumentNullException.ThrowIfNull(entries);

        return new FileCatalog(
            CurrentFormatVersion,
            Path.GetFullPath(sourceRoot),
            scannedAtUtc,
            entries);
    }
}

