using Microsoft.Data.Sqlite;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Projections;
using PzTools.Scheduling;
using PzTools.Zomboid.Backup;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class AutomaticBackupRegressionTests
{
    [Fact]
    public async Task ConfirmedPlayExit_ClearsTarget_NoFinalBackup_AndIntervalChangeCannotReviveIt()
    {
        using var temp = new TempDirectory();
        var scheduler = await ConfiguredAsync(temp);
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = temp.GetPath("save");
        var now = DateTimeOffset.UtcNow;
        for (var i = 1; i <= 2; i++) await ObserveAsync(ActivityState.Active, CharacterState.Alive, i);
        await new StateOutboxRelay().RelayAsync(state, scheduler);
        Assert.Null(await scheduler.PrepareBackupTickAsync(now));
        Assert.Equal(SchedulerMode.Continuous, (await scheduler.ReadBackupStateIfChangedAsync(-1)).Mode);
        for (var i = 3; i <= 4; i++) await ObserveAsync(ActivityState.Inactive, CharacterState.Dead, i);
        var messages = await state.ReadPendingOutboxAsync();
        Assert.Contains(messages, message => message.Command == "ClearTarget");
        Assert.DoesNotContain(messages, message => message.Command is "FinalizeTarget" or "RunOnceNow");
        await new StateOutboxRelay().RelayAsync(state, scheduler);
        // Settings are saved before the backup scheduler has consumed the stop command.
        await scheduler.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(10), now.AddSeconds(1));
        var stopped = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.Null(stopped.CurrentTarget);
        Assert.Equal(SchedulerMode.Paused, stopped.Mode);
        Assert.Equal(0, stopped.PendingRuns);
        Assert.Null(await scheduler.PrepareBackupTickAsync(now.AddHours(2)));
        scheduler = await SchedulerDatabase.CreateOrOpenAsync(scheduler.DatabasePath);
        await scheduler.ConfigureBackupAsync(temp.GetPath("repository"), false, TimeSpan.FromMinutes(10), now);
        await scheduler.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(1), now);
        Assert.Null((await scheduler.ReadBackupStateIfChangedAsync(-1)).CurrentTarget);
        Assert.Null(await scheduler.PrepareBackupTickAsync(now.AddHours(3)));

        async Task ObserveAsync(ActivityState activity, CharacterState character, int run)
        {
            await state.WritePendingBatchAsync(new(Guid.NewGuid().ToString("D"), run, now, now, 0, true,
                [new SaveObservation(path, "Sandbox", "Save", true, false, activity, character,
                    LaneStatus.Succeeded, LaneStatus.Succeeded)]));
            await new StateReactor().RunAsync(state);
        }
    }

    [Theory]
    [InlineData("Limited", 1)]
    [InlineData("Ambiguous", 0)]
    [InlineData("Paused", 0)]
    public async Task IntervalChange_DoesNotPromoteNonPlayingMode(string mode, int attempts)
    {
        using var temp = new TempDirectory();
        var database = await ConfiguredAsync(temp);
        var now = DateTimeOffset.UtcNow;
        var target = Target(temp);
        await database.EnqueueTargetCommandAsync(new("active", BackupTargetCommandKind.ActivateTarget, target));
        await database.PrepareBackupTickAsync(now);
        await using (var connection = new SqliteConnection($"Data Source={database.DatabasePath};Pooling=False"))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "UPDATE backup_scheduler_control SET mode=$mode,attempts_remaining=$attempts;";
            command.Parameters.AddWithValue("$mode", mode);
            command.Parameters.AddWithValue("$attempts", attempts);
            await command.ExecuteNonQueryAsync();
        }
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(7), now);
        var updated = await database.ReadBackupStateIfChangedAsync(-1);
        Assert.NotEqual(SchedulerMode.Continuous, updated.Mode);
        Assert.Null(await database.PrepareBackupTickAsync(now.AddDays(1)));
        var views = new RevisionedViewStore();
        await new SchedulerProjector(database, views).ProjectOnceAsync();
        Assert.Null(views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!.NextDueUtc);
    }

    [Fact]
    public async Task OffThenOnDuringPlay_StartsFullInterval_WithoutLosingConfirmedActivity()
    {
        using var temp = new TempDirectory();
        var database = await ConfiguredAsync(temp);
        var now = DateTimeOffset.UtcNow;
        await database.ConfigureBackupAsync(temp.GetPath("repository"), false, TimeSpan.FromMinutes(5), now);
        await database.EnqueueTargetCommandAsync(new("active", BackupTargetCommandKind.ActivateTarget, Target(temp)));
        Assert.Null(await database.PrepareBackupTickAsync(now));
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(3), now.AddMinutes(1));
        Assert.Null(await database.PrepareBackupTickAsync(now.AddMinutes(1)));
        Assert.Null(await database.PrepareBackupTickAsync(now.AddMinutes(4).AddTicks(-1)));
        Assert.Equal(now.AddMinutes(4), (await database.PrepareBackupTickAsync(now.AddMinutes(4)))!.ScheduledUtc);
    }

    [Fact]
    public async Task Countdown_RequiresFreshSingleActiveSave_EvenWithoutSchedulerRevisionChange()
    {
        using var temp = new TempDirectory();
        var database = await ConfiguredAsync(temp);
        var now = DateTimeOffset.UtcNow;
        var target = Target(temp);
        await database.EnqueueTargetCommandAsync(new("active", BackupTargetCommandKind.ActivateTarget, target));
        await database.PrepareBackupTickAsync(now);
        var views = new RevisionedViewStore();
        var projector = new SchedulerProjector(database, views, requireActiveState: true);
        await projector.ProjectOnceAsync();
        Assert.Null(View().NextDueUtc); // No confirmed state in this app session yet.
        Publish(GameState.Playing, ActivityState.Active, ViewFreshness.Fresh);
        await projector.ProjectOnceAsync();
        Assert.NotNull(View().NextDueUtc);
        var revision = View().SchedulerRevision;
        Publish(GameState.NotPlaying, ActivityState.Inactive, ViewFreshness.Fresh);
        await projector.ProjectOnceAsync();
        Assert.Equal(revision, View().SchedulerRevision);
        Assert.Null(View().NextDueUtc);
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(9), now);
        await projector.ProjectOnceAsync();
        Assert.Null(View().NextDueUtc);
        Publish(GameState.Playing, ActivityState.Active, ViewFreshness.Stale);
        await projector.ProjectOnceAsync();
        Assert.Null(View().NextDueUtc);
        Publish(GameState.Playing, ActivityState.Active, ViewFreshness.Fresh);
        await projector.ProjectOnceAsync();
        Assert.Equal(now.AddMinutes(9), View().NextDueUtc);
        void Publish(GameState game, ActivityState activity, ViewFreshness freshness) => views.Publish(ViewKey.SaveList,
            new SaveListView(1, game, [new(target.SaveId, "Sandbox", "Save", target.SourcePath, null, null,
                activity, CharacterState.Alive, freshness)]));
        ScheduleStatusView View() => views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!;
    }

    [Fact]
    public async Task AutomaticDispatch_RejectsInactiveTargetBeforeAllocatingOrLaunching()
    {
        using var temp = new TempDirectory();
        var database = await ConfiguredAsync(temp);
        var now = DateTimeOffset.UtcNow;
        await database.EnqueueTargetCommandAsync(new("active", BackupTargetCommandKind.ActivateTarget, Target(temp)));
        await database.PrepareBackupTickAsync(now);
        var scheduler = new BackupScheduler(database, _ => throw new InvalidOperationException("must not allocate"),
            (_, _, _, _, _) => throw new InvalidOperationException("must not launch"),
            (_, _, _, _, _) => throw new InvalidOperationException("must not maintain"), isTargetActive: _ => false);
        Assert.False((await scheduler.TickAsync(now.AddMinutes(5))).Due);
    }

    [Fact]
    public async Task StopArrivingAfterAdmission_IsRecheckedBeforeLaunchingWorker()
    {
        using var temp = new TempDirectory();
        var database = await ConfiguredAsync(temp);
        var now = DateTimeOffset.UtcNow;
        var target = Target(temp);
        await database.EnqueueTargetCommandAsync(new("active", BackupTargetCommandKind.ActivateTarget, target));
        await database.PrepareBackupTickAsync(now);
        var calls = 0;
        var scheduler = new BackupScheduler(database, async _ =>
        {
            await database.EnqueueTargetCommandAsync(new("stop", BackupTargetCommandKind.ClearTarget, target));
            return 10L;
        }, (_, _, _, _, _) => { calls++; return Task.FromResult(new WorkerInvocation(true, ProcessOutcome.Failed)); },
            (_, _, _, _, _) => throw new InvalidOperationException("must not maintain"));
        var tick = await scheduler.TickAsync(now.AddMinutes(5));
        Assert.Equal(0, calls);
        Assert.Equal(ProcessOutcome.Skipped, tick.Outcome);
        Assert.Null((await database.ReadBackupStateIfChangedAsync(-1)).CurrentTarget);
    }

    [Theory]
    [InlineData(ActivityState.Inactive)]
    [InlineData(ActivityState.Unknown)]
    public async Task AutomaticPreparation_RequiresPositiveActivityBeforeGameSave(ActivityState activity)
    {
        var preparation = new BackupTimingPreparation((_, _) => throw new InvalidOperationException("must not connect"), _ => activity);
        await Assert.ThrowsAsync<AutomaticBackupSkippedException>(() => preparation.PrepareAsync("selected", null, true));
    }

    [Fact]
    public async Task ExitDuringScheduledWait_SkipsEvenWithGameSavingDisabled()
    {
        var activity = ActivityState.Active;
        var waited = false;
        var preparation = new BackupTimingPreparation((_, _) => Task.FromResult(new GameSaveResult("disabled")),
            _ => activity, delay: (_, token) =>
            {
                token.ThrowIfCancellationRequested();
                waited = true;
                activity = ActivityState.Inactive;
                return Task.CompletedTask;
            });
        await Assert.ThrowsAsync<AutomaticBackupSkippedException>(() => preparation.PrepareAsync(
            "selected", DateTimeOffset.UtcNow.AddMinutes(1), true));
        Assert.True(waited);
    }

    [Theory]
    [InlineData("not-in-world")]
    [InlineData("game-not-running")]
    [InlineData("save-mismatch")]
    public async Task GameSaveReportsExit_AutomaticSkips_ButManualOfflineBackupRemainsAllowed(string outcome)
    {
        var preparation = new BackupTimingPreparation((_, _) => Task.FromResult(new GameSaveResult(outcome)), _ => ActivityState.Active);
        await Assert.ThrowsAsync<AutomaticBackupSkippedException>(() => preparation.PrepareAsync("selected", null, true));
        Assert.Equal(outcome, (await preparation.PrepareAsync("selected", null, false)).Outcome);
    }

    [Fact]
    public async Task Preparation_RechecksAfterSave_AndPreservesExplicitCancellation()
    {
        var activity = ActivityState.Active;
        var preparation = new BackupTimingPreparation((_, _) =>
        {
            activity = ActivityState.Inactive;
            return Task.FromResult(new GameSaveResult("saved"));
        }, _ => activity);
        await Assert.ThrowsAsync<AutomaticBackupSkippedException>(() => preparation.PrepareAsync("selected", null, true));
        var cancelled = await Assert.ThrowsAnyAsync<OperationCanceledException>(() => preparation.PrepareAsync(
            "selected", null, true, new CancellationToken(true)));
        Assert.IsNotType<AutomaticBackupSkippedException>(cancelled);
    }

    private static BackupTarget Target(TempDirectory temp) => new("Sandbox/Save", "Sandbox/Save", temp.GetPath("save"));
    private static async Task<SchedulerDatabase> ConfiguredAsync(TempDirectory temp)
    {
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow);
        return database;
    }
}
