using PzTools.App.Core;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Backup.Tests;

public sealed class ExtensionRuntimeStatusSelectionTests
{
    private static readonly string Process = new('a', 32), World = new('b', 32), Other = new('c', 32);

    [Fact]
    public void DisabledReadinessRequiresTheCurrentProcessAndWorldWithoutAnAppliedRevision()
    {
        var ready = new RuntimeExtensionStatus(RuntimeExtensionState.Disabled, "user-disabled", Process, World,
            RequestedRevision: 4, ControlReady: true);
        Assert.Equal(-1, ready.AppliedRevision);
        Assert.True(Select(ready).ControlReady);
        AssertUnavailable(Select(ready with { ProcessSession = Other }));
        AssertUnavailable(Select(ready with { WorldSession = Other }));
    }

    [Theory]
    [InlineData(RuntimeExtensionState.Active)]
    [InlineData(RuntimeExtensionState.Pending)]
    public void AppliedOrPendingOptionsFromAnotherWorldAreNotProjected(RuntimeExtensionState state)
    {
        var status = new RuntimeExtensionStatus(state, ProcessSession: Process, WorldSession: Other,
            Generation: new string('d', 32), AppliedRevision: 3, ModuleVersion: "0.2.0", ModuleHash: new string('e', 64),
            RequestedRevision: 4, ControlReady: true, AppliedVehicleOptions: new(true, false, true));
        AssertUnavailable(Select(status));
    }

    [Fact]
    public void StaleObservationOrGameSampleCannotGrantReadiness()
    {
        var status = new RuntimeExtensionStatus(RuntimeExtensionState.Disabled, ProcessSession: Process,
            WorldSession: World, RequestedRevision: 4, ControlReady: true);
        var observation = Observation(status);
        AssertUnavailable(ExtensionActivationView.SelectCurrentStatus(observation with { Quality = RuntimeQuality.Stale })!);
        AssertUnavailable(ExtensionActivationView.SelectCurrentStatus(observation with { AgeMilliseconds = 2001 })!);
        AssertUnavailable(ExtensionActivationView.SelectCurrentStatus(observation with
        {
            Snapshot = observation.Snapshot! with { SampleAgeMilliseconds = 2001 },
        })!);
    }

    [Fact]
    public void MenuOrLoadingWorldCannotGrantDisabledReadiness()
    {
        var status = new RuntimeExtensionStatus(RuntimeExtensionState.Disabled, ProcessSession: Process,
            WorldSession: World, RequestedRevision: 4, ControlReady: true);
        var observation = Observation(status);
        AssertUnavailable(ExtensionActivationView.SelectCurrentStatus(observation with
        {
            Snapshot = observation.Snapshot! with { Phase = WorldPhase.Loading },
        })!);
    }

    [Fact]
    public void ExtensionFreshnessHasItsOwnBoundAndAgeDoesNotCreateViewChanges()
    {
        var status = new RuntimeExtensionStatus(RuntimeExtensionState.Disabled, ProcessSession: Process,
            WorldSession: World, RequestedRevision: 4, ControlReady: true);
        Assert.Equal(status, Select(status with { AgeMilliseconds = 3000 }));
        Assert.Null(ExtensionActivationView.SelectCurrentStatus(Observation(status with { AgeMilliseconds = 3001 })));
        Assert.Null(ExtensionActivationView.SelectCurrentStatus(Observation(null)));
    }

    [Fact]
    public void RestartRequiredFollowsTheSameProcessAcrossWorldChanges()
    {
        var failure = new RuntimeExtensionStatus(RuntimeExtensionState.RestartRequired, "retirement-failed",
            Process, Other, Generation: new string('d', 32), AppliedRevision: 3, RequestedRevision: 4,
            AgeMilliseconds: 10);
        var selected = Select(failure);
        Assert.Equal(RuntimeExtensionState.RestartRequired, selected.State);
        Assert.Equal(World, selected.WorldSession);
        Assert.Equal(failure.Generation, selected.Generation);
        Assert.Equal(failure.RequestedRevision, selected.RequestedRevision);
        Assert.Equal(failure.Reason, selected.Reason);
        Assert.False(selected.ControlReady);
        Assert.Null(selected.AppliedVehicleOptions);
        Assert.Equal(0, selected.AgeMilliseconds);
        var menu = Observation(failure);
        Assert.Equal(RuntimeExtensionState.RestartRequired, ExtensionActivationView.SelectCurrentStatus(menu with
        {
            Snapshot = menu.Snapshot! with { Phase = WorldPhase.Menu, SavePath = null },
        })!.State);
    }

    [Fact]
    public void RestartRequiredNeverTransfersToAnotherProcessOrAStaleObservation()
    {
        var status = new RuntimeExtensionStatus(RuntimeExtensionState.RestartRequired, "retirement-failed", Other, World);
        AssertUnavailable(Select(status));
        AssertUnavailable(ExtensionActivationView.SelectCurrentStatus(Observation(status with { ProcessSession = Process })
            with { Quality = RuntimeQuality.Stale })!);
    }

    [Fact]
    public void OrdinaryFailureDoesNotTransferToAnotherWorld()
    {
        AssertUnavailable(Select(new(RuntimeExtensionState.FaultedPassThrough, "activation-failed", Process, Other)));
    }

    [Fact]
    public void UnscopedStartupDiagnosticsRemainVisibleButCannotGrantReadiness()
    {
        var status = new RuntimeExtensionStatus(RuntimeExtensionState.RestartRequired, "bootstrap-update", AgeMilliseconds: 10);
        var selected = ExtensionActivationView.SelectCurrentStatus(RuntimeObservation.Unknown() with { Extension = status });
        Assert.Equal(status with { AgeMilliseconds = 0 }, selected);
        Assert.False(selected!.ControlReady);
        Assert.Null(selected.AppliedVehicleOptions);
    }

    private static RuntimeExtensionStatus Select(RuntimeExtensionStatus status) =>
        ExtensionActivationView.SelectCurrentStatus(Observation(status))!;

    private static RuntimeObservation Observation(RuntimeExtensionStatus? status) => new(new string('f', 32), RuntimeQuality.Fresh,
        new(Process, new string('1', 32), World, 0, 0, 1, WorldPhase.Ready, GamePause.Running,
            RuntimeMode.LocalSinglePlayer, 1, 0, 0, "C:/saves/test"), Extension: status);

    private static void AssertUnavailable(RuntimeExtensionStatus status)
    {
        Assert.Equal(RuntimeExtensionState.Pending, status.State);
        Assert.Equal("waiting-for-local-world", status.Reason);
        Assert.False(status.ControlReady);
        Assert.Null(status.AppliedVehicleOptions);
        Assert.Equal(-1, status.AppliedRevision);
    }
}
