using PzTools.App.Core;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Projections;
using PzTools.Scheduling;

namespace PzTools.Backup.Tests;

public sealed class RuntimeSleepTests
{
    private static readonly string Id = Guid.NewGuid().ToString("N");
    private static RuntimeObservation Sample(long active, RuntimeSleep sleep = RuntimeSleep.Awake) =>
        new(Id, RuntimeQuality.Fresh, new(Id, Id, Id, 1, 1, active + 1, WorldPhase.Ready,
            GamePause.Running, RuntimeMode.LocalSinglePlayer, 4, active, 0,
            @"C:\fixture\Saves\Sandbox\World", Sleep: sleep));
    private static ActiveTimeScheduleState Advance(ActiveTimeScheduleState state, RuntimeObservation sample) =>
        ActiveTimeSchedulePolicy.Advance(state, sample, true, 1, 300_000);

    [Fact]
    public void SleepFreezesRemainingTime_WithoutCallingTheGamePaused_AndWakeResumes()
    {
        var state = Advance(new(1, 300_000, 300_000), Sample(0));
        state = Advance(state, Sample(120_000, RuntimeSleep.Asleep));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        Assert.Equal(ScheduleHold.Sleeping, state.Hold);
        state = Advance(state, Sample(120_000, RuntimeSleep.Asleep));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        state = Advance(state, Sample(120_000));
        Assert.Equal(ScheduleHold.None, state.Hold);
        state = Advance(state, Sample(150_000));
        Assert.Equal(150_000, state.RemainingMilliseconds); // Speed 4 is not a multiplier.
    }

    [Fact]
    public void UnknownSleepKeepsTheClockRunning_BecauseOnlyTheSleepPauseIsLost()
    {
        var state = Advance(new(1, 300_000, 300_000), Sample(0));
        state = Advance(state, Sample(120_000));
        state = Advance(state, Sample(180_000, RuntimeSleep.Unknown));
        Assert.Equal(120_000, state.RemainingMilliseconds);
        Assert.Equal(ScheduleHold.None, state.Hold);
        Assert.Equal(119_000, Advance(state, Sample(181_000)).RemainingMilliseconds);
    }

