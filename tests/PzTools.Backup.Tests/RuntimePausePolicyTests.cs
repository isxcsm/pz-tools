using PzTools.App.Core;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Projections;
using PzTools.Scheduling;
using PzTools.Zomboid.State;
using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Tests;

public sealed class RuntimePausePolicyTests
{
    private static readonly string Process = Guid.NewGuid().ToString("N"), Observer = Guid.NewGuid().ToString("N"),
        World = Guid.NewGuid().ToString("N"), Stream = Guid.NewGuid().ToString("N");
    private static RuntimeObservation Sample(long active = 0, GamePause pause = GamePause.Running,
        long eligibility = 1, long clock = 1) => new(Stream, RuntimeQuality.Fresh,
            new(Process, Observer, World, clock, eligibility, active + eligibility, WorldPhase.Ready,
                pause, RuntimeMode.LocalSinglePlayer, pause == GamePause.Paused ? 0 : 1,
                active, 0, @"C:\fixture\Saves\Sandbox\World", Sleep: RuntimeSleep.Awake));
    private static ActiveTimeScheduleState Step(ActiveTimeScheduleState state, RuntimeObservation sample,
        bool enabled = true, long generation = 1) => ActiveTimeSchedulePolicy.Advance(state, sample, enabled, generation, 300_000);

    [Fact]
    public void PausePreservesRemainder_ResumeContinues_AndSpeedDoesNotMultiplyTheClock()
    {
        var state = Step(new(1, 300_000, 300_000), Sample());
        state = Step(state, Sample(120_000, GamePause.Paused, 2));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        Assert.Equal(ScheduleHold.GamePaused, state.Hold);
        for (int i = 0; i < 3; i++) state = Step(state, Sample(120_000, GamePause.Paused, 2));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        state = Step(state, Sample(120_000, GamePause.Running, 2));
        var accelerated = Sample(180_000, GamePause.Running, 2);
        state = Step(state, accelerated with { Snapshot = accelerated.Snapshot! with { SpeedLevel = 4 } });
        Assert.Equal(120_000, state.RemainingMilliseconds);
        Assert.Equal(ScheduleHold.None, state.Hold);
    }

    [Fact]
    public void MissingObservationDoesNotAccrueTime_AndReconnectionReanchors()
    {
        var state = Step(new(1, 300_000, 300_000), Sample());
        state = Step(state, Sample(120_000));
        state = Step(state, RuntimeObservation.Unknown("disconnected"));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        state = Step(state, Sample(900_000));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        state = Step(state, Sample(930_000));
        Assert.Equal(150_000, state.RemainingMilliseconds);
    }

    [Fact]
    public void ClockEpochChangesPreserveTime_ButNewWorldStartsFullInterval()
    {
        var state = Step(new(1, 300_000, 300_000), Sample());
        state = Step(state, Sample(120_000));
        state = Step(state, Sample(0, clock: 2));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        var next = Sample();
        state = Step(state, next with { Snapshot = next.Snapshot! with { WorldSession = Guid.NewGuid().ToString("N") } });
        Assert.Equal(300_000, state.RemainingMilliseconds);
    }

    [Fact]
    public void DisabledAndPausedAreIndependent_ChangingPolicyStartsANewFrozenInterval()
    {
        var state = Step(new(1, 300_000, 300_000), Sample(0, GamePause.Paused));
        state = Step(state, Sample(0, GamePause.Paused), false, 2);
        Assert.True(state.Hold.HasFlag(ScheduleHold.Disabled));
        Assert.True(state.Hold.HasFlag(ScheduleHold.GamePaused));
        state = Step(state, Sample(0, GamePause.Running), false, 2);
        Assert.Equal(ScheduleHold.Disabled, state.Hold);
        state = Step(state, Sample(20_000, GamePause.Paused), true, 3);
        Assert.Equal(300_000, state.RemainingMilliseconds);
        Assert.Equal(ScheduleHold.GamePaused, state.Hold);
    }

    [Fact]
    public void DeferredAttemptsDoNotConsumeSlots_UnknownCompletionBlocksImplicitRetry()
    {
        var state = new ActiveTimeScheduleState(1, 300_000, -10, AttemptId: "attempt");
        var deferred = ActiveTimeSchedulePolicy.Complete(state, ScheduleDisposition.Preserve);
        Assert.Equal(0, deferred.RemainingMilliseconds);
        Assert.Equal(state.Slot, deferred.Slot);
        Assert.Null(deferred.AttemptId);
        var unknown = ActiveTimeSchedulePolicy.Complete(state, ScheduleDisposition.CompletionUnknown);
        Assert.True(Step(unknown, Sample()).CompletionUncertain);
        Assert.True(Step(unknown, Sample()).Hold.HasFlag(ScheduleHold.Unknown));
        Assert.False(Step(unknown, Sample(), generation: 2).CompletionUncertain);
        // It is a one-interval pause, not a permanent stop: play time runs it down and clears it.
        Assert.Equal(300_000, unknown.RemainingMilliseconds);
        var waiting = Step(Step(unknown, Sample()), Sample(299_000));
        Assert.True(waiting.CompletionUncertain);
        var resumed = Step(waiting, Sample(300_000));
        Assert.False(resumed.CompletionUncertain);
        Assert.Equal(ScheduleHold.None, resumed.Hold);
        Assert.Equal(0, resumed.RemainingMilliseconds);
        var consumed = ActiveTimeSchedulePolicy.Complete(state with { RemainingMilliseconds = -620_000 }, ScheduleDisposition.Consume);
        Assert.Equal(280_000, consumed.RemainingMilliseconds);
        Assert.Equal(1, consumed.Slot);
    }

