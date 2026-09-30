using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Projections;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class RuntimeScheduleIntegrationTests
{
    [Fact]
    public async Task CommittedRuntimeDrivesAdmission_PausePreservesTime_DeferredWorkerDoesNotConsumeSlot()
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0);
        Assert.Null((await f.TickAsync()).Admission);
        await f.PublishAsync(120_000, GamePause.Paused, 2);
        Assert.Null((await f.TickAsync()).Admission);
        Assert.Equal(180_000, (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.RemainingMilliseconds);
        // UTC can jump by days; only the runtime's active counter consumes the interval.
        Assert.Null((await f.Controller.PrepareAsync(DateTimeOffset.UtcNow.AddDays(3), TimeSpan.Zero, default)).Admission);
        await f.PublishAsync(120_000, GamePause.Running, 2);
        Assert.Null((await f.TickAsync()).Admission);
        await f.PublishAsync(300_000, GamePause.Running, 2);
        var due = (await f.TickAsync()).Admission!;
        Assert.NotNull(due.RuntimeTicket);
        Assert.Equal(300_000, due.RuntimeTicket.DueActiveMilliseconds);
        Assert.Equal(due.AdmissionId, (await f.TickAsync()).Admission!.AdmissionId);
        await f.Controller.FinishAsync(due, new(true, ProcessOutcome.Skipped, "runtime-deferred", ScheduleDisposition.Preserve));
        var retry = (await f.TickAsync()).Admission!;
        Assert.NotEqual(due.AdmissionId, retry.AdmissionId);
        Assert.Equal(due.RuntimeTicket.DueActiveMilliseconds, retry.RuntimeTicket!.DueActiveMilliseconds);
        await f.Controller.FinishAsync(retry, new(true, ProcessOutcome.Succeeded));
        Assert.Null((await f.TickAsync()).Admission);
        var saved = (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!;
        Assert.Equal(300_000, saved.RemainingMilliseconds);
        Assert.Equal(1, saved.Slot);
    }

    [Fact]
    public async Task ReconnectAndSchedulerRestartKeepRemainingTime_WithoutReplayingUnknownWork()
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        f.Time.Advance(11_000);
        await f.PublishAsync(120_000); await f.TickAsync();
        Assert.Equal(180_000, (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.RemainingMilliseconds);
        var before = (await f.Database.ReadBackupStateIfChangedAsync(-1)).Generation;
        await f.PublishUnknownAsync(); await f.TickAsync();
        f.Reconnect();
        await f.PublishAsync(0);
        f.RestartController();
        Assert.Null((await f.TickAsync()).Admission);
        Assert.Equal(before, (await f.Database.ReadBackupStateIfChangedAsync(-1)).Generation);
        Assert.Equal(180_000, (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.RemainingMilliseconds);
        await f.PublishAsync(180_000);
        var admission = (await f.TickAsync()).Admission!;
        Assert.NotNull(admission);
        // Crash after reservation; a new observation epoch cannot prove whether the save ran.
        f.Reconnect(); f.RestartController(); await f.PublishAsync(0);
        Assert.Null((await f.TickAsync()).Admission);
        Assert.True((await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.CompletionUncertain);
    }

    [Fact]
    public async Task OneShotDeathWorkDoesNotResetPeriodicCadence_AndWeakCommandsAreAcknowledged()
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        await f.PublishAsync(120_000); await f.TickAsync();
        var before = await f.Database.ReadBackupStateIfChangedAsync(-1);
        await f.Database.EnqueueTargetCommandAsync(new("weak-stop", BackupTargetCommandKind.ClearTarget, f.Target));
        await f.Database.EnqueueTargetCommandAsync(new("death", BackupTargetCommandKind.RunOnceNow, f.Target));
        var oneShot = (await f.TickAsync()).Admission!;
        Assert.Equal(BackupAdmissionKind.RunOnce, oneShot.Kind);
        Assert.Equal(before.Generation, (await f.Database.ReadBackupStateIfChangedAsync(-1)).Generation);
        await f.Database.FinishBackupTickAsync(oneShot, true, 7, ProcessOutcome.Succeeded, DateTimeOffset.UtcNow);
        f.Time.Advance(11_000); await f.PublishAsync(130_000); await f.TickAsync();
        Assert.Equal(170_000, (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.RemainingMilliseconds);
        await using var connection = new SqliteConnection($"Data Source={f.Database.DatabasePath};Pooling=False");
        await connection.OpenAsync(); await using var query = connection.CreateCommand();
        query.CommandText = "SELECT COUNT(*) FROM backup_target_commands WHERE applied_utc IS NULL;";
        Assert.Equal(0L, await query.ExecuteScalarAsync());
    }

    [Fact]
    public async Task NamedPipeFeedCarriesOnlyCommittedReadState_AndBecomesUnknownAfterDisconnect()
    {
        using var temp = new TempDirectory();
        var source = new RuntimeSnapshotStore(); var destination = new RuntimeSnapshotStore();
        using var serverStop = new CancellationTokenSource(); using var clientStop = new CancellationTokenSource();
        var authority = temp.GetPath("scheduler.db");
        var server = RuntimeStateFeed.ServeAsync(authority, source, serverStop.Token);
        var client = RuntimeStateFeed.FollowAsync(authority, destination, clientStop.Token);
        try
        {
            source.Publish(new("", RuntimeQuality.Offline, null, StateRevision: 12, Reason: "fixture"));
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            while (destination.Read().StateRevision != 12) await Task.Delay(20, timeout.Token);
            Assert.Equal(RuntimeQuality.Offline, destination.Read().Quality);
            await serverStop.CancelAsync();
            while (destination.Read().Quality != RuntimeQuality.Unknown) await Task.Delay(20, timeout.Token);
            Assert.False(File.Exists(authority)); // Feed never opens or creates scheduler storage.
        }
        finally
        {
            await serverStop.CancelAsync(); await clientStop.CancelAsync();
            try { await Task.WhenAll(server,client); } catch (OperationCanceledException) { }
        }
    }

    [Fact]
    public async Task RestartAfterUnfinishedReservationAndPause_DoesNotCreateANewSaveAttempt()
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        await f.PublishAsync(300_000);
        Assert.NotNull((await f.TickAsync()).Admission);
        // The same observer survives. A pause/resume is not proof the old save never started.
        f.RestartController();
        await f.PublishAsync(300_000, GamePause.Paused, 2);
        Assert.Null((await f.TickAsync()).Admission);
        await f.PublishAsync(300_000, GamePause.Running, 2);
        Assert.Null((await f.TickAsync()).Admission);
        Assert.True((await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.CompletionUncertain);
    }

    [Theory]
    [InlineData(ProcessOutcome.Failed)]
    [InlineData(ProcessOutcome.Cancelled)]
    public async Task MissingWorkerDisposition_SitsOutOneIntervalOfPlay_ThenBackupsResume(ProcessOutcome outcome)
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        await f.PublishAsync(300_000);
        var admission = (await f.TickAsync()).Admission!;
        // Covers a lost/malformed worker envelope and cancellation without a typed outcome.
        await f.Controller.FinishAsync(admission, new(false, outcome, "missing-result"));
        Assert.True((await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.CompletionUncertain);
        // No immediate retry: the game may still be saving.
        Assert.Null((await f.TickAsync()).Admission);
        await f.PublishAsync(450_000);
        Assert.Null((await f.TickAsync()).Admission);
        // One full interval later the unknown outcome no longer blocks anything.
        await f.PublishAsync(600_000);
        Assert.NotNull((await f.TickAsync()).Admission);
        Assert.False((await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.CompletionUncertain);
    }

    [Theory]
    [InlineData(false, false)] // The error came before any worker was dispatched: nothing is in doubt.
    [InlineData(true, true)]   // The worker was dispatched and its result was lost: the save may have run.
    public async Task OnlyAnErrorAfterDispatchLeavesTheOutcomeUnknown(bool dispatch, bool uncertain)
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        await f.PublishAsync(300_000);
        var run = 100L;
        var scheduler = new BackupScheduler(f.Database, _ => Task.FromResult(++run),
            (_, _, _, _, _) => throw new InvalidOperationException("must use the guarded runner"),
            (_, _, _, _, _) => throw new InvalidOperationException("must not maintain"),
            runtimeSchedule: f.Controller,
            guardedBackupRunner: dispatch ? (_, _, _) => throw new IOException("worker result lost") : null);

        await Assert.ThrowsAnyAsync<Exception>(() => scheduler.TickAsync(DateTimeOffset.UtcNow));

        var saved = (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!;
        Assert.Equal(uncertain, saved.CompletionUncertain);
        if (uncertain) Assert.Null((await f.TickAsync()).Admission);
        else Assert.NotNull((await f.TickAsync()).Admission); // The same slot is still due.
    }

    [Fact]
    public async Task SkippedWorkerDidNothing_SoItsSlotIsKept()
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        await f.PublishAsync(300_000);
        var admission = (await f.TickAsync()).Admission!;
        await f.Controller.FinishAsync(admission, new(false, ProcessOutcome.Skipped, "skipped-without-disposition"));
        var saved = (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!;
        Assert.False(saved.CompletionUncertain);
        Assert.Equal(0, saved.Slot);
        Assert.NotNull((await f.TickAsync()).Admission);
    }

    [Fact]
    public async Task FailedBackupWithKnownSaveOutcome_SpendsItsSlotAndRunsAgainNextInterval()
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        await f.PublishAsync(300_000);
        var admission = (await f.TickAsync()).Admission!;
        await f.Controller.FinishAsync(admission, new(true, ProcessOutcome.Failed, "backup-failed", ScheduleDisposition.Consume));
        var saved = (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!;
        Assert.False(saved.CompletionUncertain);
        Assert.Equal(1, saved.Slot);
        Assert.Null((await f.TickAsync()).Admission); // No immediate retry storm.
        await f.PublishAsync(600_000);
        Assert.NotNull((await f.TickAsync()).Admission);
    }

    [Theory]
    [InlineData("completion-unknown", true)]
    [InlineData("invalid-response", true)]
    [InlineData("attach-failed", false)]
    [InlineData("connection-timeout", false)]
    [InlineData("unsupported-protocol", false)]
    public void OnlyAnUnansweredSaveCommandLeavesTheOutcomeUnknown(string code, bool unknown) =>
        Assert.Equal(unknown, new PzTools.SaveBridge.GameSaveException(code, "fixture").SaveOutcomeUnknown);

    [Fact]
    public async Task WorkerThatNeverStarted_IsNotAnUnknownCompletion()
    {
        using var temp = new TempDirectory();
        var invocation = await new RunnerProcessAdapter(temp.GetPath("no-workers")).RunBackupAsync(
            temp.GetPath("repo"), new("Sandbox/World", "Sandbox/World", temp.GetPath("save")), 1, null, default);
        Assert.False(invocation.Started);
        Assert.Equal(ProcessOutcome.Failed, invocation.Outcome);
        Assert.Equal(ScheduleDisposition.Consume, invocation.ScheduleDisposition);
    }

    [Fact]
    public async Task BusyWorkerPreservesPeriodicSlotEvenWhenProcessStarted()
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        await f.PublishAsync(300_000);
        var admission = (await f.TickAsync()).Admission!;
        await f.Controller.FinishAsync(admission, new(true, ProcessOutcome.Busy));
        Assert.Equal(0, (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.Slot);
        Assert.NotNull((await f.TickAsync()).Admission);
    }
    [Fact]
    public async Task CommittedSleepPreservesRemainingAcrossSchedulerRestart_AndWakeContinuesTheSlot()
    {
        using var temp = new TempDirectory();
        var f = await Fixture.CreateAsync(temp);
        await f.PublishAsync(0); await f.TickAsync();
        await f.PublishAsync(120_000, eligibility: 2, sleep: RuntimeSleep.Asleep);
        Assert.Null((await f.TickAsync()).Admission);
        Assert.Equal(180_000, (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.RemainingMilliseconds);
        f.RestartController();
        f.Time.Advance(600_000);
        await f.PublishAsync(120_000, eligibility: 2, sleep: RuntimeSleep.Asleep);
        Assert.Null((await f.TickAsync()).Admission);
        Assert.Equal(ScheduleHold.Sleeping, (await f.Database.ReadRuntimeScheduleAsync()).Checkpoint!.Hold);
        await f.PublishAsync(120_000, eligibility: 2);
        Assert.Null((await f.TickAsync()).Admission);
        await f.PublishAsync(300_000, eligibility: 2);
        Assert.NotNull((await f.TickAsync()).Admission);
    }
    private sealed class Fixture(StateDatabase state, SchedulerDatabase scheduler, string root, string save)
    {
        private readonly string process = Guid.NewGuid().ToString("N"), world = Guid.NewGuid().ToString("N");
        private string observer = Guid.NewGuid().ToString("N"), stream = Guid.NewGuid().ToString("N");
        private long sequence;
        public ManualClock Time { get; } = new();
        public SchedulerDatabase Database => scheduler;
        public BackupTarget Target => new("Sandbox/World", "Sandbox/World", save);
        private RuntimeSnapshotStore? store;
        private RuntimeSnapshotStore Store => store ??= new(Time);
        public RuntimeScheduleController Controller { get; private set; } = null!;
        public static async Task<Fixture> CreateAsync(TempDirectory temp)
        {
            var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
            await database.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow, pauseDuringGame:true);
            var result = new Fixture(await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db")), database,
                temp.GetPath("Saves"), temp.GetPath("Saves/Sandbox/World"));
            result.RestartController(); return result;
        }
        public void RestartController() => Controller = new(Database, Store, Time);
        public void Reconnect() { stream = Guid.NewGuid().ToString("N"); observer = Guid.NewGuid().ToString("N"); sequence = 0; }
        public async Task PublishAsync(long active, GamePause pause = GamePause.Running, long eligibility = 1, RuntimeSleep sleep = RuntimeSleep.Awake)
        {
            var value = new RuntimeObservation(stream,RuntimeQuality.Fresh,
                new(process,observer,world,1,eligibility,++sequence,WorldPhase.Ready,pause,RuntimeMode.LocalSinglePlayer,
                    pause == GamePause.Paused ? 0 : 1,active,0,save, Sleep: sleep));
            await PublishAsync(value);
        }
        public Task PublishUnknownAsync() => PublishAsync(RuntimeObservation.Unknown("fixture-disconnect"));
        private async Task PublishAsync(RuntimeObservation observation)
        {
            await state.StageRuntimeAsync(observation);
            var result = (await new RuntimeStateReactor().RunAsync(state))!;
            await new StateOutboxRelay().RelayRuntimeAsync(state, scheduler, root);
            Store.Publish(result);
        }
        public async Task<RuntimeAdmissionSelection> TickAsync()
        {
            var result = await Controller.PrepareAsync(DateTimeOffset.UtcNow,TimeSpan.Zero,default);
            if (result.Admission is null && (await Database.ReadRuntimeScheduleAsync()).Checkpoint is { Hold: ScheduleHold.None, RemainingMilliseconds: <= 0 })
                throw new InvalidOperationException("Due state did not yield an admission: " + RuntimeJson.Write(await Database.ReadRuntimeScheduleAsync()));
            return result;
        }
    }
    private sealed class ManualClock : TimeProvider
    {
        private long value;
        public override long GetTimestamp() => value;
        public override long TimestampFrequency => 1000;
        public void Advance(long milliseconds) => value += milliseconds;
    }
}