    [Fact]
    public void SleepFrameRoundTrips_AndOlderFramesDoNotPretendThePlayerIsAwake()
    {
        string path = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(@"C:\fixture\Saves\Sandbox\World"));
        string frame = $"STATE4\t{Id}\t{Id}\t{Id}\t1\t1\t1\tReady\tRunning\tLocalSinglePlayer\t4\t120000\t0\t{path}\t{RuntimeSnapshot.Capabilities},runtime.sleep.v1\t-\tAlive\t{Id}\t-\t-\tAsleep";
        var state = RuntimeSnapshot.ParseWire(frame);
        Assert.Equal(RuntimeSleep.Asleep, state.Sleep);
        Assert.Equal(GamePause.Running, state.Pause);
        Assert.Equal(state, RuntimeJson.Read<RuntimeSnapshot>(RuntimeJson.Write(state)));
        var old = RuntimeSnapshot.ParseWire(frame[..frame.LastIndexOf('\t')].Replace("STATE4", "STATE3"));
        Assert.Equal(RuntimeSleep.Unknown, old.Sleep);
        Assert.NotEqual(state.SemanticKey, (state with { Sleep = RuntimeSleep.Awake }).SemanticKey);
        Assert.Throws<InvalidDataException>(() => RuntimeSnapshot.ParseWire(frame.Replace("\tAsleep", "\tTypo")));
    }

    [Fact]
    public void HeapFrame_SaysTheGamesMemory_AndAnOlderBridgeSaysNone()
    {
        string path = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(@"C:\fixture\Saves\Sandbox\World"));
        string older = $"STATE4\t{Id}\t{Id}\t{Id}\t1\t1\t1\tReady\tRunning\tLocalSinglePlayer\t4\t120000\t0\t{path}\t{RuntimeSnapshot.Capabilities}\t-\tAlive\t{Id}\t-\t-\tAwake";
        var state = RuntimeSnapshot.ParseWire(older.Replace("STATE4", "STATE5") + "\t8192");
        Assert.Equal(8192, state.HeapMaximumMegabytes);
        Assert.Equal(state, RuntimeJson.Read<RuntimeSnapshot>(RuntimeJson.Write(state)));
        Assert.Null(RuntimeSnapshot.ParseWire(older).HeapMaximumMegabytes);
        // It does not change while the game runs, so it starts no state transition.
        Assert.Equal(state.SemanticKey, (state with { HeapMaximumMegabytes = 3072 }).SemanticKey);
        // The settings read it through the link view, kept through a moment the game cannot be read.
        var monitor = new GameLinkMonitor(linkGrace: TimeSpan.FromHours(1), gameRunning: () => true);
        Assert.Equal(8192, monitor.Update(new(Id, RuntimeQuality.Fresh, state)).GameHeapMegabytes);
        Assert.Equal(8192, monitor.Update(RuntimeObservation.Unknown("connecting")).GameHeapMegabytes);
        Assert.Null(monitor.Update(new("", RuntimeQuality.Offline, null)).GameHeapMegabytes);
    }

    [Theory]
    [InlineData(ScheduleHold.GamePaused, "RuntimeBackupPaused")]
    [InlineData(ScheduleHold.Sleeping, "RuntimeBackupSleeping")]
    public void SuspendedCountdownKeepsTheActualRemainderAndRequestsMutedPresentation(ScheduleHold hold, string key)
    {
        var view = new ScheduleStatusView(1, SchedulerMode.Continuous, null, null, null, null, true, 0,
            PauseAware: true, RemainingMilliseconds: 180_000, Hold: hold);
        Assert.Equal(new CountdownPresentation(key, 180, true), ScheduleCountdownPresentation.Resolve(view, DateTimeOffset.UtcNow));
        var running = ScheduleCountdownPresentation.Resolve(view with { Hold = ScheduleHold.None }, DateTimeOffset.UtcNow);
        Assert.False(running.Suspended);
        Assert.Equal(180, running.RemainingSeconds);
    }

    [Fact]
    public void UnknownGameStateIsShownWithoutATime_AndOnlyWhenItLasts()
    {
        var now = DateTimeOffset.UtcNow;
        var view = new ScheduleStatusView(1, SchedulerMode.Continuous, null, null, null, null, true, 0,
            PauseAware: true, RemainingMilliseconds: 300_000, Hold: ScheduleHold.Unknown);
        var checking = ScheduleCountdownPresentation.Resolve(view, now);
        Assert.Equal(new CountdownPresentation("RuntimeBackupWaiting"), checking);
        Assert.Equal(new CountdownPresentation("RuntimeBackupLoading"),
            ScheduleCountdownPresentation.Resolve(view with { GamePhase = WorldPhase.Loading }, now));

        var stabilizer = new CountdownDisplayStabilizer(TimeSpan.FromSeconds(3));
        // App start: nothing was shown before, so the neutral text stays.
        Assert.Equal("NextBackupWaitingDynamic", stabilizer.Apply(checking, now).MessageKey);
        var offline = new CountdownPresentation("RuntimeBackupOffline");
        Assert.Equal(offline, stabilizer.Apply(offline, now.AddSeconds(1)));
        // The game connects: a brief unknown keeps the previous text.
        Assert.Equal(offline, stabilizer.Apply(checking, now.AddSeconds(2)));
        Assert.Equal(offline, stabilizer.Apply(checking, now.AddSeconds(4)));
        Assert.Equal(checking, stabilizer.Apply(checking, now.AddSeconds(5))); // It lasted.
        var running = new CountdownPresentation("ProjectorArea.Schedule", 300);
        Assert.Equal(running, stabilizer.Apply(running, now.AddSeconds(6)));
        Assert.Equal(running, stabilizer.Apply(checking, now.AddSeconds(7))); // A new wait starts over.
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConfirmedOfflineIsShownImmediately_WithoutTimer_EvenBeforePolicyCommit(bool pausePolicy)
    {
        using var temp = new TempDirectory();
        var db = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await db.ConfigureBackupAsync(temp.GetPath("repository"), true, TimeSpan.FromMinutes(5),
            DateTimeOffset.UtcNow, pauseDuringGame: pausePolicy);
        var feed = new RuntimeSnapshotStore();
        var views = new RevisionedViewStore();
        var projector = new SchedulerProjector(db, views, runtimeSnapshot: feed);
        feed.Publish(new("", RuntimeQuality.Offline, null, Reason: "no-game-process"));
        await projector.ProjectOnceAsync();
        var view = views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!;
        Assert.Equal(new CountdownPresentation("RuntimeBackupOffline"), ScheduleCountdownPresentation.Resolve(view, DateTimeOffset.UtcNow));
        feed.Publish(RuntimeObservation.Unknown("runtime-preparing"));
        await projector.ProjectOnceAsync();
        view = views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!;
        Assert.NotEqual("RuntimeBackupOffline", ScheduleCountdownPresentation.Resolve(view, DateTimeOffset.UtcNow).MessageKey);
    }
}