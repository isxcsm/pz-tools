using DiagnosticsProcess = System.Diagnostics.Process;
using ProcessStartInfo = System.Diagnostics.ProcessStartInfo;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class SchedulerTests
{
    [Theory]
    [InlineData(20)]
    [InlineData(3600)]
    public async Task AppSessionRestart_StartsFullIntervalAndInvalidatesOldPeriodicAdmission(int elapsedSeconds)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("scheduler.db");
        var database = await SchedulerDatabase.CreateOrOpenAsync(path);
        var now = DateTimeOffset.UtcNow;
        var target = Target(temp, "A");
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(1), now);
        await database.EnqueueTargetCommandAsync(Command("activate", BackupTargetCommandKind.ActivateTarget, target));
        Assert.Null(await database.PrepareBackupTickAsync(now));
        var previous = await database.ReadBackupStateIfChangedAsync(-1);
        var oldAdmission = new BackupTickAdmission(previous.PeriodicAdmissionId,
            BackupAdmissionKind.Periodic, target, previous.RepositoryPath,
            previous.NextDueUtc, previous.Generation, null);

        database = await SchedulerDatabase.CreateOrOpenAsync(path);
        var restartedAt = now.AddSeconds(elapsedSeconds);
        await database.RestartPeriodicScheduleAsync(restartedAt);
        var state = await database.ReadBackupStateIfChangedAsync(previous.SchedulerRevision);
        Assert.True(state.Modified);
        Assert.Equal(target, state.CurrentTarget);
        Assert.Equal(previous.Generation + 1, state.Generation);
        Assert.NotEqual(previous.PeriodicAdmissionId, state.PeriodicAdmissionId);
        Assert.Equal(restartedAt.AddMinutes(1), state.NextDueUtc);
        var lead = TimeSpan.FromSeconds(8);
        Assert.Null(await database.PrepareBackupTickAsync(restartedAt, preparationLead: lead));
        Assert.Null(await database.PrepareBackupTickAsync(restartedAt.AddSeconds(51), preparationLead: lead));

        await database.FinishBackupTickAsync(oldAdmission, true, 1, ProcessOutcome.Succeeded, restartedAt);
        Assert.Equal(state.NextDueUtc, (await database.ReadBackupStateIfChangedAsync(-1)).NextDueUtc);
        Assert.Equal(state.NextDueUtc,
            (await database.PrepareBackupTickAsync(restartedAt.AddSeconds(52), preparationLead: lead))!.ScheduledUtc);
    }

    [Fact]
    public async Task AppSessionRestart_DoesNotEnableDisabledAutomaticBackups()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        await database.ConfigureBackupAsync(temp.GetPath("repository"), false, TimeSpan.FromMinutes(1), now);
        await database.EnqueueTargetCommandAsync(Command("activate", BackupTargetCommandKind.ActivateTarget, Target(temp, "A")));
        Assert.Null(await database.PrepareBackupTickAsync(now));
        var before = await database.ReadBackupStateIfChangedAsync(-1);
        await database.RestartPeriodicScheduleAsync(now.AddHours(1));
        Assert.Equal(before, await database.ReadBackupStateIfChangedAsync(-1));
        Assert.Null(await database.PrepareBackupTickAsync(now.AddHours(1)));
    }

    [Fact]
    public async Task AppSessionRestart_DoesNotRestoreAnExitBackup()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(1), now);
        await database.EnqueueTargetCommandAsync(Command("final", BackupTargetCommandKind.FinalizeTarget, Target(temp, "A")));
        var admission = await database.PrepareBackupTickAsync(now);
        await database.RestartPeriodicScheduleAsync(now.AddHours(1));
        Assert.Null(admission);
        Assert.Null(await database.PrepareBackupTickAsync(now.AddHours(1)));
        Assert.Equal(0, (await database.ReadBackupStateIfChangedAsync(-1)).PendingRuns);
    }

    [Fact]
    public async Task PreparationLeadAdmitsEarlyWithoutMovingTheScheduledSaveTime()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(1), now);
        await database.EnqueueTargetCommandAsync(Command("activate", BackupTargetCommandKind.ActivateTarget, Target(temp, "A")));
        var lead = TimeSpan.FromSeconds(8);
        Assert.Null(await database.PrepareBackupTickAsync(now, preparationLead: lead));
        Assert.Null(await database.PrepareBackupTickAsync(now.AddSeconds(51), preparationLead: lead));
        var admission = await database.PrepareBackupTickAsync(now.AddSeconds(52), preparationLead: lead);
        Assert.Equal(now.AddMinutes(1), admission!.ScheduledUtc);
        Assert.Equal(admission.ScheduledUtc, (await database.ReadBackupStateIfChangedAsync(-1)).NextDueUtc);
        await database.ConfigureBackupAsync(temp.GetPath("repository"), false, TimeSpan.FromMinutes(1), now);
        Assert.Null(await database.PrepareBackupTickAsync(now.AddMinutes(1), preparationLead: lead));
    }

    [Fact]
    public async Task GameProcessExitWatcher_WakesWhenWatchedProcessExits()
    {
        using var watcher = new GameProcessExitWatcher();
        var process = DiagnosticsProcess.Start(new ProcessStartInfo(
            "cmd.exe", "/c ping -n 2 127.0.0.1 >nul")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        })!;
        watcher.Watch(process);

        Assert.True(await watcher.WaitAsync(TimeSpan.FromSeconds(5), CancellationToken.None));
    }

    [Fact]
    public async Task ForcedStateChecks_DoNotPostponeNextPeriodicCheck()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var runs = 0;
        var scheduler = new StateScheduler(
            database,
            TimeSpan.FromSeconds(3),
            _ => Task.FromResult((long)++runs),
            (_, _) => Task.FromResult(new WorkerInvocation(true, ProcessOutcome.Succeeded)));

        Assert.True((await scheduler.TickAsync(now)).Due);
        Assert.True((await scheduler.TickAsync(now.AddSeconds(1), force: true)).Due);
        Assert.False((await scheduler.TickAsync(now.AddSeconds(1))).Due);
        Assert.True((await scheduler.TickAsync(now.AddSeconds(3))).Due);
        Assert.Equal(3, runs);
    }

    [Fact]
    public async Task StateIntervalChange_AppliesOnFirstTickAfterRestart()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        Assert.True(await database.PrepareStateTickAsync(TimeSpan.FromSeconds(10), now));
        await database.AdvanceStateDueAsync(TimeSpan.FromSeconds(10), now);

        Assert.True(await database.PrepareStateTickAsync(TimeSpan.FromSeconds(3),
            now.AddSeconds(1)));
    }

    [Fact]
    public async Task ActivateTarget_WaitsForConfiguredIntervalBeforeFirstPeriodicBackup()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var target = Target(temp, "A");
        await database.ConfigureBackupAsync(
            temp.GetPath("repository"), true, TimeSpan.FromMinutes(5), now);
        var configured = await database.ReadBackupStateIfChangedAsync(-1);

        await database.EnqueueTargetCommandAsync(Command("activate-a", BackupTargetCommandKind.ActivateTarget, target));
        Assert.Null(await database.PrepareBackupTickAsync(now));
        Assert.Null(await database.PrepareBackupTickAsync(now.AddMinutes(5).AddTicks(-1)));
        var admission = await database.PrepareBackupTickAsync(now.AddMinutes(5));

        Assert.NotNull(admission);
        Assert.Equal(BackupAdmissionKind.Periodic, admission.Kind);
        Assert.Equal(target, admission.Target);
        var state = await database.ReadBackupStateIfChangedAsync(configured.SchedulerRevision);
        Assert.True(state.Modified);
        Assert.Equal(SchedulerMode.Continuous, state.Mode);
        Assert.Equal(target, state.CurrentTarget);
        Assert.Equal(now.AddMinutes(5), state.NextDueUtc);
    }

    [Fact]
    public async Task DisabledAutomaticBackup_TracksTargetWithoutAdmittingWork()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var target = Target(temp, "A");
        await database.ConfigureBackupAsync(
            temp.GetPath("repository"), false, TimeSpan.FromMinutes(5), now);
        await database.EnqueueTargetCommandAsync(Command("activate-a", BackupTargetCommandKind.ActivateTarget, target));

        Assert.Null(await database.PrepareBackupTickAsync(now));
        var state = await database.ReadBackupStateIfChangedAsync(-1);
        Assert.Equal(target, state.CurrentTarget);
        // Activity and the automation switch are separate: re-enabling should not
        // need a new game transition, but disabled automation must never run or count down.
        Assert.Equal(SchedulerMode.Continuous, state.Mode);
        Assert.False(state.AutomaticEnabled);
        Assert.Null(await database.PrepareBackupTickAsync(now.AddHours(1)));
        var views = new PzTools.Projections.RevisionedViewStore();
        await new PzTools.Projections.SchedulerProjector(database, views).ProjectOnceAsync();
        Assert.Null(views.ReadIfChanged<PzTools.Projections.ScheduleStatusView>(
            PzTools.Projections.ViewKey.ScheduleStatus, 0).Snapshot!.NextDueUtc);
    }

    [Fact]
    public async Task ChangingIntervalWhilePlaying_ReschedulesWithoutImmediateBackup()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var repository = temp.GetPath("repository");
        var target = Target(temp, "A");
        await database.ConfigureBackupAsync(repository, true, TimeSpan.FromMinutes(5), now);
        await database.EnqueueTargetCommandAsync(Command(
            "activate-a", BackupTargetCommandKind.ActivateTarget, target));
        Assert.Null(await database.PrepareBackupTickAsync(now));

        var changedAt = now.AddMinutes(1);
        await database.ConfigureBackupAsync(repository, true, TimeSpan.FromMinutes(10), changedAt);

        Assert.Null(await database.PrepareBackupTickAsync(changedAt));
        Assert.Null(await database.PrepareBackupTickAsync(changedAt.AddMinutes(10).AddTicks(-1)));
        Assert.Equal(changedAt.AddMinutes(10),
            (await database.PrepareBackupTickAsync(changedAt.AddMinutes(10)))?.ScheduledUtc);
    }

    [Fact]
    public async Task ExitCommand_IsAStop_NotARetryableFinalBackup()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var target = Target(temp, "A");
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(5), now);
        await database.EnqueueTargetCommandAsync(Command("active", BackupTargetCommandKind.ActivateTarget, target));
        await database.PrepareBackupTickAsync(now);
        await database.EnqueueTargetCommandAsync(Command("final", BackupTargetCommandKind.FinalizeTarget, target));
        Assert.Null(await database.PrepareBackupTickAsync(now));
        Assert.Null(await database.PrepareBackupTickAsync(now.AddDays(1)));
        var state = await database.ReadBackupStateIfChangedAsync(-1);
        Assert.Null(state.CurrentTarget);
        Assert.Equal(0, state.PendingRuns);
        Assert.Equal(SchedulerMode.Paused, state.Mode);
    }

    [Fact]
    public async Task FinalForPreviousSave_DoesNotReplaceNewActiveTarget()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var firstTarget = Target(temp, "A");
        var secondTarget = Target(temp, "B");
        await database.ConfigureBackupAsync(
            temp.GetPath("repository"), true, TimeSpan.FromMinutes(5), now);
        await database.EnqueueTargetCommandAsync(Command("activate-a", BackupTargetCommandKind.ActivateTarget, firstTarget));
        _ = await database.PrepareBackupTickAsync(now);
        await database.EnqueueTargetCommandAsync(Command("final-a", BackupTargetCommandKind.FinalizeTarget, firstTarget));
        await database.EnqueueTargetCommandAsync(Command("activate-b", BackupTargetCommandKind.ActivateTarget, secondTarget));

        Assert.Null(await database.PrepareBackupTickAsync(now));
        // A delayed stop for A must not clear a newly activated B.
        await database.EnqueueTargetCommandAsync(Command("late-final-a", BackupTargetCommandKind.FinalizeTarget, firstTarget));
        Assert.Null(await database.PrepareBackupTickAsync(now));
        var state = await database.ReadBackupStateIfChangedAsync(-1);
        Assert.Equal(secondTarget, state.CurrentTarget);
        Assert.Equal(SchedulerMode.Continuous, state.Mode);
        Assert.Null(await database.PrepareBackupTickAsync(now));
        Assert.NotNull(await database.PrepareBackupTickAsync(now.AddMinutes(5)));
    }

    [Fact]
    public async Task AmbiguousActiveSet_SuspendsAdmissionUntilSingleTargetIsResolved()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var first = Target(temp, "A");
        var second = Target(temp, "B");
        await database.ConfigureBackupAsync(
            temp.GetPath("repository"), true, TimeSpan.FromMinutes(5), now);
        await database.EnqueueTargetCommandAsync(Command(
            "activate-a", BackupTargetCommandKind.ActivateTarget, first));
        await database.EnqueueTargetCommandAsync(Command(
            "activate-b", BackupTargetCommandKind.ActivateTarget, second));
        await database.EnqueueTargetCommandAsync(Command(
            "ambiguous", BackupTargetCommandKind.SuspendAmbiguous, first));

        Assert.Null(await database.PrepareBackupTickAsync(now));
        var suspended = await database.ReadBackupStateIfChangedAsync(-1);
        Assert.Equal(SchedulerMode.Ambiguous, suspended.Mode);

        await database.EnqueueTargetCommandAsync(Command(
            "resolved-a", BackupTargetCommandKind.ActivateTarget, first));
        Assert.Null(await database.PrepareBackupTickAsync(now));
        var admission = await database.PrepareBackupTickAsync(now.AddMinutes(5));
        Assert.NotNull(admission);
        Assert.Equal(first, admission.Target);
    }

    [Fact]
    public async Task StateOutboxRelay_IsIdempotentAndCarriesDynamicTarget()
    {
        using var temp = new TempDirectory();
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await scheduler.ConfigureBackupAsync(
            temp.GetPath("repository"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow);
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = Path.GetFullPath(temp.GetPath("save")).ToUpperInvariant();
        var reactor = new StateReactor();
        await ApplyAsync(ActivityState.Active, 1);
        await ApplyAsync(ActivityState.Active, 2);

        var relay = new StateOutboxRelay();
        Assert.Equal(1, await relay.RelayAsync(state, scheduler));
        Assert.Equal(0, await relay.RelayAsync(state, scheduler));
        var activatedAt = DateTimeOffset.UtcNow;
        Assert.Null(await scheduler.PrepareBackupTickAsync(activatedAt));
        var admission = (await scheduler.PrepareBackupTickAsync(
            activatedAt.AddMinutes(5)))!;
        Assert.Equal("Sandbox/Save", admission.Target.SaveId);
        Assert.Equal(path, admission.Target.SourcePath);

        async Task ApplyAsync(ActivityState activity, long runIndex)
        {
            var now = DateTimeOffset.UtcNow;
            await state.WritePendingBatchAsync(new CollectionBatch(
                Guid.NewGuid().ToString("D"), runIndex, now, now, 1, true,
                [new SaveObservation(path, "Sandbox", "Save", true, false, activity,
                    CharacterState.Alive, LaneStatus.Succeeded, LaneStatus.Succeeded)]));
            await reactor.RunAsync(state);
        }
    }

    [Fact]
    public async Task StateReactor_MultipleActiveSavesProducesAmbiguousSchedulerState()
    {
        using var temp = new TempDirectory();
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await scheduler.ConfigureBackupAsync(
            temp.GetPath("repository"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow);
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var saves = new[]
        {
            new SaveObservation(Path.GetFullPath(temp.GetPath("A")), "Sandbox", "A", true,
                false, ActivityState.Active, CharacterState.Alive,
                LaneStatus.Succeeded, LaneStatus.Succeeded),
            new SaveObservation(Path.GetFullPath(temp.GetPath("B")), "Sandbox", "B", true,
                false, ActivityState.Active, CharacterState.Alive,
                LaneStatus.Succeeded, LaneStatus.Succeeded),
        };
        for (var run = 1; run <= 2; run++)
        {
            var now = DateTimeOffset.UtcNow;
            await state.WritePendingBatchAsync(new CollectionBatch(
                Guid.NewGuid().ToString("D"), run, now, now, 1, true, saves));
            await new StateReactor().RunAsync(state);
        }

        await new StateOutboxRelay().RelayAsync(state, scheduler);

        Assert.Null(await scheduler.PrepareBackupTickAsync(DateTimeOffset.UtcNow));
        Assert.Equal(SchedulerMode.Ambiguous,
            (await scheduler.ReadBackupStateIfChangedAsync(-1)).Mode);
        Assert.Equal(GameState.Ambiguous,
            (await state.ReadCurrentStateIfChangedAsync(-1)).Game);
    }

    [Fact]
    public async Task BackupScheduler_RunsBackupThenMaintenanceForDynamicTarget()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var target = new BackupTarget("Sandbox/Save", "Sandbox/Save", sourcePath);
        await database.ConfigureBackupAsync(repositoryPath, true, TimeSpan.FromMinutes(5), now);
        await database.EnqueueTargetCommandAsync(Command("activate", BackupTargetCommandKind.ActivateTarget, target));
        var stages = new List<string>();
        var scheduler = new BackupScheduler(
            database,
            _ => Task.FromResult(10_000L),
            async (repositoryDirectory, scheduledTarget, runIndex, scheduledUtc, token) =>
            {
                stages.Add("backup");
                var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryDirectory, token);
                await using var lease = RepositoryWriterLease.Acquire(repositoryDirectory);
                var source = await repository.AddOrGetSourceAsync(
                    lease, scheduledTarget.SourceKey, scheduledTarget.SourcePath, token);
                var run = await repository.StartRunAsync(lease, source.SourceId, runIndex, token);
                await repository.CompleteRunAsync(
                    lease, run.RunIndex, RunStatus.Succeeded, cancellationToken: token);
                return new WorkerInvocation(true, ProcessOutcome.NoChange);
            },
            (_, scheduledTarget, sourceId, _, _) =>
            {
                stages.Add($"maintenance:{scheduledTarget.SaveId}:{sourceId}");
                return Task.FromException<WorkerInvocation>(new IOException("launch failed"));
            });

        Assert.False((await scheduler.TickAsync(now)).Due);
        var result = await scheduler.TickAsync(now.AddMinutes(5));

        Assert.Equal(ProcessOutcome.NoChange, result.Outcome);
        Assert.Equal(ProcessOutcome.Failed, result.Maintenance?.Outcome);
        Assert.Equal("maintenance-dispatch-IOException", result.Maintenance?.FailureCode);
        Assert.Equal(target, result.Target);
        Assert.Equal("backup", stages[0]);
        Assert.StartsWith("maintenance:Sandbox/Save:", stages[1]);
    }

    [Fact]
    public async Task BackupScheduler_RetriesPeriodicBackupWhenRepositoryIsBusy()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        var target = new BackupTarget("Sandbox/Save", "Sandbox/Save", sourcePath);
        await database.ConfigureBackupAsync(repositoryPath, true, TimeSpan.FromMinutes(5), now);
        await database.EnqueueTargetCommandAsync(Command("activate", BackupTargetCommandKind.ActivateTarget, target));
        var attempts = 0;
        var scheduler = new BackupScheduler(
            database,
            _ => Task.FromResult(10_000L + ++attempts),
            async (repositoryDirectory, scheduledTarget, runIndex, scheduledUtc, token) =>
            {
                if (attempts == 1)
                    return new WorkerInvocation(false, ProcessOutcome.Busy);
                var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryDirectory, token);
                await using var lease = RepositoryWriterLease.Acquire(repositoryDirectory);
                var source = await repository.AddOrGetSourceAsync(
                    lease, scheduledTarget.SourceKey, scheduledTarget.SourcePath, token);
                var run = await repository.StartRunAsync(lease, source.SourceId, runIndex, token);
                await repository.CompleteRunAsync(
                    lease, run.RunIndex, RunStatus.Succeeded, cancellationToken: token);
                return new WorkerInvocation(true, ProcessOutcome.NoChange);
            },
            (_, _, _, _, _) => Task.FromResult(new WorkerInvocation(true, ProcessOutcome.Skipped)));

        Assert.False((await scheduler.TickAsync(now)).Due);
        var due = now.AddMinutes(5);
        Assert.Equal(ProcessOutcome.Busy, (await scheduler.TickAsync(due)).Outcome);
        Assert.Equal(due, (await database.ReadBackupStateIfChangedAsync(-1)).NextDueUtc);

        var retry = await scheduler.TickAsync(due.AddSeconds(1));
        Assert.True(retry.Due);
        Assert.Equal(ProcessOutcome.NoChange, retry.Outcome);
        Assert.Equal(2, attempts);
        Assert.Equal(now.AddMinutes(10), (await database.ReadBackupStateIfChangedAsync(-1)).NextDueUtc);
    }

    [Fact]
    public async Task MaintenanceLaneMutex_DoesNotBlockAnotherLane()
    {
        using var temp = new TempDirectory();
        var repository = temp.GetPath("repository");
        var mutexName = MaintenanceLaneSignal.MutexName(repository, "RevisionReclamation");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var holder = NamedMutexRunner.TryRunAsync(mutexName, async _ =>
        {
            entered.SetResult();
            await release.Task;
            return true;
        });
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.True(await MaintenanceLaneSignal.IsRunningAsync(repository, "RevisionReclamation"));
            Assert.False(await MaintenanceLaneSignal.IsRunningAsync(repository, "ArtifactCleanup"));
        }
        finally
        {
            release.SetResult();
            await holder;
        }
    }

    [Fact]
    public async Task DueBackup_SignalsRunningMaintenanceToYield()
    {
        using var temp = new TempDirectory();
        var repository = temp.GetPath("repository");
        await MaintenanceLaneSignal.RequestYieldForRunningLanesAsync(repository);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var holder = NamedMutexRunner.TryRunAsync(
            MaintenanceLaneSignal.MutexName(repository, "RevisionReclamation"), async _ =>
            {
                using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                using var watch = MaintenanceLaneSignal.WatchForYield(
                    repository, "RevisionReclamation", cancellation);
                entered.SetResult();
                try { await Task.Delay(Timeout.InfiniteTimeSpan, cancellation.Token); }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
                return cancellation.IsCancellationRequested;
            });

        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await MaintenanceLaneSignal.RequestYieldForRunningLanesAsync(repository);
        Assert.True((await holder.WaitAsync(TimeSpan.FromSeconds(5))).Value);
    }

    [Fact]
    public async Task InvalidIntervalsAreRejectedBeforeScheduling()
    {
        using var temp = new TempDirectory();
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() =>
            database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.Zero, now));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() =>
            database.PrepareStateTickAsync(TimeSpan.Zero, now));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() =>
            database.PrepareStateTickAsync(TimeSpan.FromMilliseconds(500), now));
    }

    private static BackupTarget Target(TempDirectory temp, string name) =>
        new($"Sandbox/{name}", $"Sandbox/{name}", temp.GetPath(name));

    private static BackupTargetCommand Command(
        string key,
        BackupTargetCommandKind kind,
        BackupTarget target) => new(key, kind, target);
}
