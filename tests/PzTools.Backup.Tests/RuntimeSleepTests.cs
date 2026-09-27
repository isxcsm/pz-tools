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
    public void UnknownSleepCannotAdvanceClock_AndReanchorsWithoutCatchUp()
    {
        var state = Advance(new(1, 300_000, 300_000), Sample(0));
        state = Advance(state, Sample(120_000));
        state = Advance(state, Sample(180_000, RuntimeSleep.Unknown));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        Assert.True(state.Hold.HasFlag(ScheduleHold.Unknown));
        state = Advance(state, Sample(999_000));
        Assert.Equal(180_000, state.RemainingMilliseconds);
        Assert.Equal(179_000, Advance(state, Sample(1_000_000)).RemainingMilliseconds);
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

    [Theory]
    [InlineData(ScheduleHold.Unknown, "RuntimeBackupWaiting")]
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