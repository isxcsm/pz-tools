namespace PzTools.Backup.Core;

public enum CatalogEntryKind
{
    File,
    Directory,
}

public sealed record CatalogEntry(
    string RelativePath,
    CatalogEntryKind Kind,
    long Size,
    DateTimeOffset LastWriteTimeUtc,
    FileAttributes Attributes,
    string? FileSystemId = null,
    string? ContentId = null)
{
    public string RelativePath { get; init; } = BackupPath.NormalizeRelative(RelativePath);
}

