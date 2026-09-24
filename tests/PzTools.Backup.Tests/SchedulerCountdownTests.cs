using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Projections;
using PzTools.Scheduling;

namespace PzTools.Backup.Tests;

public sealed class SchedulerCountdownTests
{
    [Fact]
    public async Task PreparingWorkerKeepsCurrentCountdownUntilScheduledTime()
    {
        using var fixture = await Fixture.CreateAsync();
        var views = new RevisionedViewStore();
        var clock = new TestClock(fixture.Admission.ScheduledUtc.AddSeconds(-8));
        var projector = new SchedulerProjector(fixture.Database, views, fixture.Repository, clock);
        await fixture.StartWorkerAsync();
        await projector.ProjectOnceAsync();
        var before = views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!;
        Assert.Equal(fixture.Admission.ScheduledUtc, before.NextDueUtc);
        Assert.False(before.PeriodicBackupInProgress);
        clock.Now = fixture.Admission.ScheduledUtc;
        await projector.ProjectOnceAsync();
        var after = views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!;
        Assert.Equal(fixture.Admission.ScheduledUtc.AddMinutes(5), after.NextDueUtc);
        Assert.True(after.PeriodicBackupInProgress);
    }

    private sealed class TestClock(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public async Task CountdownAdvancesWhenWorkerStartsWithoutWaitingForSchedulerCompletion()
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.Projector.ProjectOnceAsync();
        var before = fixture.View;
        Assert.Equal(fixture.Admission.ScheduledUtc, before.Snapshot!.NextDueUtc);
        await fixture.StartWorkerAsync();

        await fixture.Projector.ProjectOnceAsync();
        var running = fixture.View;
        Assert.Equal(before.Snapshot.SchedulerRevision, running.Snapshot!.SchedulerRevision);
        Assert.True(running.ViewRevision > before.ViewRevision);
        Assert.True(running.Snapshot.PeriodicBackupInProgress);
        Assert.Equal(fixture.Admission.ScheduledUtc.AddMinutes(5), running.Snapshot.NextDueUtc);
        // This is display-only: recovery and the scheduler still own the original admission.
        Assert.Equal(fixture.Admission.ScheduledUtc,
            (await fixture.Database.ReadBackupStateIfChangedAsync(-1)).NextDueUtc);
        await fixture.Projector.ProjectOnceAsync();
        Assert.Equal(running.ViewRevision, fixture.View.ViewRevision);

        await fixture.Repository.CompleteWorkflowAsync(100, "backup-scheduler", WorkflowStatus.Succeeded);
        await fixture.Database.FinishBackupTickAsync(fixture.Admission, true, 100,
            ProcessOutcome.Succeeded, fixture.Admission.ScheduledUtc);
        await fixture.Projector.ProjectOnceAsync();
        Assert.Equal(running.Snapshot.NextDueUtc, fixture.View.Snapshot!.NextDueUtc);
        Assert.False(fixture.View.Snapshot.PeriodicBackupInProgress);
    }

