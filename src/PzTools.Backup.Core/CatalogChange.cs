namespace PzTools.Backup.Core;

public enum CatalogChangeKind
{
    Added,
    Modified,
    Deleted,
    Renamed,
}

public sealed record CatalogChange(
    CatalogChangeKind Kind,
    string RelativePath,
    CatalogEntry? Previous,
    CatalogEntry? Current);

