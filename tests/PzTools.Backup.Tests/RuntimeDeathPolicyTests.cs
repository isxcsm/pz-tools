using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Scheduling;
using PzTools.App.Core;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class RuntimeDeathPolicyTests
{
    private static string Id() => Guid.NewGuid().ToString("N");
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DeathIsIndependentOfPeriodicPause_AndOneEpisodeDoesNotReplay(bool pausePolicy)
    {
        using var temp = new TempDirectory();
        var db = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var target = new BackupTarget("Sandbox/world", "Sandbox/world", temp.GetPath("world"));
        var now = DateTimeOffset.UtcNow;
        await db.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), now, pauseDuringGame: pausePolicy);
        var feed = new RuntimeSnapshotStore(); var controller = new RuntimeScheduleController(db, feed);
        var s = new RuntimeSnapshot(Id(), Id(), Id(), 1, 1, 1, WorldPhase.Ready, GamePause.Paused,
            RuntimeMode.LocalSinglePlayer, 0, 0, 0, target.SourcePath, "42.20", RuntimeCharacterLife.Alive, Id());
        var authority = Id(); long revision = 0;
        async Task Publish(RuntimeSnapshot sample, bool enabled = true)
        {
            var o = new RuntimeObservation(Id(), RuntimeQuality.Fresh, sample, ++revision, AuthorityEpoch: authority);
            await db.ApplyRuntimeTransitionAsync(o, target, backupOnDeath: enabled); feed.Publish(o);
        }
        await Publish(s);
        s = s with { CharacterLife = RuntimeCharacterLife.Dead, DeathId = Id(), Sequence = 2 };
        await Publish(s);
        var selected = await controller.PrepareAsync(now, TimeSpan.Zero, default);
        var admission = Assert.IsType<BackupTickAdmission>(selected.Admission);
        Assert.True(selected.Enabled); Assert.Equal(BackupAdmissionKind.RunOnce, admission.Kind);
        Assert.True(admission.RuntimeTicket!.IsDeath); Assert.True(admission.RuntimeTicket.MatchesDeath(s));
        Assert.Equal(admission.RuntimeTicket, RuntimeSaveTicket.Parse(admission.RuntimeTicket.Encode()));
        await db.FinishBackupTickAsync(admission, true, 1, ProcessOutcome.Skipped, now);
        var retry = (await controller.PrepareAsync(now, TimeSpan.Zero, default)).Admission!;
        Assert.NotEqual(admission.AdmissionId, retry.AdmissionId);
        Assert.Equal(admission.RuntimeTicket.DeathId, retry.RuntimeTicket!.DeathId);
        await db.FinishBackupTickAsync(retry, true, 2, ProcessOutcome.Succeeded, now);
        await Publish(s with { ObserverEpoch = Id(), Sequence = 3 });
        Assert.Null((await controller.PrepareAsync(now, TimeSpan.Zero, default)).Admission);
        Assert.Equal(0, (await db.ReadBackupStateIfChangedAsync(-1)).PendingRuns);
        // A new character's death is a new episode, not a permanent suppression of this world.
        s = s with { CharacterSession = Id(), DeathId = Id(), ObserverEpoch = Id(), Sequence = 4 };
        await Publish(s);
        Assert.NotNull((await controller.PrepareAsync(now, TimeSpan.Zero, default)).Admission);
    }
    [Fact]
    public async Task DisabledDeathsAreConsumedAndNewCharacterInvalidatesPendingWork()
    {
        using var temp = new TempDirectory();
        var db = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var target = new BackupTarget("world", "world", temp.GetPath("world"));
        await db.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow);
        var s = new RuntimeSnapshot(Id(), Id(), Id(), 0, 0, 1, WorldPhase.Ready, GamePause.Running,
            RuntimeMode.LocalSinglePlayer, 1, 0, 0, target.SourcePath, CharacterLife: RuntimeCharacterLife.Dead, CharacterSession: Id(), DeathId: Id());
        var authority = Id(); long revision = 0;
        async Task Apply(RuntimeSnapshot sample, bool enabled, RuntimeQuality quality = RuntimeQuality.Fresh)
            => await db.ApplyRuntimeTransitionAsync(new(Id(), quality, sample, ++revision, AuthorityEpoch: authority), target, backupOnDeath: enabled);
        await db.EnqueueTargetCommandAsync(new("state-transition:legacy-death", BackupTargetCommandKind.RunOnceNow, target));
        Assert.Null(await db.PrepareBackupTickAsync(DateTimeOffset.UtcNow));
        await Apply(s, false); await Apply(s, true);
        Assert.Null(await db.PrepareBackupTickAsync(DateTimeOffset.UtcNow));
        await db.ConfigureBackupAsync(temp.GetPath("repo"), false, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow);
        s = s with { DeathId = Id() }; await Apply(s, true);
        await db.ConfigureBackupAsync(temp.GetPath("repo"), true, TimeSpan.FromMinutes(5), DateTimeOffset.UtcNow);
        await Apply(s, true); Assert.Null(await db.PrepareBackupTickAsync(DateTimeOffset.UtcNow));
        s = s with { DeathId = Id() };
        await Apply(s, true, RuntimeQuality.Stale);
        Assert.Null(await db.PrepareBackupTickAsync(DateTimeOffset.UtcNow));
        await Apply(s, true);
        Assert.NotNull(await db.PrepareBackupTickAsync(DateTimeOffset.UtcNow));
        await Apply(s with { CharacterLife = RuntimeCharacterLife.Alive, CharacterSession = Id(), DeathId = null }, true);
        Assert.Null(await db.PrepareBackupTickAsync(DateTimeOffset.UtcNow));
        Assert.Equal(0, (await db.ReadBackupStateIfChangedAsync(-1)).PendingRuns);
    }
    [Fact]
    public async Task ExecutionProjectionDoesNotChangePreferences_AndCanClearAStaleResult()
    {
        using var temp = new TempDirectory(); var views = new RevisionedViewStore();
        RuntimeSaveExecution? last = null;
        var controller = new GameExtensionController(temp.Path, views, lastSave: () => last);
        Assert.False(Assert.Single((await controller.RefreshAsync()).Cards).Enabled);
        last = new(Id(), Id(), Id(), "pztools.seamless-save", "pztools.standard-save", RuntimeSaveOutcome.Succeeded, "unsupported-game-build", 25, 30);
        await controller.RefreshRuntimeAsync(default);
        var view = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0).Snapshot!;
        Assert.Equal(last, view.LastSave); Assert.False(Assert.Single(view.Cards).Enabled);
        last = null; await controller.RefreshRuntimeAsync(default);
        Assert.Null(views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0).Snapshot!.LastSave);
    }
}