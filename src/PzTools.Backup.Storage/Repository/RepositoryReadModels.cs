using PzTools.Backup.Core;

namespace PzTools.Backup.Storage.Repository;

public sealed record RevisionEntry(
    string RelativePath,
    string EntryKind,
    long ByteLength,
    DateTimeOffset ModifiedUtc,
    DateTimeOffset ChangedUtc,
    FileAttributes Attributes,
    byte[]? FileId,
    byte[]? ParentFileId,
    Guid? ObjectId,
    Guid? PackId,
    string? PackRelativePath,
    long? PackOffset,
    long? StoredLength,
    long? OriginalLength,
    string? ChecksumAlgorithm,
    byte[]? Checksum,
    string? CompressionAlgorithm,
    int? ObjectFlags);

public sealed record RepositoryPack(
    Guid PackId,
    string RelativePath,
    long ByteLength,
    string Status,
    long CreatedRunIndex);

public sealed record PackUsage(RepositoryPack Pack, long LiveBytes);

public sealed record CompactionObject(
    Guid ObjectId,
    Guid PackId,
    string PackRelativePath,
    long PackOffset,
    long OriginalLength,
    long StoredLength,
    string ChecksumAlgorithm,
    byte[] Checksum,
    string CompressionAlgorithm,
    int Flags);

public sealed record DeduplicationCandidate(
    Guid ObjectId,
    Guid PackId,
    string PackRelativePath,
    long PackOffset,
    long StoredLength,
    long OriginalLength,
    string ChecksumAlgorithm,
    byte[] Checksum,
    string CompressionAlgorithm,
    int Flags);

/// <param name="ContentHash">The object's change fingerprint (first 16 bytes of SHA-256), when recorded.</param>
public sealed record CurrentFileObject(DeduplicationCandidate Object, byte[]? ContentHash);

public sealed record RevisionReference(long SourceId, long Revision);

public sealed record CurrentTrackedPath(
    string RelativePath,
    string EntryKind,
    byte[] FileId,
    byte[] ParentFileId);

public sealed record RepositoryRevisionSummary(
    long Revision,
    DateTimeOffset CreatedUtc,
    long LogicalSize,
    long FileCount,
    string State,
    DateTimeOffset? MetadataFileModifiedUtc = null,
    string DisplayName = "",
    string? CharacterName = null,
    string? CharacterState = null,
    BackupKind Kind = BackupKind.Unknown,
    double? HoursSurvived = null,
    bool CharacterMetadataRead = false,
    string? CharacterMetadataError = null,
    string? GameVersion = null);

public sealed record RepositorySourceHistory(
    long SourceId,
    string SourceKey,
    string RootPath,
    long CurrentRevision,
    IReadOnlyList<RepositoryRevisionSummary> Revisions);

public sealed record RepositoryCatalogSnapshot(
    bool Modified,
    long RepositoryChangeRevision,
    IReadOnlyList<RepositorySourceHistory> Sources);

public sealed record RevisionFileLocator(
    long SourceId,
    long Revision,
    string RelativePath,
    Guid ObjectId,
    Guid PackId,
    string PackRelativePath,
    long PackOffset,
    long StoredLength,
    long OriginalLength,
    string CompressionAlgorithm);
