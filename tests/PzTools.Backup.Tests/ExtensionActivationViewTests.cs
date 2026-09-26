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
        Assert.True(value.CanEditOptions);
        Assert.False(value.IsBusy);
        Assert.Null(value.AppliedVehicleOptions);
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
        Assert.True(Project(Card(), null, worldReady: false).CanEditOptions);
    }

    [Fact]
    public void PendingFirstActivationKeepsTheSavedRequestAndAllowsOffOrOptionChanges()
    {
        var value = Project(Card(enabled: true), new(RuntimeExtensionState.Pending, "safe-boundary",
            Process, World, Generation, RequestedRevision: 8, ControlReady: true));
        Assert.True(value.IsOn);
        Assert.True(value.IsBusy);
        Assert.True(value.CanToggle);
        Assert.True(value.CanEditOptions);
        Assert.Null(value.AppliedVehicleOptions);
    }

    [Fact]
    public void PendingUpdateKeepsLastGoodDiagnosticsWithoutLockingPreferenceControls()
    {
        var desired = Card(enabled: true) with { VehicleDrivetrain = new(false, true, false) };
        var value = Project(desired, Active() with { State = RuntimeExtensionState.Pending,
            Reason = "safe-boundary", AppliedRevision = 7 });
        Assert.True(value.IsOn);
        Assert.True(value.IsBusy);
        Assert.True(value.CanToggle);
        Assert.True(value.CanEditOptions);
        Assert.Equal(new VehicleDrivetrainPreference(true, false, true), value.AppliedVehicleOptions);
        Assert.NotEqual(desired.VehicleDrivetrain, value.AppliedVehicleOptions);
    }

    [Fact]
    public void SavedRequestBeforeWorkerAdmissionRemainsEditableWhileRuntimeIsBusy()
    {
        var initial = Project(Card(enabled: true), new(RuntimeExtensionState.Disabled,
            RequestedRevision: 7, ControlReady: true));
        Assert.True(initial.IsOn);
        Assert.True(initial.IsBusy);
        Assert.True(initial.CanToggle);
        Assert.True(initial.CanEditOptions);
        Assert.Null(initial.AppliedVehicleOptions);
        var update = Project(Card(enabled: true), Active() with { RequestedRevision = 7, AppliedRevision = 7 });
        Assert.True(update.IsOn);
        Assert.True(update.IsBusy);
        Assert.True(update.CanEditOptions);
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
        Assert.True(value.CanEditOptions);
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
        Assert.True(off.CanEditOptions);
        Assert.False(off.IsBusy);
        Assert.Equal("retirement-failed", off.FailureReason);
        var on = Project(Card(enabled: true), restart);
        Assert.True(on.IsOn);
        Assert.True(on.CanToggle); // A saved ON can still be switched OFF.
        Assert.True(Project(Card(), restart with { AgeMilliseconds = 3001 }).CanToggle);
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
    public void StaleOrUnavailableWorldDropsAppliedDiagnosticsWithoutHidingSavedOn()
    {
        foreach (var value in new[] { Project(Card(enabled: true), Active() with { AgeMilliseconds = 3001 }),
            Project(Card(enabled: true), Active(), worldReady: false),
            Project(Card(enabled: true), Active() with { AppliedVehicleOptions = null }) })
        {
            Assert.True(value.IsOn);
            Assert.True(value.CanToggle);
            Assert.True(value.CanEditOptions);
            Assert.Null(value.AppliedVehicleOptions);
        }
    }

    [Fact]
    public void OffRequestShowsSavedOffImmediatelyWhileRuntimeRetirementRemainsAHint()
    {
        var stopping = Project(Card(), Active());
        Assert.False(stopping.IsOn);
        Assert.True(stopping.IsBusy);
        Assert.True(stopping.CanToggle);
        Assert.True(stopping.CanEditOptions);
        Assert.NotNull(stopping.AppliedVehicleOptions);
        var stopped = Project(Card(), new(RuntimeExtensionState.Disabled, "user-disabled",
            RequestedRevision: 8, ControlReady: true));
        Assert.False(stopped.IsOn);
        Assert.False(stopped.IsBusy);
        Assert.True(stopped.CanToggle);
        Assert.True(stopped.CanEditOptions);
    }

    [Fact]
    public void ActiveCapabilityWithAllFeaturesOffRemainsAnActiveCapability()
    {
        var value = Project(Card(enabled: true), Active() with { AppliedVehicleOptions = new(false, false, false) });
        Assert.True(value.IsOn);
        Assert.True(value.CanToggle);
        Assert.True(value.CanEditOptions);
        Assert.Equal(new VehicleDrivetrainPreference(false, false, false), value.AppliedVehicleOptions);
    }

    [Fact]
    public void ActiveVersionMismatchCanAlwaysBeTurnedOff()
    {
        var value = Project(Card(enabled: true) with { VersionMatches = false }, Active());
        Assert.True(value.IsOn);
        Assert.True(value.CanToggle);
    }

    [Fact]
    public void SaveProviderIsAnExplicitPerSaveSelectionNotContinuousActivation()
    {
        var card = Card() with { Definition = Definition(ExtensionIds.SeamlessSave) };
        var unready = ExtensionActivationView.Project(card, true, false, Active());
        Assert.True(unready.IsPerSave);
        Assert.False(unready.IsOn);
        Assert.True(unready.CanToggle);
        Assert.True(unready.CanEditOptions);
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
        store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, false, new(false, true, false)), 0);
        var views = new RevisionedViewStore();
        var controller = new GameExtensionController(root, views, gameVersion: () => "42.20.0");
        var first = await controller.RefreshAsync();
        Assert.True(first.Cards.Single(x => x.Definition.Id == ExtensionIds.VehicleDrivetrain).Enabled);
        store.SetEnabled(ExtensionIds.VehicleDrivetrain, false, 1);
        await controller.RefreshRuntimeAsync(default);
        var latest = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0).Snapshot!;
        var card = latest.Cards.Single(x => x.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.False(card.Enabled);
        Assert.Equal(2, card.SettingsRevision);
        Assert.Equal(new VehicleDrivetrainPreference(false, true, false), card.VehicleDrivetrain);
    }

    [Fact]
    public async Task RuntimePendingDoesNotBlockOptionEditsOrAnOffRequest()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("runtime");
        var store = new ExtensionSettingsStore(root);
        var previous = new VehicleDrivetrainPreference(true, false, true);
        store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, false, previous), 0);
        var pending = Active() with { State = RuntimeExtensionState.Pending, Reason = "safe-boundary",
            AppliedRevision = 1, RequestedRevision = 2 };
        var controller = new GameExtensionController(root, new RevisionedViewStore(), gameVersion: () => "42.20.0",
            extensionStatus: () => pending, runtimeWorldReady: () => true);
        var initial = await controller.RefreshAsync();
        var card = initial.Cards.Single(x => x.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.True(initial.ActivationFor(card).IsBusy);
        Assert.True(initial.ActivationFor(card).CanEditOptions);
        var requested = new VehicleDrivetrainPreference(false, true, false);
        var edited = await controller.SetVehicleDrivetrainPreferenceAsync(requested, card.SettingsRevision);
        card = edited.Cards.Single(x => x.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.Equal(requested, card.VehicleDrivetrain);
        Assert.Equal(previous, edited.ActivationFor(card).AppliedVehicleOptions);
        Assert.True(edited.ActivationFor(card).CanToggle);
        var stopped = await controller.SetPreferenceAsync(card.Definition.Id, false, false, card.SettingsRevision);
        card = stopped.Cards.Single(x => x.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.False(stopped.ActivationFor(card).IsOn);
        Assert.True(stopped.ActivationFor(card).IsBusy);
        Assert.True(stopped.ActivationFor(card).CanEditOptions);
        Assert.False(store.Read().Extensions[card.Definition.Id].Enabled);
        Assert.Equal(requested, store.Read().Extensions[card.Definition.Id].VehicleDrivetrain);
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
        new(Definition(ExtensionIds.VehicleDrivetrain), enabled, "runtime-pending", revision);
    private static ExtensionDefinition Definition(string id) =>
        new(id, "0.2.0", "title", "description", "runtime-pending",
            [id == ExtensionIds.VehicleDrivetrain ? ExtensionCapabilities.VehicleDrivetrain : ExtensionCapabilities.SavePreparation]);
    private static RuntimeExtensionStatus Active() => new(RuntimeExtensionState.Active, null,
        Process, World, Generation, 8, "0.2.0", new string('a', 64), RequestedRevision: 8,
        ControlReady: true, AppliedVehicleOptions: new(true, false, true));
}
