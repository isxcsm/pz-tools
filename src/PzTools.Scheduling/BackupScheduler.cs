using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;

namespace PzTools.Scheduling;

public sealed class BackupScheduler(
    SchedulerDatabase schedulerDatabase,
    Func<CancellationToken, Task<long>> allocateRunIndex,
    Func<string, BackupTarget, long, DateTimeOffset?, CancellationToken, Task<WorkerInvocation>> backupRunner,
    Func<string, BackupTarget, long, long, CancellationToken, Task<WorkerInvocation>> maintenanceRunner,
    string? telemetryConfigurationPath = null,
    TimeSpan? preparationLead = null,
    Func<BackupTarget, bool>? isTargetActive = null,
    RuntimeScheduleController? runtimeSchedule = null,
    Func<BackupTickAdmission, long, CancellationToken, Task<WorkerInvocation>>? guardedBackupRunner = null)
{
    private readonly HashSet<string> recoveredRepositories = (
        new HashSet<string>(StringComparer.OrdinalIgnoreCase));
    // A busy repository (an export or a restore holds it) keeps the backup due. Without a pause the
    // next one-second tick would allocate a run, reserve a workflow and start a runner only to hear
    // "busy" again, for as long as the export lasts.
    private static readonly TimeSpan BusyRetry = TimeSpan.FromSeconds(10);
    private DateTimeOffset busyRetryAt = DateTimeOffset.MinValue;

    public async Task<BackupTickResult> TickAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default)
    {
        var selection = runtimeSchedule is null ? new RuntimeAdmissionSelection(false, null)
            : await runtimeSchedule.PrepareAsync(now, preparationLead ?? TimeSpan.Zero, cancellationToken);
        // With a runtime controller the tick is prepared there either way; only without one is it done here.
        var admission = runtimeSchedule is not null ? selection.Admission : await schedulerDatabase.PrepareBackupTickAsync(
            now, cancellationToken, preparationLead);
        if (admission is null || (!selection.Enabled || RuntimeScheduleController.IsFallback(admission))
            && (isTargetActive is not null && !isTargetActive(admission.Target) || WaitsForNewCharacter(admission)))
        {
            return new BackupTickResult(
                false, null, null, null, null, ProcessOutcome.Skipped);
        }
        if (now < busyRetryAt)
            return new BackupTickResult(false, null, null, null, null, ProcessOutcome.Skipped);

        var repository = await RepositoryDatabase.CreateOrOpenAsync(
            admission.RepositoryPath, cancellationToken);
        if (recoveredRepositories.Add(Path.GetFullPath(admission.RepositoryPath)))
        {
            await repository.RecoverAbandonedWorkflowsAsync(
                "backup-scheduler", cancellationToken: cancellationToken);
        }

        var runIndex = await allocateRunIndex(cancellationToken);
        var workflow = await repository.ReserveWorkflowAsync(
            "backup-maintenance",
            sourceId: null,
            "backup-scheduler",
            admission.AdmissionId,
            runIndex,
            cancellationToken);
        if (workflow.Status != WorkflowStatus.Running)
        {
            var stages = await repository.ReadWorkflowStagesAsync(
                workflow.RunIndex, cancellationToken);
            var workerStarted = stages.Any(stage => stage.Producer == "backup-worker");
            var recoveredOutcome = ToOutcome(workflow.Status);
            // A reservation that never reached its worker left nothing in doubt, whatever ended it.
            if (runtimeSchedule is not null && admission.RuntimeTicket is not null)
                await runtimeSchedule.FinishAsync(admission, null,
                    recoveredOutcome is ProcessOutcome.Succeeded or ProcessOutcome.NoChange ? ScheduleDisposition.Consume
                    : recoveredOutcome is ProcessOutcome.Skipped or ProcessOutcome.Busy || !workerStarted ? ScheduleDisposition.Preserve
                    : ScheduleDisposition.CompletionUnknown, cancellationToken);
            if (runtimeSchedule is not null)
                await runtimeSchedule.FinishFallbackAsync(admission, workerStarted, recoveredOutcome, now, cancellationToken);
            await schedulerDatabase.FinishBackupTickAsync(
                admission,
                workerStarted,
                workflow.RunIndex,
                recoveredOutcome,
                now,
                CancellationToken.None);
            return new BackupTickResult(
                true,
                workflow.RunIndex,
                admission.Target,
                null,
                null,
                recoveredOutcome);
        }

        WorkerInvocation? backup = null;
        WorkerInvocation? maintenance = null;
        var outcome = ProcessOutcome.Failed;
        var dispatched = false;
        try
        {
            // 독립 점검기가 저장소 잠금을 쥐고 있으면 먼저 양보를 요청합니다.
            try
            {
                await MaintenanceLaneSignal.RequestYieldForRunningLanesAsync(
                    admission.RepositoryPath, cancellationToken);
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                // 신호 전달 실패만으로 예정된 백업 자체를 중단하지 않습니다.
            }
            // A stop/interval change can arrive while repository admission or yield is awaited.
            var currentSelection = runtimeSchedule is null ? new RuntimeAdmissionSelection(false, null)
                : await runtimeSchedule.PrepareAsync(DateTimeOffset.UtcNow, preparationLead ?? TimeSpan.Zero, cancellationToken);
            // Rechecked at the tick's own time (not the controller's clock read above), as when admitted.
            var currentAdmission = currentSelection.Enabled ? currentSelection.Admission
                : await schedulerDatabase.PrepareBackupTickAsync(now, cancellationToken, preparationLead);
            bool valid = currentAdmission?.AdmissionId == admission.AdmissionId
                && (currentSelection.Enabled && !RuntimeScheduleController.IsFallback(admission)
                    || (isTargetActive is null || isTargetActive(admission.Target)) && !WaitsForNewCharacter(admission));
            if (!valid) backup = new WorkerInvocation(false, ProcessOutcome.Skipped,
                "automatic-reservation-obsolete", ScheduleDisposition.Preserve);
            else if (admission.RuntimeTicket is not null)
            {
                var guarded = guardedBackupRunner ?? throw new InvalidOperationException("Guarded worker dispatch is unavailable.");
                dispatched = true;
                backup = await guarded(currentAdmission!, workflow.RunIndex, cancellationToken);
            }
            else
            {
                dispatched = true;
                backup = await backupRunner(admission.RepositoryPath, admission.Target, workflow.RunIndex,
                    admission.Kind == BackupAdmissionKind.Periodic ? admission.ScheduledUtc : null, cancellationToken);
            }
            if (backup.Outcome is ProcessOutcome.Succeeded or ProcessOutcome.NoChange)
            {
                var bound = await repository.ReadWorkflowAsync(
                    workflow.RunIndex, cancellationToken);
                if (bound.SourceId is null)
                {
                    throw new InvalidDataException(
                        "The backup worker did not bind the workflow to a repository source.");
                }
                Exception? maintenanceFailure = null;
                try
                {
                    maintenance = await maintenanceRunner(
                        admission.RepositoryPath,
                        admission.Target,
                        bound.SourceId.Value,
                        workflow.RunIndex,
                        cancellationToken);
                }
                catch (Exception exception)
                {
                    maintenanceFailure = exception;
                    maintenance = new WorkerInvocation(
                        false, ProcessOutcome.Failed,
                        $"maintenance-dispatch-{exception.GetType().Name}");
                }
                if (maintenance?.Outcome == ProcessOutcome.Failed)
                {
                    await BestEffortProcessTelemetry.TryRecordAsync(
                        schedulerDatabase.DatabasePath,
                        "backup-scheduler",
                        workflow.RunIndex,
                        "maintenance.dispatch.failed",
                        maintenanceFailure is null
                            ? System.Text.Json.JsonSerializer.Serialize(new
                            {
                                failureCode = maintenance.FailureCode,
                                phase = "maintenance-dispatch",
                                saveId = admission.Target.SaveId,
                            })
                            : FailureTelemetry.FromException(
                                maintenance.FailureCode!, maintenanceFailure,
                                phase: "maintenance-dispatch",
                                operation: "backup-schedule",
                                saveId: admission.Target.SaveId),
                        telemetryConfigurationPath);
                }
                // 레인의 자식 작업은 별도 프로세스입니다. 시작 실패도 이미 완료된 백업의 결과를 바꾸지 않습니다.
                outcome = backup.Outcome;
            }
            else
            {
                outcome = backup.Outcome;
            }

            await repository.CompleteWorkflowAsync(
                workflow.RunIndex,
                "backup-scheduler",
                ToWorkflowStatus(outcome),
                backup.FailureCode,
                CancellationToken.None);
            await TryRecordTelemetryAsync(
                workflow.RunIndex, admission, outcome, backup, maintenance);
            return new BackupTickResult(
                true,
                workflow.RunIndex,
                admission.Target,
                backup,
                maintenance,
                outcome);
        }
        catch (OperationCanceledException)
        {
            outcome = ProcessOutcome.Cancelled;
            await TryCompleteAsync(
                repository, workflow.RunIndex, WorkflowStatus.Cancelled, "cancelled");
            throw;
        }
        catch (Exception exception)
        {
            outcome = ProcessOutcome.Failed;
            await TryCompleteAsync(
                repository,
                workflow.RunIndex,
                WorkflowStatus.Failed,
                "scheduler-pipeline-failed");
            await BestEffortProcessTelemetry.TryRecordAsync(
                schedulerDatabase.DatabasePath,
                "backup-scheduler",
                workflow.RunIndex,
                "tick.failed",
                FailureTelemetry.FromException(
                    "scheduler-pipeline-failed", exception,
                    phase: "schedule",
                    operation: "backup-schedule",
                    saveId: admission.Target.SaveId),
                telemetryConfigurationPath);
            throw;
        }
        finally
        {
            busyRetryAt = outcome == ProcessOutcome.Busy ? now + BusyRetry : DateTimeOffset.MinValue;
            // An error before the worker was dispatched (for example a busy scheduler database)
            // means no save was requested: keep the slot instead of treating its outcome as unknown.
            if (runtimeSchedule is not null && admission.RuntimeTicket is not null)
                await runtimeSchedule.FinishAsync(admission, backup,
                    dispatched ? ScheduleDisposition.CompletionUnknown : ScheduleDisposition.Preserve,
                    CancellationToken.None);
            if (runtimeSchedule is not null)
                await runtimeSchedule.FinishFallbackAsync(admission, backup?.Started == true, outcome, now, CancellationToken.None);
            await schedulerDatabase.FinishBackupTickAsync(
                admission,
                backup?.Started == true,
                workflow.RunIndex,
                outcome,
                now,
                CancellationToken.None);
        }
    }

    // Clock-time scheduling has no hold of its own: keep a periodic backup due while the played
    // character is dead. The backup made at the moment of death is a separate, one-time request.
    private bool WaitsForNewCharacter(BackupTickAdmission admission) =>
        admission.Kind == BackupAdmissionKind.Periodic && runtimeSchedule?.Observation is { IsCharacterDead: true } observation
        && StringComparer.OrdinalIgnoreCase.Equals(observation.Snapshot!.SavePath, admission.Target.SourcePath);

    private async Task TryRecordTelemetryAsync(
        long runIndex,
        BackupTickAdmission admission,
        ProcessOutcome outcome,
        WorkerInvocation? backup,
        WorkerInvocation? maintenance)
    {
        await BestEffortProcessTelemetry.TryRecordAsync(
            schedulerDatabase.DatabasePath,
            "backup-scheduler",
            runIndex,
            "tick.completed",
            System.Text.Json.JsonSerializer.Serialize(new
            {
                outcome = outcome.ToString(),
                admission.Kind,
                admission.Target.SaveId,
                failureCode = backup?.FailureCode,
                failureOrigin = backup?.Outcome == ProcessOutcome.Failed
                    ? "backup-worker" : null,
                maintenanceOutcome = maintenance?.Outcome.ToString(),
                maintenanceFailureCode = maintenance?.FailureCode,
            }),
            telemetryConfigurationPath);
    }

    private static WorkflowStatus ToWorkflowStatus(ProcessOutcome outcome) => outcome switch
    {
        ProcessOutcome.Succeeded => WorkflowStatus.Succeeded,
        ProcessOutcome.NoChange => WorkflowStatus.NoChange,
        ProcessOutcome.Skipped => WorkflowStatus.Skipped,
        ProcessOutcome.Busy => WorkflowStatus.Busy,
        ProcessOutcome.Degraded => WorkflowStatus.Degraded,
        ProcessOutcome.Cancelled => WorkflowStatus.Cancelled,
        _ => WorkflowStatus.Failed,
    };

    private static ProcessOutcome ToOutcome(WorkflowStatus status) => status switch
    {
        WorkflowStatus.Succeeded => ProcessOutcome.Succeeded,
        WorkflowStatus.NoChange => ProcessOutcome.NoChange,
        WorkflowStatus.Skipped => ProcessOutcome.Skipped,
        WorkflowStatus.Busy => ProcessOutcome.Busy,
        WorkflowStatus.Degraded => ProcessOutcome.Degraded,
        WorkflowStatus.Cancelled or WorkflowStatus.Abandoned => ProcessOutcome.Cancelled,
        _ => ProcessOutcome.Failed,
    };

    private static async Task TryCompleteAsync(
        RepositoryDatabase repository,
        long runIndex,
        WorkflowStatus status,
        string code)
    {
        try
        {
            await repository.CompleteWorkflowAsync(
                runIndex,
                "backup-scheduler",
                status,
                code,
                CancellationToken.None);
        }
        catch (InvalidOperationException)
        {
        }
    }
}
