namespace PzTools.Backup.Storage.Repository;

public sealed record RevisionPruneResult(long SourceId, int DeletedRevisions, long? OldestRetainedRevision);

public sealed record RevisionRetentionResult(
    long SourceId,
    int MarkedDeleted,
    long ActiveRevisionCount,
    long? OldestActiveRevision);

public sealed record RevisionCompactionResult(
    long SourceId,
    int CompactedRevisions,
    int RebasedEntryVersions);

public sealed record GarbageCollectionResult(
    int DeletedObjects,
    int DeletedPacks,
    int DeletedOrphanFiles,
    IReadOnlyList<string> FilesThatCouldNotBeDeleted);

public sealed record PackCompactionResult(
    int SourcePacks,
    int RelocatedObjects,
    Guid? NewPackId,
    IReadOnlyList<string> FilesThatCouldNotBeDeleted);

public sealed record ArtifactCleanupResult(
    int DeletedTemporaryFiles,
    IReadOnlyList<string> FilesThatCouldNotBeDeleted);
