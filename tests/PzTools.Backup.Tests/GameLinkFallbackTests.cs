using PzTools.App.Core;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Projections;
using PzTools.SaveBridge;
using PzTools.Scheduling;
using PzTools.Zomboid.Backup;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

/// <summary>A feature stops only when the thing it needs from the game is missing; backups never do.</summary>
public sealed class GameLinkFallbackTests
{
    private static string Id() => Guid.NewGuid().ToString("N");

    private static RuntimeSnapshot World(string path, long active = 0, RuntimeSleep sleep = RuntimeSleep.Awake,
        WorldPhase phase = WorldPhase.Ready, string? process = null) =>
        new(process ?? Id(), Id(), Id(), 1, 1, active + 1, phase, phase == WorldPhase.Ready ? GamePause.Running : GamePause.Unknown,
            phase == WorldPhase.Ready ? RuntimeMode.LocalSinglePlayer : RuntimeMode.Unsupported, 1, active, 0,
            phase == WorldPhase.Ready ? path : null, Sleep: sleep);

    [Fact]
    public void UnreadableSleep_OnlyLosesTheSleepPause()
    {
        string stream = Id();
        var first = World(@"C:\fixture\Saves\Sandbox\World", sleep: RuntimeSleep.Unknown);
        RuntimeObservation At(long active, RuntimeSleep sleep) => new(stream, RuntimeQuality.Fresh,
            first with { ActiveMilliseconds = active, Sequence = active + 1, Sleep = sleep });
        ActiveTimeScheduleState Step(ActiveTimeScheduleState state, RuntimeObservation sample) =>
            ActiveTimeSchedulePolicy.Advance(state, sample, true, 1, 300_000);

        var state = Step(new(1, 300_000, 300_000), At(0, RuntimeSleep.Unknown));
        state = Step(state, At(120_000, RuntimeSleep.Unknown));
        Assert.Equal(ScheduleHold.None, state.Hold);
        Assert.Equal(180_000, state.RemainingMilliseconds);
        // Sleep that can be read still pauses.
        Assert.Equal(ScheduleHold.Sleeping, Step(state, At(120_000, RuntimeSleep.Asleep)).Hold);
    }

    [Fact]
    public void LinkIsUnusable_OnlyWhenARunningGameCannotBeRead()
    {
        var path = @"C:\fixture\Saves\Sandbox\World";
        Assert.True(RuntimeObservation.Unknown("runtime-unavailable").IsLinkUnusable);
        Assert.True(new RuntimeObservation(Id(), RuntimeQuality.Fresh, World(path, phase: WorldPhase.Unknown)).IsLinkUnusable);
        Assert.False(new RuntimeObservation(Id(), RuntimeQuality.Fresh, World(path)).IsLinkUnusable);
        Assert.False(new RuntimeObservation(Id(), RuntimeQuality.Fresh, World(path, phase: WorldPhase.Loading)).IsLinkUnusable);
        Assert.False(new RuntimeObservation(Id(), RuntimeQuality.Fresh, World(path, phase: WorldPhase.Menu)).IsLinkUnusable);
        Assert.False(new RuntimeObservation("", RuntimeQuality.Offline, null).IsLinkUnusable);
        Assert.False(new RuntimeObservation("", RuntimeQuality.Ambiguous, null).IsLinkUnusable);
        Assert.False(new RuntimeObservation(Id(), RuntimeQuality.Unsupported, World(path)).IsLinkUnusable);
    }

