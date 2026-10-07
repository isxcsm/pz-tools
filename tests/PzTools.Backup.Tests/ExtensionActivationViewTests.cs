using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class ExtensionActivationViewTests
{
    private const string Process = "11111111111111111111111111111111";
    private const string World = "22222222222222222222222222222222";
    private const string Generation = "33333333333333333333333333333333";

    [Fact]
    public void SavedVehiclePreferenceIsShownOfflineWithoutClaimingAppliedEvidence()
    {
        var value = Project(Card(enabled: true), null, worldReady: false);
        Assert.True(value.IsOn);
        Assert.True(value.CanToggle);
        Assert.False(value.IsBusy);
    }

    [Fact]
    public void EditingPreferencesDoesNotRequireAReadyControllerWorldOrKnownVersion()
    {
        var status = new RuntimeExtensionStatus(RuntimeExtensionState.Disabled, ControlReady: true);
        Assert.True(Project(Card(), status).CanToggle);
        Assert.True(Project(Card(), status with { ControlReady = false }).CanToggle);
        Assert.True(Project(Card(), status, worldReady: false).CanToggle);
        Assert.True(Project(Card() with { VersionMatches = false }, status).CanToggle);
        Assert.True(Project(Card() with { VersionMatches = false, ForceVersion = true }, status).CanToggle);
    }

    [Fact]
    public void PendingFirstActivationKeepsTheSavedRequestAndAllowsOffOrOptionChanges()
    {
        var value = Project(Card(enabled: true), new(RuntimeExtensionState.Pending, "safe-boundary",
            Process, World, Generation, RequestedRevision: 8, ControlReady: true));
        Assert.True(value.IsOn);
        Assert.True(value.IsBusy);
        Assert.True(value.CanToggle);
    }

    [Fact]
    public void PendingUpdateKeepsLastGoodDiagnosticsWithoutLockingPreferenceControls()
    {
        var desired = Card(enabled: true) with { Options = VehicleOptions.Of(false, true, false) };
        var value = Project(desired, Active() with { State = RuntimeExtensionState.Pending,
            Reason = "safe-boundary", AppliedRevision = 7 });
        Assert.True(value.IsOn);
        Assert.True(value.IsBusy);
        Assert.True(value.CanToggle);
    }

    [Fact]
    public void SavedRequestBeforeWorkerAdmissionRemainsEditableWhileRuntimeIsBusy()
    {
        var initial = Project(Card(enabled: true), new(RuntimeExtensionState.Disabled,
            RequestedRevision: 7, ControlReady: true));
        Assert.True(initial.IsOn);
        Assert.True(initial.IsBusy);
        Assert.True(initial.CanToggle);
        var update = Project(Card(enabled: true), Active() with { RequestedRevision = 7, AppliedRevision = 7 });
        Assert.True(update.IsOn);
        Assert.True(update.IsBusy);
    }

    [Theory]
    [InlineData(RuntimeExtensionState.Unsupported)]
    [InlineData(RuntimeExtensionState.FaultedPassThrough)]
    public void TransientFailureRemainsOffAfterRollbackButCanBeRetried(RuntimeExtensionState state)
    {
        var value = Project(Card(revision: 9), new(state, "initialization-failed",
            RequestedRevision: 8, ControlReady: false));
        Assert.False(value.IsOn);
        Assert.False(value.IsBusy);
        Assert.True(value.CanToggle);
        Assert.Equal("initialization-failed", value.FailureReason);
    }

    [Fact]
    public void CurrentProcessRestartRequirementBlocksOnButAllowsConfigurationAndOff()
    {
        var restart = new RuntimeExtensionStatus(RuntimeExtensionState.RestartRequired, "retirement-failed",
            Process, World, RequestedRevision: 8);
        var off = Project(Card(revision: 9), restart);
        Assert.False(off.IsOn);
        Assert.False(off.CanToggle);
        Assert.False(off.IsBusy);
        Assert.Equal("retirement-failed", off.FailureReason);
        var on = Project(Card(enabled: true), restart);
        Assert.True(on.IsOn);
        Assert.True(on.CanToggle); // A saved ON can still be switched OFF.
        Assert.True(Project(Card(), restart with { AgeMilliseconds = 3001 }).CanToggle);
        Assert.False(off.AwaitsGameRestart); // A restart forced by a failure is still reported as one.
    }

    [Fact]
    public void AnUpdateWaitingForTheGamesRestartIsARestartHintNotAFailure()
    {
        // Both the state stream (no process yet) and the coordinator (the bound game) report it.
        foreach (var update in new RuntimeExtensionStatus[] { new(RuntimeExtensionState.RestartRequired, "bootstrap-update"),
            new(RuntimeExtensionState.RestartRequired, "bootstrap-update", Process, World, RequestedRevision: 8) })
        {
            var on = Project(Card(enabled: true), update);
            Assert.True(on.AwaitsGameRestart);
            Assert.True(on.IsOn);        // The preference is kept for the next game ...
            Assert.True(on.CanToggle);   // ... and can still be switched off.
            Assert.False(on.IsBusy);
            Assert.True(Project(Card(), update).AwaitsGameRestart);
        }
        Assert.False(Project(Card(enabled: true), Active()).AwaitsGameRestart);
    }

    [Fact]
    public void FailureHintDoesNotInventAPreferenceRollbackBeforeItCommits()
    {
        var failure = new RuntimeExtensionStatus(RuntimeExtensionState.FaultedPassThrough, "activation-failed",
            Process, World, RequestedRevision: 8);
        Assert.True(Project(Card(enabled: true), failure).IsOn);
        Assert.False(Project(Card(enabled: false, revision: 9), failure).IsOn);
    }

    [Fact]
    public void StaleOrUnavailableWorldDropsAppliedEvidenceWithoutHidingSavedOn()
    {
        foreach (var (status, worldReady) in new[] { (Active() with { AgeMilliseconds = 3001 }, true), (Active(), false),
            (Active() with { AppliedConfiguration = null }, true) })
        {
            var value = Project(Card(enabled: true), status, worldReady);
            Assert.True(value.IsOn);
            Assert.True(value.CanToggle);
            // Without current evidence that the game runs what was asked for, a saved OFF has nothing left to wait for.
            Assert.False(Project(Card(), status, worldReady).IsBusy);
        }
    }

    [Fact]
    public void OffRequestShowsSavedOffImmediatelyWhileRuntimeRetirementRemainsAHint()
    {
        var stopping = Project(Card(), Active());
        Assert.False(stopping.IsOn);
        Assert.True(stopping.IsBusy);
        Assert.True(stopping.CanToggle);
        var stopped = Project(Card(), new(RuntimeExtensionState.Disabled, "user-disabled",
            RequestedRevision: 8, ControlReady: true));
        Assert.False(stopped.IsOn);
        Assert.False(stopped.IsBusy);
        Assert.True(stopped.CanToggle);
    }

    [Fact]
    public void AnyContinuousModuleTheGameRunsAsRequestedIsApplied_SoTurningItOffShowsProgress()
    {
        // The evidence is the digest of what the app sent, the same for every module; nothing about it is the vehicle's.
        var other = Card() with { Definition = Definition(VehicleDrivetrainExtension.Id) with { Id = "pztools.another-module" } };
        var stopping = Project(other, Active());
        Assert.False(stopping.IsOn);
        Assert.True(stopping.IsBusy);
        Assert.False(Project(other, Active() with { AppliedConfiguration = null }).IsBusy);
        var running = Project(other with { Enabled = true }, Active());
        Assert.True(running.IsOn);
        Assert.False(running.IsBusy);
    }

    [Fact]
    public void RunningGameOutsideTheSupportedRangeRefusesOnUnlessTheRangeIsIgnored()
    {
        // The game would reject the request with version-mismatch and the module would be saved off again.
        var outside = Card() with { GameVersion = "41.78", VersionMatches = false };
        Assert.False(Project(outside, null).CanToggle);
        Assert.True(Project(outside with { ForceVersion = true }, null).CanToggle);
        // An unknown version (no game running) still lets a desired ON be saved.
        Assert.True(Project(Card() with { VersionMatches = false }, null, worldReady: false).CanToggle);
        Assert.True(Project(Card() with { GameVersion = "42.20", VersionMatches = true }, null).CanToggle);
    }

    [Fact]
    public void ActiveVersionMismatchCanAlwaysBeTurnedOff()
    {
        var value = Project(Card(enabled: true) with { VersionMatches = false }, Active());
        Assert.True(value.IsOn);
        Assert.True(value.CanToggle);
        Assert.True(Project(Card(enabled: true) with { GameVersion = "41.78", VersionMatches = false }, Active()).CanToggle);
    }

    [Fact]
    public void SaveProviderIsAnExplicitPerSaveSelectionNotContinuousActivation()
    {
        var card = Card() with { Definition = Definition("pztools.test-save") };
        var unready = ExtensionActivationView.Project(card, true, false, Active());
        Assert.True(unready.IsPerSave);
        Assert.False(unready.IsOn);
        Assert.True(unready.CanToggle);
        Assert.True(ExtensionActivationView.Project(card, true, true, null).CanToggle);
        Assert.True(ExtensionActivationView.Project(card, false, true, null).CanToggle);
        var selected = ExtensionActivationView.Project(card with { Enabled = true }, false, false, null);
        Assert.True(selected.IsOn);
        Assert.True(selected.CanToggle); // OFF must remain possible when the game disappears.
    }

    [Fact]
    public async Task RuntimeRefreshReadsWorkerRollbackInsteadOfCachedDesiredPreference()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("runtime");
        var store = new ExtensionSettingsStore(root);
        store.SetPreference(VehicleDrivetrainExtension.Id, new(true, false, VehicleOptions.Of(false, true, false)), 0);
        var views = new RevisionedViewStore();
        var controller = new GameExtensionController(root, views, gameVersion: () => "42.20.0");
        var first = await controller.RefreshAsync();
        Assert.True(first.Cards.Single(x => x.Definition.Id == VehicleDrivetrainExtension.Id).Enabled);
        store.SetEnabled(VehicleDrivetrainExtension.Id, false, 1);
        await controller.RefreshRuntimeAsync(default);
        var latest = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0).Snapshot!;
        var card = latest.Cards.Single(x => x.Definition.Id == VehicleDrivetrainExtension.Id);
        Assert.False(card.Enabled);
        Assert.Equal(2, card.SettingsRevision);
        VehicleOptions.AssertSame(VehicleOptions.Of(false, true, false), card.Options);
    }

    [Fact]
    public async Task RuntimePendingDoesNotBlockOptionEditsOrAnOffRequest()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("runtime");
        var store = new ExtensionSettingsStore(root);
        var previous = VehicleOptions.Of(true, false, true);
        store.SetPreference(VehicleDrivetrainExtension.Id, new(true, false, previous), 0);
        var pending = Active() with { State = RuntimeExtensionState.Pending, Reason = "safe-boundary",
            AppliedRevision = 1, RequestedRevision = 2 };
        var controller = new GameExtensionController(root, new RevisionedViewStore(), gameVersion: () => "42.20.0",
            extensionStatus: _ => pending, runtimeWorldReady: () => true);
        var initial = await controller.RefreshAsync();
        var card = initial.Cards.Single(x => x.Definition.Id == VehicleDrivetrainExtension.Id);
        Assert.True(initial.ActivationFor(card).IsBusy);
        var requested = VehicleOptions.Of(false, true, false);
        GameExtensionsView edited = initial;
        foreach (var (key, value) in requested)
            edited = await controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, key, value);
        card = edited.Cards.Single(x => x.Definition.Id == VehicleDrivetrainExtension.Id);
        VehicleOptions.AssertSame(requested, card.Options);
        Assert.True(edited.ActivationFor(card).CanToggle);
        var stopped = await controller.ApplyEditAsync(card.Definition.Id, GameExtensionSetting.Enabled, false);
        card = stopped.Cards.Single(x => x.Definition.Id == VehicleDrivetrainExtension.Id);
        Assert.False(stopped.ActivationFor(card).IsOn);
        Assert.True(stopped.ActivationFor(card).IsBusy);
        Assert.False(store.Read().Extensions[card.Definition.Id].Enabled);
        VehicleOptions.AssertSame(requested, store.Read().Extensions[card.Definition.Id].Options);
    }

    [Fact]
    public async Task RuntimeReadinessChangePublishesAViewWithoutChangingSettings()
    {
        using var temp = new TempDirectory();
        var views = new RevisionedViewStore();
        var ready = false;
        var controller = new GameExtensionController(temp.GetPath("runtime"), views, runtimeWorldReady: () => ready);
        await controller.RefreshAsync();
        var first = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0);
        ready = true;
        await controller.RefreshRuntimeAsync(default);
        var changed = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, first.ViewRevision);
        Assert.True(changed.Modified);
        Assert.True(changed.Snapshot!.RuntimeWorldReady);
    }

    private static ExtensionActivationView Project(ExtensionCardView card, RuntimeExtensionStatus? runtime,
        bool worldReady = true) => ExtensionActivationView.Project(card, true, worldReady, runtime);
    private static ExtensionCardView Card(bool enabled = false, long revision = 8) =>
        new(Definition(VehicleDrivetrainExtension.Id), enabled, "runtime-pending", revision);
    private static ExtensionDefinition Definition(string id) =>
        new(id, "0.2.0", "title", "description", "runtime-pending",
            [id == VehicleDrivetrainExtension.Id ? ExtensionCapabilities.Continuous : ExtensionCapabilities.SavePreparation]);
    private static RuntimeExtensionStatus Active() => new(RuntimeExtensionState.Active, null,
        Process, World, Generation, 8, "0.2.0", new string('a', 64), RequestedRevision: 8,
        ControlReady: true, AppliedConfiguration: new string('e', 64));
}
