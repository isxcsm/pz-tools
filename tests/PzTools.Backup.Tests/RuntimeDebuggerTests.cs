using PzTools.App.Core;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Projections;
using PzTools.Scheduling;
using PzTools.State.Scheduler;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

/// <summary>
/// Seen in the game: a Lua error with Break On Error on (debug mode) stops the game thread in the game's Lua debugger,
/// and after the link grace the app said it was not connected and backed up on the clock. The game is alive and its
/// world frozen: a known state, in which backups wait, and the game-aware schedule goes on when the player does.
/// </summary>
public sealed class RuntimeDebuggerTests
{
    private static string Id() => Guid.NewGuid().ToString("N");

    private static RuntimeSnapshot World(string path, WorldPhase phase = WorldPhase.Ready, long clock = 1) =>
        new(Id(), Id(), Id(), clock, 1, 1, phase, phase == WorldPhase.Ready ? GamePause.Running : GamePause.Unknown,
            phase is WorldPhase.Ready or WorldPhase.Menu ? RuntimeMode.LocalSinglePlayer : RuntimeMode.Unsupported, 1, 0, 0,
            phase == WorldPhase.Ready ? path : null, Sleep: RuntimeSleep.Awake);

    // The observation the state scheduler publishes once the game has waited in the debugger for longer than freshness.
    private static RuntimeObservation InDebugger(RuntimeSnapshot sample, long revision = 0, string authority = "") =>
        new(Id(), RuntimeQuality.Stale, sample with { InDebugger = true, SampleAgeMilliseconds = 95_000 }, revision,
            Reason: RuntimeObservation.GameDebuggerReason, AuthorityEpoch: authority);

