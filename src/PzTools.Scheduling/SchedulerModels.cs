using PzTools.Process.Contracts;

namespace PzTools.Scheduling;

public enum SchedulerMode { Paused, Continuous, Limited, Ambiguous }

public enum BackupTargetCommandKind
{
    ActivateTarget,
    FinalizeTarget,
    ClearTarget,
    RunOnceNow,
    SuspendAmbiguous,
}

public enum BackupAdmissionKind
{
    Periodic,
    Final,
    RunOnce,
}

public sealed record BackupTarget(
    string SaveId,
    string SourceKey,
    string SourcePath)
{
    public void Validate()
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(SaveId);
        ArgumentException.ThrowIfNullOrWhiteSpace(SourceKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(SourcePath);
        if (!Path.IsPathFullyQualified(SourcePath))
            throw new ArgumentException("A backup target path must be absolute.", nameof(SourcePath));
    }
}

public sealed record BackupTargetCommand(
    string IdempotencyKey,
    BackupTargetCommandKind Kind,
    BackupTarget Target,
    string? TransitionId = null,
    long? CauseRunIndex = null)
{
    public void Validate()
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(IdempotencyKey);
        Target.Validate();
        if (CauseRunIndex is <= 0)
            throw new ArgumentOutOfRangeException(nameof(CauseRunIndex));
    }
}

public sealed record BackupSchedulerState(
    bool Modified,
    long SchedulerRevision,
    string RepositoryPath,
    bool AutomaticEnabled,
    TimeSpan Interval,
    BackupTarget? CurrentTarget,
    SchedulerMode Mode,
    int AttemptsRemaining,
    int PendingRuns,
    long Generation,
    DateTimeOffset NextDueUtc,
    long? LastRunIndex,
    ProcessOutcome? LastOutcome)
{
    public string PeriodicAdmissionId =>
        $"backup-scheduler:periodic:{Generation}:{NextDueUtc:O}:{LastRunIndex}";

    public void Validate()
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(RepositoryPath);
        if (Interval < TimeSpan.FromMinutes(1)
            || Interval > TimeSpan.FromMinutes(60)
            || Interval.Ticks % TimeSpan.TicksPerMinute != 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(Interval), "The backup interval must be 1 to 60 whole minutes.");
        }
        CurrentTarget?.Validate();
        if (SchedulerRevision < 0 || Generation < 0)
            throw new ArgumentOutOfRangeException(nameof(SchedulerRevision));
        if (Mode == SchedulerMode.Limited && AttemptsRemaining <= 0)
            throw new ArgumentOutOfRangeException(nameof(AttemptsRemaining));
        if (Mode != SchedulerMode.Limited && AttemptsRemaining != 0)
            throw new ArgumentException(
                "Only Limited mode may have remaining attempts.",
                nameof(AttemptsRemaining));
    }
}

public sealed record BackupTickAdmission(
    string AdmissionId,
    BackupAdmissionKind Kind,
    BackupTarget Target,
    string RepositoryPath,
    DateTimeOffset ScheduledUtc,
    long Generation,
    string? PendingCommandId);

public sealed record WorkerInvocation(
    bool Started,
    ProcessOutcome Outcome,
    string? FailureCode = null);

public sealed record BackupTickResult(
    bool Due,
    long? RunIndex,
    BackupTarget? Target,
    WorkerInvocation? Backup,
    WorkerInvocation? Maintenance,
    ProcessOutcome Outcome);

public sealed record StateTickResult(bool Due, long? RunIndex, WorkerInvocation? Runner);