    [Fact]
    public void TransportHeartbeatCannotMakeAnOldGameThreadSampleFresh()
    {
        var time = new ManualClock();
        var cache = new RuntimeSnapshotStore(time);
        var sample = Sample();
        cache.Publish(sample with { Snapshot = sample.Snapshot! with { SampleAgeMilliseconds = 1000 } });
        time.Advance(1200);
        Assert.Equal(RuntimeQuality.Stale, cache.Read().Quality);
        cache.Publish(sample with { Snapshot = sample.Snapshot! with { SampleAgeMilliseconds = 2300 } });
        Assert.False(cache.Read().IsFresh);
        cache.Publish(sample);
        Assert.True(cache.Read().IsFresh);
    }

    [Fact]
    public void RuntimeActivityDoesNotOpenPlayersFile_AndPausedStillMeansWorldIsOpen()
    {
        var sample = Sample(120_000, GamePause.Paused, 2);
        var lane = new GameActivityLane(() => sample);
        Assert.Equal(ActivityState.Active, lane.Probe(@"C:\fixture\Saves\Sandbox\World\players.db").State);
        Assert.Equal(ActivityState.Inactive, lane.Probe(@"C:\fixture\Saves\Sandbox\Other\players.db").State);
        Assert.Equal(ActivityState.Unknown, new GameActivityLane(() => RuntimeObservation.Unknown())
            .Probe(@"C:\fixture\Saves\Sandbox\World\players.db").State);
    }

    [Fact]
    public void GuardTicketAndTypedDispositionSurviveSerialization_AndRejectMalformedTickets()
    {
        var ticket = new RuntimeSaveTicket(Process, Observer, World, 1, 2, 9000, 5, Guid.NewGuid().ToString("N"));
        Assert.Equal(ticket, RuntimeSaveTicket.Parse(ticket.Encode()));
        Assert.Throws<InvalidDataException>(() => RuntimeSaveTicket.Parse("1|missing"));
        var envelope = ProcessResultEnvelope<object>.Success("backup-worker", 1, ProcessOutcome.Skipped,
            DateTimeOffset.UtcNow, new { reason = "paused" }) with { ScheduleDisposition = ScheduleDisposition.Preserve };
        Assert.Equal(ScheduleDisposition.Preserve,
            ProcessResultJson.Deserialize<object>(ProcessResultJson.Serialize(envelope)).ScheduleDisposition);
    }

