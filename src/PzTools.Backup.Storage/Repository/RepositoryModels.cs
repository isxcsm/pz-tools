namespace PzTools.Backup.Storage.Repository;

public sealed record RepositoryIdentity(
    Guid RepositoryId,
    int FormatVersion,
    int SchemaVersion,
    DateTimeOffset CreatedUtc);

public sealed record RepositorySource(
    long SourceId,
    string SourceKey,
    string RootPath,
    DateTimeOffset CreatedUtc);

public sealed record SourceCheckpoint(
    string VolumeIdentity,
    string JournalId,
    long NextUsn);

public sealed record StartedRun(
    long RunIndex,
    long SourceId,
    DateTimeOffset StartedUtc,
    bool OwnsWorkflow = true);

public sealed record RepositoryRun(
    long RunIndex,
    long SourceId,
    RunStatus Status,
    DateTimeOffset StartedUtc,
    DateTimeOffset? CompletedUtc,
    string? FailureCode);

public enum RunStatus
{
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Abandoned,
}

public sealed record SourceState(
    long SourceId,
    long CurrentRevision,
    SourceCheckpoint? Checkpoint);
