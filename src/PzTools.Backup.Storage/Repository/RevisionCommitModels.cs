using PzTools.Process.Contracts;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Repository;

public sealed record PackRegistration(
    Guid PackId,
    string RelativePath,
    int FormatVersion,
    long ByteLength);

public sealed record StoredObjectRegistration(
    Guid ObjectId,
    Guid PackId,
    long PackOffset,
    long StoredLength,
    long OriginalLength,
    string ChecksumAlgorithm,
    byte[]? Checksum,
    string CompressionAlgorithm,
    int Flags = 0,
    byte[]? ContentHash = null);

public sealed record EntryVersionRegistration(
    string RelativePath,
    CatalogEntryKind Kind,
    bool Tombstone,
    long ByteLength,
    DateTimeOffset ModifiedUtc,
    DateTimeOffset ChangedUtc,
    FileAttributes Attributes,
    byte[]? FileId,
    byte[]? ParentFileId,
    Guid? ObjectId);

public sealed record RevisionCommitRequest(
    long RunIndex,
    long SourceId,
    SourceCheckpoint? Checkpoint,
    IReadOnlyList<PackRegistration> Packs,
    IReadOnlyList<StoredObjectRegistration> Objects,
    IReadOnlyList<EntryVersionRegistration> Entries,
    long? RequestedRevision = null,
    SupportedLanguage NameLanguage = SupportedLanguage.Korean);

public sealed record CommittedRevision(
    long SourceId,
    long Revision,
    long RunIndex,
    DateTimeOffset CreatedUtc);