    [Fact]
    public async Task SemanticStateAndOutboxCommitTogether_HeartbeatsDoNotAdvanceRevision()
    {
        using var temp = new TempDirectory();
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await scheduler.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow, pauseDuringGame: true);
        var sample = Sample();
        await state.StageRuntimeAsync(sample);
        var applied = (await new RuntimeStateReactor().RunAsync(state))!;
        Assert.Single(await state.ReadRuntimeOutboxAsync());
        await new StateOutboxRelay().RelayRuntimeAsync(state, scheduler, @"C:\fixture\Saves");
        Assert.Empty(await state.ReadRuntimeOutboxAsync());
        Assert.Equal("Sandbox/World", (await scheduler.ReadBackupStateIfChangedAsync(-1)).CurrentTarget!.SaveId);
        var revision = (await scheduler.ReadBackupStateIfChangedAsync(-1)).SchedulerRevision;
        await scheduler.ApplyRuntimeTransitionAsync(applied, new("Sandbox/World", "Sandbox/World", sample.Snapshot!.SavePath!));
        Assert.Equal(revision, (await scheduler.ReadBackupStateIfChangedAsync(-1)).SchedulerRevision);
        await state.StageRuntimeAsync(Sample(20_000));
        var heartbeat = (await new RuntimeStateReactor().RunAsync(state))!;
        Assert.Equal(applied.StateRevision, heartbeat.StateRevision);
        Assert.Empty(await state.ReadRuntimeOutboxAsync());
        Assert.False((await state.ReadCurrentStateIfChangedAsync(-1)).Initialized);
        // An unrelated weak clear must not erase the runtime-selected target.
        await scheduler.EnqueueTargetCommandAsync(new("weak-clear", BackupTargetCommandKind.ClearTarget,
            new("Sandbox/World", "Sandbox/World", sample.Snapshot!.SavePath!)));
        await scheduler.PrepareBackupTickAsync(DateTimeOffset.UtcNow.AddDays(1));
        Assert.NotNull((await scheduler.ReadBackupStateIfChangedAsync(-1)).CurrentTarget);
    }

    [Fact]
    public async Task RuntimeOutboxFailureRollsBackAuthority_AndRetryAppliesThePendingObservation()
    {
        using var temp = new TempDirectory();
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        await state.StageRuntimeAsync(Sample());
        await ExecuteAsync("CREATE TRIGGER fail_runtime BEFORE INSERT ON runtime_outbox BEGIN SELECT RAISE(ABORT,'fixture'); END;");
        await Assert.ThrowsAsync<SqliteException>(() => new RuntimeStateReactor().RunAsync(state));
        Assert.Empty(await state.ReadRuntimeOutboxAsync());
        Assert.Equal(0, (await state.ReadCurrentStateIfChangedAsync(-1)).StateRevision);
        await ExecuteAsync("DROP TRIGGER fail_runtime;");
        Assert.NotNull(await new RuntimeStateReactor().RunAsync(state));
        Assert.Single(await state.ReadRuntimeOutboxAsync());
        async Task ExecuteAsync(string sql)
        {
            await using var connection = new SqliteConnection($"Data Source={state.DatabasePath};Pooling=False");
            await connection.OpenAsync(); await using var command = connection.CreateCommand();
            command.CommandText = sql; await command.ExecuteNonQueryAsync();
        }
    }

    [Fact]
    public async Task SettingsGenerationRevokesPreparationPermit_ButUnrelatedSettingsDoNot()
    {
        using var temp = new TempDirectory();
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await scheduler.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow, pauseDuringGame: true);
        await state.StageRuntimeAsync(Sample()); await new RuntimeStateReactor().RunAsync(state);
        await new StateOutboxRelay().RelayRuntimeAsync(state, scheduler, @"C:\fixture\Saves");
        var control = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.True(await RuntimePreparationPermit.IsCurrentAsync(scheduler.DatabasePath, control.Generation, control.CurrentTarget!.SourcePath));
        await scheduler.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow, pauseDuringGame: true);
        Assert.True(await RuntimePreparationPermit.IsCurrentAsync(scheduler.DatabasePath, control.Generation, control.CurrentTarget.SourcePath));
        await scheduler.ConfigureBackupAsync(temp.GetPath("repo"), false, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow, pauseDuringGame: true);
        Assert.False(await RuntimePreparationPermit.IsCurrentAsync(scheduler.DatabasePath, control.Generation, control.CurrentTarget.SourcePath));
        Assert.False(await RuntimePreparationPermit.IsCurrentAsync(temp.GetPath("missing.db"), 0, control.CurrentTarget.SourcePath));
        Assert.False(File.Exists(temp.GetPath("missing.db")));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PausePreferencePersistsIndependentlyFromSaveAndAutomaticSwitches(bool pause)
    {
        using var temp = new TempDirectory();
        var settings = new AppSettingsService(temp.GetPath("runtime"));
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var value = AppSettings.CreateDefault() with { SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("repo"),
            PausePeriodicDuringGame = pause, AutomaticBackupEnabled = false, SaveGameBeforeBackup = true, BackupIntervalMinutes = 17 };
        await settings.SaveAndApplyAsync(value, database);
        Assert.Equal(value, settings.Load());
        Assert.Equal(pause, (await database.ReadRuntimeScheduleAsync()).Enabled);
        Assert.False((await database.ReadBackupStateIfChangedAsync(-1)).AutomaticEnabled);
        Assert.True(settings.Load().SaveGameBeforeBackup);
        var views = new RevisionedViewStore(); new SettingsProjector(views).Project(value);
        Assert.Equal(pause, views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot!.PausePeriodicDuringGame);
    }

    [Fact]
    public void RuntimeNegotiationAcceptsAdditionalCapabilities_ButNeverDowngradesRequiredGuard()
    {
        var path = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(@"C:\fixture\Saves\Sandbox\World"));
        var prefix = $"STATE1\t{Process}\t{Observer}\t{World}\t1\t1\t1\tReady\tRunning\tLocalSinglePlayer\t1\t0\t0\t{path}\t";
        Assert.True(RuntimeSnapshot.ParseWire(prefix + RuntimeSnapshot.Capabilities + ",runtime.future.v1").IsWorldReady);
        Assert.Throws<InvalidDataException>(() => RuntimeSnapshot.ParseWire(prefix + "runtime.snapshot.v1,runtime.active-clock.v1"));
    }
    private sealed class ManualClock : TimeProvider
    {
        private long ticks;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => ticks;
        public void Advance(long milliseconds) => ticks += milliseconds;
    }
}