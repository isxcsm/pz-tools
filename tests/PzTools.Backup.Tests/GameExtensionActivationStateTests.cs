using System.Text.Json;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionActivationStateTests
{
    private static readonly string Process = new('a', 32), World = new('b', 32), Generation = new('c', 32);
    private static readonly RuntimeVehicleOptions First = new(true, false, true), Second = new(false, true, false);
    private static RuntimeExtensionStatus Active(long revision, string? reason = null) => new(RuntimeExtensionState.Active,
        reason, Process, World, Generation, revision, "0.1.0", new string('d', 64));
    private static RuntimeExtensionStatus Pending(long revision) => Active(revision) with { State = RuntimeExtensionState.Pending, Reason = "safe-boundary" };
    private static GameExtensionActivationState Bound()
    {
        var state = new GameExtensionActivationState();
        Assert.True(state.Bind(Process, World));
        return state;
    }

    [Fact]
    public void RuntimeContractDefaultsDoNotClaimAppliedFeaturesAndMetadataRoundTrips()
    {
        var legacy = new RuntimeExtensionStatus(RuntimeExtensionState.Disabled).Validate();
        Assert.False(legacy.ControlReady); Assert.Null(legacy.AppliedVehicleOptions); Assert.Equal(-1, legacy.RequestedRevision);
        var applied = Active(4) with { RequestedRevision = 5, ControlReady = true, AppliedVehicleOptions = First };
        Assert.Equal(applied, JsonSerializer.Deserialize<RuntimeExtensionStatus>(JsonSerializer.Serialize(applied))!.Validate());
        Assert.Throws<InvalidDataException>(() => (legacy with { RequestedRevision = -2 }).Validate());
        Assert.Throws<InvalidDataException>(() => (legacy with { ControlReady = true }).Validate());
        Assert.Throws<InvalidDataException>(() => (legacy with { AppliedVehicleOptions = First }).Validate());
        Assert.Throws<InvalidDataException>(() => (applied with { State = RuntimeExtensionState.FaultedPassThrough }).Validate());
    }

    [Fact]
    public void FirstPendingRequestIsNotAnAppliedFeatureSnapshot()
    {
        var state = Bound(); state.RecordRequest(1, First);
        var waiting = state.Observe(Pending(-1), 1);
        Assert.True(waiting.ControlReady); Assert.Null(waiting.AppliedVehicleOptions);
        Assert.Equal(1, waiting.RequestedRevision);
        Assert.False(GameExtensionActivationState.IsDefinitiveFailure(waiting, requestRejected: false));
    }

    [Fact]
    public void OnlyAcknowledgedRevisionChangesAppliedOptionsAndPendingRetainsTheOldValues()
    {
        var state = Bound(); state.RecordRequest(1, First);
        var first = state.Observe(Active(1), 1);
        Assert.Equal(First, first.AppliedVehicleOptions);
        state.RecordRequest(2, Second);
        var waiting = state.Observe(Pending(1), 2);
        Assert.Equal(First, waiting.AppliedVehicleOptions); Assert.Equal(1, waiting.AppliedRevision);
        Assert.Equal(2, waiting.RequestedRevision);
        var applied = state.Observe(Active(2), 2);
        Assert.Equal(Second, applied.AppliedVehicleOptions);
    }

    [Fact]
    public void OldActiveRejectionNeverClaimsTheRequestedValuesAndIsAnExplicitFailure()
    {
        var state = Bound(); state.RecordRequest(1, First); state.Observe(Active(1), 1);
        state.RecordRequest(2, Second);
        var rejected = state.Observe(Active(1, "update-rejected:preflight"), 2);
        Assert.Equal(First, rejected.AppliedVehicleOptions);
        Assert.True(GameExtensionActivationState.IsDefinitiveFailure(rejected, requestRejected: true));
    }

    [Fact]
    public void AcknowledgementOfAnEarlierPendingRequestIsMappedToItsOwnOptions()
    {
        var state = Bound(); state.RecordRequest(1, First); state.RecordRequest(2, Second);
        var earlier = state.Observe(Active(1), 2);
        Assert.Equal(First, earlier.AppliedVehicleOptions);
        Assert.Equal(2, earlier.RequestedRevision);
    }

    [Fact]
    public void GenerationChangeOrDisconnectDropsPreviousAppliedEvidence()
    {
        var state = Bound(); state.RecordRequest(1, First); state.Observe(Active(1), 1);
        Assert.Null(state.Observe(Pending(1) with { Generation = new string('e', 32) }, 2).AppliedVehicleOptions);
        state.Disconnect();
        Assert.Null(state.Observe(Active(1), 2).AppliedVehicleOptions);
    }

    [Fact]
    public void DisabledHandshakeIsReadyButNeverShowsOldAppliedFeatures()
    {
        var state = Bound(); state.RecordRequest(1, First); state.Observe(Active(1), 1);
        var disabled = state.Observe(new(RuntimeExtensionState.Disabled, "user-disabled", Process), 2);
        Assert.True(disabled.ControlReady); Assert.Null(disabled.AppliedVehicleOptions);
        Assert.Equal(World, disabled.WorldSession); Assert.Equal(2, disabled.RequestedRevision);
    }

    [Fact]
    public void FailureDisablesOnlyTheExactRevisionAndPreservesOtherPreferences()
    {
        using var temp = new TempDirectory(); var store = new ExtensionSettingsStore(temp.Path);
        var options = new VehicleDrivetrainPreference(true, false, true);
        var requested = store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, true, options), 0);
        var state = Bound(); state.RecordRequest(requested.Revision, First);
        Assert.True(state.FailClosed(Active(-1) with { State = RuntimeExtensionState.Unsupported,
                Reason = "update-rejected:preflight" }, requested.Revision, () => true,
            revision => store.SetEnabled(ExtensionIds.VehicleDrivetrain, false, revision).Revision));
        var committed = store.Read(); var preference = committed.Extensions[ExtensionIds.VehicleDrivetrain];
        Assert.False(preference.Enabled); Assert.True(preference.ForceVersion); Assert.Equal(options, preference.VehicleDrivetrain);
        var failure = state.Blocked(committed.Revision)!;
        Assert.False(failure.ControlReady); Assert.Null(failure.AppliedVehicleOptions);
        Assert.Equal(requested.Revision, failure.RequestedRevision);
        Assert.Null(state.Blocked(committed.Revision + 1));
    }

    [Fact]
    public void ConcurrentNewPreferenceCannotBeOverwrittenByAnOlderFailure()
    {
        using var temp = new TempDirectory(); var store = new ExtensionSettingsStore(temp.Path);
        var requested = store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, false, new(true, false, true)), 0);
        var newerOptions = new VehicleDrivetrainPreference(false, true, false);
        var state = Bound();
        state.FailClosed(Active(-1) with { State = RuntimeExtensionState.Unsupported }, requested.Revision, () => true, expected =>
        {
            store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, true, newerOptions), expected);
            try { return store.SetEnabled(ExtensionIds.VehicleDrivetrain, false, expected).Revision; }
            catch (ExtensionSettingsConflictException) { return null; }
        });
        var current = store.Read();
        Assert.True(current.Extensions[ExtensionIds.VehicleDrivetrain].Enabled);
        Assert.True(current.Extensions[ExtensionIds.VehicleDrivetrain].ForceVersion);
        Assert.Equal(newerOptions, current.Extensions[ExtensionIds.VehicleDrivetrain].VehicleDrivetrain);
        Assert.Null(state.Blocked(current.Revision));
    }

    [Fact]
    public void StaleOrOfflineWorldCannotRunTheRollbackCallback()
    {
        var state = Bound(); int writes = 0;
        Assert.False(state.FailClosed(Active(1, "update-rejected"), 2, () => false, _ => { writes++; return 3; }));
        Assert.Equal(0, writes); Assert.Null(state.Failure); Assert.Null(state.Blocked(2));
    }

    [Fact]
    public void ForeignWorldAndProcessResponsesAreNeverAttributedToCurrentSettings()
    {
        var state = Bound(); int writes = 0;
        foreach (var other in new[] { Active(1) with { WorldSession = new string('f', 32) }, Active(1) with { ProcessSession = new string('f', 32) } })
        {
            Assert.Throws<ExtensionSessionMismatchException>(() => state.Observe(other, 2));
            Assert.Throws<ExtensionSessionMismatchException>(() => state.FailClosed(other, 2, () => true, _ => { writes++; return 3; }));
        }
        Assert.Equal(0, writes); Assert.Null(state.Failure);
    }

    [Fact]
    public void FailedRevisionRemainsLockedAcrossDisconnectButANewWorldResetsIt()
    {
        var state = Bound();
        state.FailClosed(Active(1) with { State = RuntimeExtensionState.FaultedPassThrough, Reason = "activation-failed" }, 2, () => true, _ => 3);
        state.Disconnect(); Assert.False(state.Bind(Process, World)); Assert.NotNull(state.Blocked(3));
        Assert.True(state.Bind(Process, new string('f', 32))); Assert.Null(state.Blocked(3)); Assert.Null(state.Failure);
        Assert.Null(state.Observe(new(RuntimeExtensionState.Disabled, null, Process), 3).AppliedVehicleOptions);
    }

    [Fact]
    public void RestartRequiredSurvivesRevisionsReconnectAndWorldChangesInTheSameProcess()
    {
        var state = Bound();
        state.FailClosed(Active(1) with { State = RuntimeExtensionState.RestartRequired, Reason = "retirement-failed" },
            2, () => true, _ => 3);
        Assert.NotNull(state.Blocked(3)); Assert.NotNull(state.Blocked(4)); Assert.NotNull(state.Blocked(100));
        state.Disconnect();
        Assert.False(state.Bind(Process, World));
        Assert.Equal(RuntimeExtensionState.RestartRequired, state.Observe(new(RuntimeExtensionState.Disabled, null, Process), 4).State);
        var nextWorld = new string('f', 32);
        Assert.True(state.Bind(Process, nextWorld));
        var locked = state.Blocked(100)!;
        Assert.Equal(RuntimeExtensionState.RestartRequired, locked.State);
        Assert.Equal(Process, locked.ProcessSession); Assert.Equal(nextWorld, locked.WorldSession);
        Assert.Equal(2, locked.RequestedRevision); Assert.False(locked.ControlReady); Assert.Null(locked.AppliedVehicleOptions);
        Assert.Equal(locked, state.Observe(new(RuntimeExtensionState.Disabled, null, Process), 100));
    }

    [Fact]
    public void OnlyANewProcessClearsRestartRequiredAndAllowsReadinessAgain()
    {
        var state = Bound();
        state.FailClosed(Active(1) with { State = RuntimeExtensionState.RestartRequired }, 2, () => true, _ => 3);
        var nextProcess = new string('e', 32);
        Assert.True(state.Bind(nextProcess, World));
        Assert.Null(state.Failure); Assert.Null(state.Blocked(3)); Assert.Null(state.Blocked(4));
        var ready = state.Observe(new(RuntimeExtensionState.Disabled, null, nextProcess), 4);
        Assert.True(ready.ControlReady); Assert.Equal(RuntimeExtensionState.Disabled, ready.State);
        Assert.Null(ready.AppliedVehicleOptions);
    }

    [Fact]
    public void LaterFailureCannotDowngradeRestartRequiredOrWriteAnotherRevision()
    {
        var state = Bound();
        state.FailClosed(Active(1) with { State = RuntimeExtensionState.RestartRequired, Reason = "retirement-failed" },
            2, () => true, _ => 3);
        int writes = 0;
        Assert.True(state.FailClosed(Active(1) with { State = RuntimeExtensionState.Unsupported },
            4, () => true, _ => { writes++; return 5; }));
        Assert.Equal(0, writes); Assert.Equal("retirement-failed", state.Failure!.Reason);
        Assert.Equal(RuntimeExtensionState.RestartRequired, state.Blocked(5)!.State);
    }

    [Fact]
    public void SameProcessRestartRequiredFromAnOlderWorldIsNormalizedButOtherFailuresAreRejected()
    {
        var state = Bound();
        var previousWorld = new string('f', 32);
        var poisoned = Active(1) with { State = RuntimeExtensionState.RestartRequired, WorldSession = previousWorld,
            Reason = "retirement-failed" };
        state.VerifyTarget(poisoned, 2);
        var observed = state.Observe(poisoned, 2);
        Assert.False(observed.ControlReady); Assert.Equal(World, observed.WorldSession);
        Assert.True(state.FailClosed(poisoned, 2, () => true, _ => 3));
        Assert.Equal(World, state.Blocked(3)!.WorldSession);
        Assert.Equal(Process, state.Blocked(3)!.ProcessSession);
        Assert.False(state.Blocked(3)!.ControlReady);
        Assert.Throws<ExtensionSessionMismatchException>(() => state.VerifyTarget(poisoned with { ProcessSession = new string('e', 32) }, 4));
        foreach (var other in new[] { RuntimeExtensionState.Active, RuntimeExtensionState.Pending,
            RuntimeExtensionState.Disabled, RuntimeExtensionState.Unsupported, RuntimeExtensionState.FaultedPassThrough })
            Assert.Throws<ExtensionSessionMismatchException>(() => state.VerifyTarget(poisoned with { State = other }, 4));
    }

    [Theory]
    [InlineData(RuntimeExtensionState.Unsupported)]
    [InlineData(RuntimeExtensionState.FaultedPassThrough)]
    [InlineData(RuntimeExtensionState.RestartRequired)]
    public void DefinitiveFailureCannotMasqueradeAsSuccessfulOff(RuntimeExtensionState failureState)
    {
        var state = Bound(); var actual = Active(1) with { State = failureState, Reason = "initialization-failed" };
        Assert.True(GameExtensionActivationState.IsDefinitiveFailure(actual, false));
        state.FailClosed(actual, 2, () => true, _ => 3);
        Assert.Equal(failureState, state.Failure!.State);
        Assert.False(state.Failure.ControlReady); Assert.Null(state.Failure.AppliedVehicleOptions);
    }

    [Fact]
    public async Task ReconcilerExposesRejectionSeparatelyFromAnAcceptedPendingRequest()
    {
        var accepted = new ReplySession(Pending(-1));
        var state = new GameExtensionReconciler(new(RuntimeExtensionState.Disabled));
        await state.ReconcileAsync(accepted, Process, World, 1, ExtensionIds.VehicleDrivetrain, false,
            () => new Dictionary<string, string>(), default);
        Assert.False(state.RequestRejected);
        var rejected = new ReplySession(Active(1, "update-rejected"));
        await state.ReconcileAsync(rejected, Process, World, 2, ExtensionIds.VehicleDrivetrain, false,
            () => new Dictionary<string, string>(), default);
        Assert.True(state.RequestRejected);
    }

    private sealed class ReplySession(RuntimeExtensionStatus reply) : IGameExtensionSession
    {
        public Task<RuntimeExtensionStatus> StatusAsync(CancellationToken token) => Task.FromResult(reply);
        public Task<RuntimeExtensionStatus> PingAsync(CancellationToken token) => Task.FromResult(reply);
        public Task<RuntimeExtensionStatus> ApplyAsync(string processSession, string worldSession, long expectedRevision, long revision,
            string moduleId, bool forceVersion, IReadOnlyDictionary<string, string> configuration, CancellationToken token) => Task.FromResult(reply);
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
