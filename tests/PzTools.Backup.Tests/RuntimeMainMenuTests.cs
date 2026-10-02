using PzTools.App.Core;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Projections;
using PzTools.Scheduling;

namespace PzTools.Backup.Tests;

public sealed class RuntimeMainMenuTests
{
    private static readonly string Id = Guid.NewGuid().ToString("N");
    private static readonly DateTimeOffset Now = new(2026, 9, 27, 0, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FreshMenuIsShownWithoutCountdown_BeforeTheSchedulerTransitionCommits(bool pauseAware)
    {
        using var temp = new TempDirectory();
        var database = await CreateDatabaseAsync(temp, pauseAware);
        var feed = new RuntimeSnapshotStore();
        var views = new RevisionedViewStore();
        var projector = new SchedulerProjector(database, views, runtimeSnapshot: feed);
        var controlBefore = await database.ReadBackupStateIfChangedAsync(-1);
        var storageBefore = await database.ReadRuntimeScheduleAsync();
        Assert.Null(storageBefore.Facts);

        feed.Publish(Sample(WorldPhase.Menu));
        await projector.ProjectOnceAsync();

        var view = Read(views);
        Assert.Equal(WorldPhase.Menu, view.GamePhase);
        Assert.Equal(new CountdownPresentation("RuntimeBackupMainMenu"),
            ScheduleCountdownPresentation.Resolve(view, Now));
        Assert.Equal(pauseAware, view.PauseAware);
        Assert.Equal(controlBefore, await database.ReadBackupStateIfChangedAsync(-1));
        Assert.Equal(storageBefore, await database.ReadRuntimeScheduleAsync());
        if (pauseAware) Assert.True(view.Hold.HasFlag(ScheduleHold.Unknown));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CachedMenuDoesNotSurviveDisconnectOrLossOfFreshness(bool pauseAware)
    {
        using var temp = new TempDirectory();
        var database = await CreateDatabaseAsync(temp, pauseAware);
        var clock = new ManualClock();
        var feed = new RuntimeSnapshotStore(clock);
        var views = new RevisionedViewStore();
        var projector = new SchedulerProjector(database, views, runtimeSnapshot: feed);

        foreach (var quality in new[] { RuntimeQuality.Unknown, RuntimeQuality.Stale,
                     RuntimeQuality.Ambiguous, RuntimeQuality.Unsupported, RuntimeQuality.Offline })
        {
            feed.Publish(Sample(WorldPhase.Menu));
            await projector.ProjectOnceAsync();
            Assert.Equal(WorldPhase.Menu, Read(views).GamePhase);

            feed.Publish(Sample(WorldPhase.Menu) with { Quality = quality });
            await projector.ProjectOnceAsync();
            AssertNoMenu();
        }

        feed.Publish(Sample(WorldPhase.Menu));
        await projector.ProjectOnceAsync();
        clock.Advance(2001);
        await projector.ProjectOnceAsync();
        AssertNoMenu();

        var menu = Sample(WorldPhase.Menu);
        feed.Publish(menu with { Snapshot = menu.Snapshot! with { SampleAgeMilliseconds = 1000 } });
        clock.Advance(1001);
        await projector.ProjectOnceAsync();
        AssertNoMenu(); // Receipt heartbeats cannot refresh an old game-thread sample.

        feed.Publish(Sample(WorldPhase.Menu));
        await projector.ProjectOnceAsync();
        feed.Publish(RuntimeObservation.Unknown("runtime-feed-disconnected"));
        await projector.ProjectOnceAsync();
        AssertNoMenu();

        void AssertNoMenu()
        {
            Assert.Equal(WorldPhase.Unknown, Read(views).GamePhase);
            Assert.NotEqual("RuntimeBackupMainMenu",
                ScheduleCountdownPresentation.Resolve(Read(views), Now).MessageKey);
        }
    }

    [Theory]
    [InlineData(false, WorldPhase.Unknown)]
    [InlineData(false, WorldPhase.Loading)]
    [InlineData(false, WorldPhase.Ready)]
    [InlineData(false, WorldPhase.Unloading)]
    [InlineData(true, WorldPhase.Unknown)]
    [InlineData(true, WorldPhase.Loading)]
    [InlineData(true, WorldPhase.Ready)]
    [InlineData(true, WorldPhase.Unloading)]
    public async Task OtherFreshPhasesAreNotPresentedAsTheMainMenu(bool pauseAware, WorldPhase phase)
    {
        using var temp = new TempDirectory();
        var database = await CreateDatabaseAsync(temp, pauseAware);
        var feed = new RuntimeSnapshotStore();
        var views = new RevisionedViewStore();
        var projector = new SchedulerProjector(database, views, runtimeSnapshot: feed);
        feed.Publish(Sample(WorldPhase.Menu));
        await projector.ProjectOnceAsync();

        feed.Publish(Sample(phase));
        await projector.ProjectOnceAsync();

        Assert.Equal(phase, Read(views).GamePhase);
        Assert.NotEqual("RuntimeBackupMainMenu",
            ScheduleCountdownPresentation.Resolve(Read(views), Now).MessageKey);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void OfflineDisabledAndUnavailableMessagesKeepTheirPriority(bool pauseAware)
    {
        var view = new ScheduleStatusView(1, SchedulerMode.Continuous, null, Now.AddMinutes(5),
            null, null, true, 0, PauseAware: pauseAware, RemainingMilliseconds: 300_000,
            Hold: ScheduleHold.Unknown, GamePhase: WorldPhase.Menu);
        Assert.Equal(new CountdownPresentation("RuntimeBackupMainMenu"),
            ScheduleCountdownPresentation.Resolve(view, Now));
        Assert.Equal(new CountdownPresentation("AutomaticBackupOff"),
            ScheduleCountdownPresentation.Resolve(view with { AutomaticEnabled = false }, Now));
        Assert.Equal(new CountdownPresentation("RuntimeBackupOffline"),
            ScheduleCountdownPresentation.Resolve(view with {
                AutomaticEnabled = false, Hold = ScheduleHold.GameOffline | ScheduleHold.NoWorld }, Now));
        Assert.Equal(new CountdownPresentation("SchedulerStatusUnavailable"),
            ScheduleCountdownPresentation.Resolve(view, Now, unavailable: true));
        // The skipped interval is shown with its remaining time; it ends by itself.
        Assert.Equal(pauseAware ? new CountdownPresentation("RuntimeBackupCompletionUnknown", 300)
                : new CountdownPresentation("RuntimeBackupMainMenu"),
            ScheduleCountdownPresentation.Resolve(view with { CompletionUncertain = true }, Now));
    }

    [Fact]
    public async Task DisplayingPendingMenuCannotAuthorizeOrConsumeADueBackup()
    {
        using var temp = new TempDirectory();
        var database = await CreateDatabaseAsync(temp, pauseAware: true);
        var ready = Sample(WorldPhase.Ready) with { StateRevision = 1 };
        var target = new BackupTarget("Sandbox/World", "Sandbox/World", ready.Snapshot!.SavePath!);
        await database.ApplyRuntimeTransitionAsync(ready, target);
        var control = await database.ReadBackupStateIfChangedAsync(-1);
        await database.WriteRuntimeCheckpointAsync(new(control.Generation, 300_000, 0));
        var storage = await database.ReadRuntimeScheduleAsync();

        var menu = Sample(WorldPhase.Menu) with { StateRevision = 2 };
        var projected = RuntimeScheduleProjection.Build(control, storage, menu);
        Assert.Equal(WorldPhase.Menu, projected.GamePhase);
        Assert.True(projected.Hold.HasFlag(ScheduleHold.Unknown));
        Assert.Equal(0, projected.RemainingMilliseconds);
        Assert.Equal(storage, await database.ReadRuntimeScheduleAsync());
        Assert.Equal(control, await database.ReadBackupStateIfChangedAsync(-1));

        var feed = new RuntimeSnapshotStore();
        feed.Publish(menu);
        var selection = await new RuntimeScheduleController(database, feed)
            .PrepareAsync(Now.AddDays(1), TimeSpan.Zero, default);
        Assert.Null(selection.Admission);
        var held = (await database.ReadRuntimeScheduleAsync()).Checkpoint!;
        Assert.Equal(0, held.RemainingMilliseconds);
        Assert.Equal(0, held.Slot);
        Assert.Null(held.AttemptId);
        Assert.True(held.Hold.HasFlag(ScheduleHold.Unknown));

        // Once committed, the existing policy clears the old world rather than
        // admitting a due save from the newly visible menu state.
        await database.ApplyRuntimeTransitionAsync(menu, null);
        Assert.Null((await database.ReadBackupStateIfChangedAsync(-1)).CurrentTarget);
        Assert.Null((await new RuntimeScheduleController(database, feed)
            .PrepareAsync(Now.AddDays(1), TimeSpan.Zero, default)).Admission);
    }

    private static RuntimeObservation Sample(WorldPhase phase) =>
        new(Id, RuntimeQuality.Fresh,
            new(Id, Id, Id, 1, 1, 1, phase, GamePause.Running, RuntimeMode.LocalSinglePlayer,
                1, 0, 0, phase == WorldPhase.Ready ? @"C:\fixture\Saves\Sandbox\World" : null,
                Sleep: RuntimeSleep.Awake),
            StateRevision: 1, AuthorityEpoch: Id);

    private static async Task<SchedulerDatabase> CreateDatabaseAsync(TempDirectory temp, bool pauseAware)
    {
        var database = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await database.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(5),
            Now, pauseDuringGame: pauseAware);
        return database;
    }

    private static ScheduleStatusView Read(RevisionedViewStore views) =>
        views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!;

    private sealed class ManualClock : TimeProvider
    {
        private long value;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => value;
        public void Advance(long milliseconds) => value += milliseconds;
    }
}
