namespace PzTools.Backup.Storage.Repository;

public enum WorkflowStatus
{
    Running,
    Succeeded,
    NoChange,
    Skipped,
    Busy,
    Degraded,
    Failed,
    Cancelled,
    Abandoned,
    LaunchFailed,
}

public sealed record WorkflowRun(
    long RunIndex,
    string Pipeline,
    long? SourceId,
    string OwnerComponent,
    string? AdmissionId,
    WorkflowStatus Status,
    DateTimeOffset StartedUtc,
    DateTimeOffset? CompletedUtc,
    string? FailureCode);

public sealed record WorkflowStage(
    long RunIndex,
    string Producer,
    WorkflowStatus Status,
    DateTimeOffset StartedUtc,
    DateTimeOffset? CompletedUtc,
    string? FailureCode);