    [Fact]
    public async Task BusyAdmissionWithoutWorkerDoesNotPretendTheNextIntervalHasStarted()
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.ReserveAsync();
        await fixture.Projector.ProjectOnceAsync();
        Assert.Equal(fixture.Admission.ScheduledUtc, fixture.View.Snapshot!.NextDueUtc);
        Assert.False(fixture.View.Snapshot.PeriodicBackupInProgress);
        await fixture.Repository.CompleteWorkflowAsync(100, "backup-scheduler", WorkflowStatus.Busy);
        await fixture.Database.FinishBackupTickAsync(fixture.Admission, false, 100,
            ProcessOutcome.Busy, fixture.Admission.ScheduledUtc);
        await fixture.Projector.ProjectOnceAsync();
        Assert.Equal(fixture.Admission.ScheduledUtc, fixture.View.Snapshot!.NextDueUtc);
        Assert.NotEqual(fixture.Admission.AdmissionId,
            (await fixture.Database.PrepareBackupTickAsync(fixture.Admission.ScheduledUtc))!.AdmissionId);
    }

    [Theory]
    [InlineData("manual-backup:example")]
    [InlineData("backup-scheduler:pending:final-example:0")]
    public async Task OtherBackupKindsDoNotResetPeriodicCountdown(string unrelatedAdmission)
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.Repository.ReserveWorkflowAsync("backup", null, "backup-worker", unrelatedAdmission, 100);
        await fixture.Repository.AttachWorkflowStageAsync(100, "backup-worker");
        await fixture.Projector.ProjectOnceAsync();
        Assert.Equal(fixture.Admission.ScheduledUtc, fixture.View.Snapshot!.NextDueUtc);
        Assert.False(fixture.View.Snapshot.PeriodicBackupInProgress);
    }

    [Fact]
    public async Task NewIntervalAndDisabledStateReplaceTheRunningCountdown()
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.StartWorkerAsync();
        await fixture.Projector.ProjectOnceAsync();
        var changedAt = DateTimeOffset.UtcNow;
        await fixture.Database.ConfigureBackupAsync(fixture.Repository.RepositoryPath, true,
            TimeSpan.FromMinutes(10), changedAt);
        await fixture.Projector.ProjectOnceAsync();
        Assert.Equal(changedAt.AddMinutes(10), fixture.View.Snapshot!.NextDueUtc);
        Assert.False(fixture.View.Snapshot.PeriodicBackupInProgress);
        await fixture.Database.ConfigureBackupAsync(fixture.Repository.RepositoryPath, false,
            TimeSpan.FromMinutes(10), changedAt);
        await fixture.Projector.ProjectOnceAsync();
        Assert.False(fixture.View.Snapshot!.AutomaticEnabled);
        Assert.False(fixture.View.Snapshot.PeriodicBackupInProgress);

        await fixture.Repository.CompleteWorkflowAsync(100, "backup-scheduler", WorkflowStatus.Succeeded);
        await fixture.Database.FinishBackupTickAsync(fixture.Admission, true, 100,
            ProcessOutcome.Succeeded, changedAt);
        await fixture.Projector.ProjectOnceAsync();
        Assert.False(fixture.View.Snapshot!.AutomaticEnabled);
        Assert.False(fixture.View.Snapshot.PeriodicBackupInProgress);
        Assert.Null(await fixture.Database.PrepareBackupTickAsync(changedAt.AddHours(1)));
    }

    [Fact]
    public void NextSlotKeepsCadenceAndSkipsAlreadyMissedSlots()
    {
        var due = DateTimeOffset.UtcNow;
        Assert.Equal(due.AddMinutes(5), BackupScheduleTiming.NextDue(due, TimeSpan.FromMinutes(5), due));
        Assert.Equal(due.AddMinutes(15), BackupScheduleTiming.NextDue(due, TimeSpan.FromMinutes(5), due.AddMinutes(12)));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(10)]
    public async Task FinishingPreviousBackupCannotOverwriteTheNewIntervalDueTime(int minutes)
    {
        using var fixture = await Fixture.CreateAsync();
        await fixture.StartWorkerAsync();
        var changedAt = fixture.Admission.ScheduledUtc.AddSeconds(20);
        await fixture.Database.ConfigureBackupAsync(fixture.Repository.RepositoryPath, true,
            TimeSpan.FromMinutes(minutes), changedAt);
        var due = changedAt.AddMinutes(minutes);
        await fixture.Repository.CompleteWorkflowAsync(100, "backup-scheduler", WorkflowStatus.Succeeded);
        await fixture.Database.FinishBackupTickAsync(fixture.Admission, true, 100,
            ProcessOutcome.Succeeded, changedAt.AddSeconds(1));
        var state = await fixture.Database.ReadBackupStateIfChangedAsync(-1);
        Assert.Equal(due, state.NextDueUtc);
        Assert.Equal(ProcessOutcome.Succeeded, state.LastOutcome);
        Assert.Null(await fixture.Database.PrepareBackupTickAsync(due.AddSeconds(-1)));
        Assert.NotNull(await fixture.Database.PrepareBackupTickAsync(due));
    }

    private sealed class Fixture(TempDirectory temp, SchedulerDatabase database,
        RepositoryDatabase repository, BackupTickAdmission admission) : IDisposable
    {
        public SchedulerDatabase Database { get; } = database;
        public RepositoryDatabase Repository { get; } = repository;
        public BackupTickAdmission Admission { get; } = admission;
        private readonly RevisionedViewStore views = new();
        private SchedulerProjector? projector;
        public SchedulerProjector Projector => projector ??= new(Database, views, Repository);
        public ViewReadResult<ScheduleStatusView> View => views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0);

        public Task<WorkflowRun> ReserveAsync() => Repository.ReserveWorkflowAsync(
            "backup-maintenance", null, "backup-scheduler", Admission.AdmissionId, 100);
        public async Task StartWorkerAsync()
        {
            await ReserveAsync();
            await Repository.AttachWorkflowStageAsync(100, "backup-worker");
        }
        public static async Task<Fixture> CreateAsync()
        {
            var temp = new TempDirectory();
            try
            {
                var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
                var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
                var activatedAt = DateTimeOffset.UtcNow.AddMinutes(-5);
                await database.ConfigureBackupAsync(repository.RepositoryPath, true, TimeSpan.FromMinutes(5), activatedAt);
                await database.EnqueueTargetCommandAsync(new("activate", BackupTargetCommandKind.ActivateTarget,
                    new("Sandbox/Save", "Sandbox/Save", temp.GetPath("source"))));
                Assert.Null(await database.PrepareBackupTickAsync(activatedAt));
                var admission = await database.PrepareBackupTickAsync(activatedAt.AddMinutes(5));
                return new(temp, database, repository, admission!);
            }
            catch { temp.Dispose(); throw; }
        }
        public void Dispose() => temp.Dispose();
    }
}