    [Fact]
    public async Task UnreadableGame_FallsBackToClockTimeBackups_AndReturnsWhenItCanBeReadAgain()
    {
        using var temp = new TempDirectory();
        var db = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var target = new BackupTarget("Sandbox/world", "Sandbox/world", temp.GetPath("world"));
        Directory.CreateDirectory(target.SourcePath);
        // The scheduler re-checks a reservation against the real clock, so the interval ends just before now.
        var now = DateTimeOffset.UtcNow.AddMinutes(-5).AddSeconds(-1);
        await db.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), now, pauseDuringGame: true);
        var feed = new RuntimeSnapshotStore();
        feed.Publish(RuntimeObservation.Unknown("runtime-unavailable"));
        var controller = new RuntimeScheduleController(db, feed, linkGrace: TimeSpan.Zero);

        // The game's file locks are the only remaining evidence of which save is played.
        Assert.Null((await controller.PrepareAsync(now, TimeSpan.Zero, default)).Admission);
        Assert.Null((await controller.PrepareAsync(now.AddMinutes(5), TimeSpan.Zero, default)).Admission);
        await db.EnqueueTargetCommandAsync(new("activate", BackupTargetCommandKind.ActivateTarget, target));

        bool active = false; int backups = 0; long run = 0; DateTimeOffset? scheduled = null;
        var scheduler = new BackupScheduler(db, _ => Task.FromResult(++run),
            (_, _, _, due, _) => { backups++; scheduled = due; return Task.FromResult(new WorkerInvocation(true, ProcessOutcome.Skipped, null)); },
            (_, _, _, _, _) => Task.FromResult(new WorkerInvocation(false, ProcessOutcome.Skipped, null)),
            isTargetActive: _ => active, runtimeSchedule: controller);
        Assert.False((await scheduler.TickAsync(now.AddMinutes(5))).Due); // The save is not being played.
        active = true;
        var tick = await scheduler.TickAsync(now.AddMinutes(5));
        Assert.True(tick.Due);
        Assert.Equal(target, tick.Target);
        Assert.Equal(1, backups);
        Assert.Equal(now.AddMinutes(5), scheduled); // Dispatched as an ordinary, unguarded periodic backup.
        Assert.False((await scheduler.TickAsync(now.AddMinutes(5).AddSeconds(1))).Due);
        var checkpoint = (await db.ReadRuntimeScheduleAsync()).Checkpoint!;
        Assert.Equal(now.AddMinutes(10), checkpoint.FallbackDueUtc);
        var view = RuntimeScheduleProjection.Build(await db.ReadBackupStateIfChangedAsync(-1),
            await db.ReadRuntimeScheduleAsync(), feed.Read());
        Assert.True(view.Fallback);
        Assert.Equal(new CountdownPresentation("RuntimeBackupFallback", 240),
            ScheduleCountdownPresentation.Resolve(view, now.AddMinutes(6)));

        // The game answers again: back to game time. Its world is newly observed, so a full interval starts.
        var authority = Id();
        var fresh = new RuntimeObservation(Id(), RuntimeQuality.Fresh, World(target.SourcePath), 1, AuthorityEpoch: authority);
        await db.ApplyRuntimeTransitionAsync(fresh, target);
        feed.Publish(fresh);
        Assert.Null((await controller.PrepareAsync(now.AddMinutes(6), TimeSpan.Zero, default)).Admission);
        checkpoint = (await db.ReadRuntimeScheduleAsync()).Checkpoint!;
        Assert.Null(checkpoint.FallbackDueUtc);
        Assert.Equal(300_000, checkpoint.RemainingMilliseconds);
        Assert.False(RuntimeScheduleProjection.Build(await db.ReadBackupStateIfChangedAsync(-1),
            await db.ReadRuntimeScheduleAsync(), feed.Read()).Fallback);
    }

    [Fact]
    public async Task BriefOutage_DoesNotStartTheFallback()
    {
        using var temp = new TempDirectory();
        var db = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var now = DateTimeOffset.UtcNow;
        await db.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), now, pauseDuringGame: true);
        var feed = new RuntimeSnapshotStore();
        feed.Publish(RuntimeObservation.Unknown("connecting"));
        var controller = new RuntimeScheduleController(db, feed, linkGrace: TimeSpan.FromHours(1));
        await controller.PrepareAsync(now, TimeSpan.Zero, default);
        await controller.PrepareAsync(now.AddMinutes(10), TimeSpan.Zero, default);
        Assert.Null((await db.ReadRuntimeScheduleAsync()).Checkpoint!.FallbackDueUtc);
    }

    [Theory]
    [InlineData("attach-failed", BackupGameSave.SaveUnavailable)]
    [InlineData("connection-timeout", BackupGameSave.SaveUnavailable)]
    [InlineData("bridge-not-built", BackupGameSave.SaveUnavailable)]
    [InlineData("not-in-world", "not-in-world")]
    public async Task UnreachableGame_IsBackedUpFromDisk_ButARefusedOrUncertainSaveStillFails(string code, string outcome)
    {
        var save = new BackupGameSave((_, _) => throw new GameSaveException(code, "test"), _ => ActivityState.Active);
        Assert.Equal(outcome, (await save.PrepareAsync(@"C:\fixture", default)).Outcome);
        foreach (var failure in new[] { "completion-unknown", "save-failed", "queue-timeout" })
            await Assert.ThrowsAsync<GameSaveException>(() => new BackupGameSave(
                (_, _) => throw new GameSaveException(failure, "test"), _ => ActivityState.Active).PrepareAsync(@"C:\fixture", default));
    }

    [Fact]
    public void Monitor_ReportsOnlyConditionsThatLast_AndOnlyWhileAGameRuns()
    {
        var path = @"C:\fixture\Saves\Sandbox\World";
        bool running = true;
        var lasting = new GameLinkMonitor(linkGrace: TimeSpan.Zero, valueGrace: TimeSpan.Zero, gameRunning: () => running);
        Assert.Equal(new GameLinkView(LinkUnavailable: true), lasting.Update(RuntimeObservation.Unknown("runtime-unavailable")));
        Assert.Equal(new GameLinkView(SleepUnavailable: true), lasting.Update(
            new(Id(), RuntimeQuality.Fresh, World(path, sleep: RuntimeSleep.Unknown))));
        Assert.Equal(GameLinkView.Available, lasting.Update(new(Id(), RuntimeQuality.Fresh, World(path))));
        Assert.Equal(GameLinkView.Available, lasting.Update(new("", RuntimeQuality.Offline, null)));
        running = false; // A dead feed with no game is not a game that cannot be reached.
        Assert.Equal(GameLinkView.Available, lasting.Update(RuntimeObservation.Unknown("runtime-feed-disconnected")));

        var patient = new GameLinkMonitor(linkGrace: TimeSpan.FromHours(1), valueGrace: TimeSpan.FromHours(1), gameRunning: () => true);
        Assert.Equal(GameLinkView.Available, patient.Update(RuntimeObservation.Unknown("connecting")));
        Assert.Equal(GameLinkView.Available, patient.Update(new(Id(), RuntimeQuality.Fresh, World(path, sleep: RuntimeSleep.Unknown))));
    }
}