    [Fact]
    public void Wire_SaysWhetherTheGameThreadIsInTheDebugger()
    {
        string id = Id();
        string frame = string.Join('\t', "STATE6", id, id, id, "1", "1", "7", "Ready", "Running", "LocalSinglePlayer", "1", "0",
            "1500", Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(@"C:\fixture\Saves\Sandbox\World")),
            RuntimeSnapshot.Capabilities, "-", "Unknown", "-", "-", "-", "Awake", "8192", "Debugger");
        Assert.True(RuntimeSnapshot.ParseWire(frame).InDebugger);
        Assert.False(RuntimeSnapshot.ParseWire(frame[..frame.LastIndexOf('\t')] + "\t-").InDebugger);
        Assert.Throws<InvalidDataException>(() => RuntimeSnapshot.ParseWire(frame[..frame.LastIndexOf('\t')] + "\tHung"));
        // An older bridge says nothing about it.
        var older = RuntimeSnapshot.ParseWire(frame[..frame.LastIndexOf('\t')].Replace("STATE6", "STATE5"));
        Assert.False(older.InDebugger);
        Assert.Equal(8192, older.HeapMaximumMegabytes);
        // Not a semantic change of its own: the observation's reason says it.
        var sample = RuntimeSnapshot.ParseWire(frame);
        Assert.Equal((sample with { InDebugger = false }).SemanticKey, sample.SemanticKey);
    }

    [Theory]
    [InlineData(WorldPhase.Ready)]
    [InlineData(WorldPhase.Menu)]
    [InlineData(WorldPhase.Loading)]
    public void AGameWaitingInTheDebugger_IsAKnownState_NotALostLink(WorldPhase phase)
    {
        var clock = new ManualClock();
        var feed = new RuntimeSnapshotStore(clock);
        var sample = World(@"C:\fixture\Saves\Sandbox\World", phase);
        feed.Publish(new(Id(), RuntimeQuality.Fresh, sample with { InDebugger = true, SampleAgeMilliseconds = 95_000 }));
        var waiting = feed.Read();
        Assert.Equal(RuntimeQuality.Stale, waiting.Quality);
        Assert.Equal(RuntimeObservation.GameDebuggerReason, waiting.Reason);
        Assert.True(waiting.IsInDebugger);
        Assert.False(waiting.IsFresh);
        Assert.False(waiting.IsLinkUnusable);
        Assert.False(new GameLinkMonitor(linkGrace: TimeSpan.Zero, gameRunning: () => true).Update(waiting).LinkUnavailable);

        // Frames that stop arriving are a lost link, wherever the game thread was.
        clock.Advance(2001);
        Assert.False(feed.Read().IsInDebugger);
        Assert.True(feed.Read().IsLinkUnusable);
    }

    [Fact]
    public void AGameThreadStoppedElsewhereInAWorld_MayBeHung_AndStaysUnusable()
    {
        var feed = new RuntimeSnapshotStore();
        feed.Publish(new(Id(), RuntimeQuality.Fresh, World(@"C:\fixture\Saves\Sandbox\World") with { SampleAgeMilliseconds = 95_000 }));
        var hung = feed.Read();
        Assert.Equal("stale-game-sample", hung.Reason);
        Assert.False(hung.IsInDebugger);
        Assert.True(hung.IsLinkUnusable);
        // A reason alone, without the sample it is about, is not the debugger.
        Assert.False((RuntimeObservation.Unknown(RuntimeObservation.GameDebuggerReason) with { Quality = RuntimeQuality.Stale }).IsInDebugger);
    }

    [Fact]
    public void Policy_HoldsTheCountdownWithoutCountingTheWait()
    {
        string stream = Id();
        var sample = World(@"C:\fixture\Saves\Sandbox\World");
        ActiveTimeScheduleState Step(ActiveTimeScheduleState state, RuntimeObservation observation) =>
            ActiveTimeSchedulePolicy.Advance(state, observation, true, 1, 300_000);

        var state = Step(new(1, 300_000, 300_000), new(stream, RuntimeQuality.Fresh, sample));
        state = Step(state, new(stream, RuntimeQuality.Fresh, sample with { ActiveMilliseconds = 100_000, Sequence = 2 }));
        Assert.Equal(200_000, state.RemainingMilliseconds);
        var waiting = InDebugger(sample with { ActiveMilliseconds = 100_000, Sequence = 3 }) with { StreamEpoch = stream };
        state = Step(state, waiting);
        Assert.Equal(ScheduleHold.GameDebugger, state.Hold);
        Assert.Equal(200_000, state.RemainingMilliseconds);
        Assert.False(state.Anchored);
        // The game goes on: the gap starts a new clock epoch, and the countdown resumes from where it stood.
        var resumed = sample with { ClockEpoch = 2, ActiveMilliseconds = 0, Sequence = 4 };
        state = Step(state, new(stream, RuntimeQuality.Fresh, resumed));
        state = Step(state, new(stream, RuntimeQuality.Fresh, resumed with { ActiveMilliseconds = 50_000, Sequence = 5 }));
        Assert.Equal(ScheduleHold.None, state.Hold);
        Assert.Equal(150_000, state.RemainingMilliseconds);
    }

    [Fact]
    public async Task GameAwareSchedule_WaitsWithoutTheClockFallback_AndResumesWhenTheGameGoesOn()
    {
        using var temp = new TempDirectory();
        var db = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var target = new BackupTarget("Sandbox/world", "Sandbox/world", temp.GetPath("world"));
        Directory.CreateDirectory(target.SourcePath);
        var now = DateTimeOffset.UtcNow;
        await db.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), now, pauseDuringGame: true);
        var feed = new RuntimeSnapshotStore();
        var authority = Id();
        var sample = World(target.SourcePath);
        var fresh = new RuntimeObservation(Id(), RuntimeQuality.Fresh, sample, 1, AuthorityEpoch: authority);
        await db.ApplyRuntimeTransitionAsync(fresh, target);
        // The backup is due now; the game stops in the debugger first. Its save's file is locked, as it is in play.
        var control = await db.ReadBackupStateIfChangedAsync(-1);
        await db.WriteRuntimeCheckpointAsync(new(control.Generation, 300_000, 0));
        await db.EnqueueTargetCommandAsync(new("activate", BackupTargetCommandKind.ActivateTarget, target));
        var waiting = InDebugger(sample, 2, authority);
        await db.ApplyRuntimeTransitionAsync(waiting, target);
        feed.Publish(waiting);
        var controller = new RuntimeScheduleController(db, feed, linkGrace: TimeSpan.Zero);

        // However long the player reads the error: no backup, and no clock-time backups of a frozen save.
        foreach (var minutes in new[] { 0, 10, 60 })
            Assert.Null((await controller.PrepareAsync(now.AddMinutes(minutes), TimeSpan.Zero, default)).Admission);
        var held = (await db.ReadRuntimeScheduleAsync()).Checkpoint!;
        Assert.Null(held.FallbackDueUtc);
        Assert.Equal(ScheduleHold.GameDebugger, held.Hold);
        Assert.Equal(0, held.RemainingMilliseconds);
        Assert.Equal(target, (await db.ReadBackupStateIfChangedAsync(-1)).CurrentTarget);
        var view = RuntimeScheduleProjection.Build(await db.ReadBackupStateIfChangedAsync(-1), await db.ReadRuntimeScheduleAsync(), feed.Read());
        Assert.False(view.Fallback);
        Assert.Equal(new CountdownPresentation("RuntimeBackupDebugger", 0, true), ScheduleCountdownPresentation.Resolve(view, now));

        // The player goes on: the backup long due is asked of the game at once.
        var resumed = new RuntimeObservation(fresh.StreamEpoch, RuntimeQuality.Fresh, sample with { ClockEpoch = 2, Sequence = 9 }, 3,
            AuthorityEpoch: authority);
        await db.ApplyRuntimeTransitionAsync(resumed, target);
        feed.Publish(resumed);
        var admission = (await controller.PrepareAsync(now.AddMinutes(61), TimeSpan.Zero, default)).Admission;
        Assert.NotNull(admission);
        Assert.False(RuntimeScheduleController.IsFallback(admission));
        Assert.Equal(2, admission.RuntimeTicket!.ClockEpoch);

        // A game thread stopped anywhere else is not known to wait: past the grace, the clock fallback still takes over.
        var hung = new RuntimeObservation(fresh.StreamEpoch, RuntimeQuality.Stale, sample with { SampleAgeMilliseconds = 95_000 }, 4,
            Reason: "stale-game-sample", AuthorityEpoch: authority);
        await db.ApplyRuntimeTransitionAsync(hung, target);
        feed.Publish(hung);
        await controller.PrepareAsync(now.AddMinutes(62), TimeSpan.Zero, default);
        Assert.NotNull((await db.ReadRuntimeScheduleAsync()).Checkpoint!.FallbackDueUtc);
    }

    [Fact]
    public async Task ClockTimeSchedule_AlsoWaitsWhileTheGameIsInTheDebugger()
    {
        using var temp = new TempDirectory();
        var db = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var target = new BackupTarget("Sandbox/world", "Sandbox/world", temp.GetPath("world"));
        var now = DateTimeOffset.UtcNow;
        await db.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), now, pauseDuringGame: false);
        await db.EnqueueTargetCommandAsync(new("activate", BackupTargetCommandKind.ActivateTarget, target));
        var feed = new RuntimeSnapshotStore();
        int backups = 0; long run = 0;
        var scheduler = new BackupScheduler(db, _ => Task.FromResult(++run),
            (_, _, _, _, _) => { backups++; return Task.FromResult(new WorkerInvocation(false, ProcessOutcome.Skipped, null)); },
            (_, _, _, _, _) => Task.FromResult(new WorkerInvocation(false, ProcessOutcome.Skipped, null)),
            runtimeSchedule: new RuntimeScheduleController(db, feed));
        await scheduler.TickAsync(now);
        var sample = World(target.SourcePath);

        feed.Publish(InDebugger(sample));
        Assert.False((await scheduler.TickAsync(now.AddMinutes(6))).Due);
        Assert.Equal(0, backups);
        // The line says why the backup waits, with the time to its slot while there is one.
        var views = new RevisionedViewStore();
        await new SchedulerProjector(db, views, runtimeSnapshot: feed).ProjectOnceAsync();
        var view = views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!;
        Assert.True(view.Hold.HasFlag(ScheduleHold.GameDebugger));
        Assert.Equal("RuntimeBackupDebugger", ScheduleCountdownPresentation.Resolve(view, now.AddMinutes(6)).MessageKey);

        feed.Publish(new(Id(), RuntimeQuality.Fresh, sample));
        Assert.True((await scheduler.TickAsync(now.AddMinutes(6))).Due);
        Assert.Equal(1, backups);
    }

    [Fact]
    public void Countdown_SaysTheGameIsInTheDebugger()
    {
        var now = new DateTimeOffset(2026, 10, 9, 0, 0, 0, TimeSpan.Zero);
        var view = new ScheduleStatusView(1, SchedulerMode.Continuous, null, null, null, null, true, 0, PauseAware: true,
            RemainingMilliseconds: 120_500, Hold: ScheduleHold.GameDebugger);
        // On game time the time left stands still, as in a pause.
        Assert.Equal(new CountdownPresentation("RuntimeBackupDebugger", 121, true), ScheduleCountdownPresentation.Resolve(view, now));
        // Stopped with no world open (in the main menu): there is no time left to show.
        Assert.Equal(new CountdownPresentation("RuntimeBackupDebugger", null, true),
            ScheduleCountdownPresentation.Resolve(view with { Hold = ScheduleHold.GameDebugger | ScheduleHold.NoWorld }, now));
        // Said before a skipped backup's countdown, which waits for the game as well.
        Assert.Equal("RuntimeBackupDebugger", ScheduleCountdownPresentation.Resolve(view with { CompletionUncertain = true }, now).MessageKey);
        // On the clock the time runs; a backup that falls due waits.
        var clock = view with { PauseAware = false, RemainingMilliseconds = null, NextDueUtc = now.AddMinutes(2) };
        Assert.Equal(new CountdownPresentation("RuntimeBackupDebugger", 120), ScheduleCountdownPresentation.Resolve(clock, now));
        Assert.Equal(new CountdownPresentation("RuntimeBackupDebugger"), ScheduleCountdownPresentation.Resolve(clock, now.AddMinutes(3)));
        // Offline and switched off keep their priority.
        Assert.Equal("AutomaticBackupOff", ScheduleCountdownPresentation.Resolve(view with { AutomaticEnabled = false }, now).MessageKey);
    }

    [Fact]
    public void SaveInPlay_StaysInPlayWhileTheGameIsInTheDebugger()
    {
        using var temp = new TempDirectory();
        var world = temp.GetPath("world");
        Directory.CreateDirectory(world);
        var players = Path.Combine(world, "players.db");
        File.WriteAllText(players, "fixture");
        var waiting = InDebugger(World(world));
        Assert.Equal(ActivityState.Active, new GameActivityLane(() => waiting).Probe(players).State);
        var other = temp.GetPath("other");
        Directory.CreateDirectory(other);
        Assert.Equal(ActivityState.Inactive, new GameActivityLane(() => waiting).Probe(Path.Combine(other, "players.db")).State);
        // A game thread stopped elsewhere is not known to be in its world: the file lock says it, as before.
        var hung = waiting with { Reason = "stale-game-sample" };
        Assert.Equal("sharing-violation", LockedProbe(players, hung).ErrorCode);
    }

    private static (ActivityState State, LaneStatus Status, string? ErrorCode) LockedProbe(string players, RuntimeObservation observation)
    {
        using var held = new FileStream(players, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        return new GameActivityLane(() => observation).Probe(players);
    }

    [Fact]
    public void Extensions_KeepTheirWorldForAsLongAsTheGameIsInTheDebugger()
    {
        var sample = World(@"C:\fixture\Saves\Sandbox\World");
        var waiting = InDebugger(sample);
        var hung = waiting with { Reason = "stale-game-sample" };
        var minutes = RuntimeExtensionCoordinator.TransientStaleGrace + TimeSpan.FromMinutes(30);
        Assert.True(RuntimeExtensionCoordinator.KeepsWorldWhileStale(waiting, minutes, sample.ProcessSession, sample.WorldSession));
        Assert.False(RuntimeExtensionCoordinator.KeepsWorldWhileStale(hung, minutes, sample.ProcessSession, sample.WorldSession));
        Assert.True(RuntimeExtensionCoordinator.KeepsWorldWhileStale(hung, TimeSpan.FromSeconds(1), sample.ProcessSession, sample.WorldSession));
        // Another world is another world, debugger or not.
        Assert.False(RuntimeExtensionCoordinator.KeepsWorldWhileStale(waiting, TimeSpan.Zero, sample.ProcessSession, Id()));
    }

    private sealed class ManualClock : TimeProvider
    {
        private long value;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => value;
        public void Advance(long milliseconds) => value += milliseconds;
    }
}
