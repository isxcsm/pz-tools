using PzTools.Backup.Core;

namespace PzTools.Backup.Engine;

public sealed record FullScanEntry(
    string PathKey,
    string RelativePath,
    CatalogEntryKind Kind,
    long Length,
    DateTimeOffset ModifiedUtc,
    DateTimeOffset ChangedUtc,
    FileAttributes Attributes,
    byte[] FileId,
    byte[] ParentFileId);

public enum FullScanChangeKind
{
    Added,
    Modified,
    Deleted,
}

public sealed record FullScanChange(FullScanChangeKind Kind, FullScanEntry Entry);
