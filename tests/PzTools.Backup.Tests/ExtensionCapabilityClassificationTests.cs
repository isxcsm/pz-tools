using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Backup.Tests;

public sealed class ExtensionCapabilityClassificationTests
{
    [Theory]
    [InlineData(ExtensionCapabilities.SavePreparation, ExtensionActivationKind.PerSave)]
    [InlineData(ExtensionCapabilities.VehicleDrivetrain, ExtensionActivationKind.Continuous)]
    public void ARecognizedSingleCapabilityDeterminesBehaviorIndependentlyOfIdentity(string capability, ExtensionActivationKind expected)
    {
        foreach (var id in new[] { ExtensionIds.SeamlessSave, ExtensionIds.VehicleDrivetrain, "pztools.another-extension" })
            Assert.Equal(expected, Definition(id, [capability]).ActivationKind);
    }

    public static IEnumerable<object?[]> UnsupportedCapabilities()
    {
        yield return [null];
        yield return [Array.Empty<string>()];
        yield return [new[] { "" }];
        yield return [new[] { "unknown.feature.v1" }];
        yield return [new[] { "SAVE.PREPARE.V1" }];
        yield return [new[] { ExtensionCapabilities.SavePreparation, ExtensionCapabilities.VehicleDrivetrain }];
        yield return [new[] { ExtensionCapabilities.SavePreparation, ExtensionCapabilities.SavePreparation }];
        yield return [new[] { ExtensionCapabilities.SavePreparation, "unknown.feature.v1" }];
    }

    [Theory]
    [MemberData(nameof(UnsupportedCapabilities))]
    public void MissingUnknownDuplicateAndCompositeCapabilitiesAreFailClosed(string[]? capabilities)
    {
        var definition = Definition(ExtensionIds.VehicleDrivetrain, capabilities!);
        Assert.Equal(ExtensionActivationKind.Unsupported, definition.ActivationKind);
        var card = new ExtensionCardView(definition, true, "runtime-pending", 4, ForceVersion: true);
        Assert.False(card.CanEnable);
        Assert.False(card.EffectiveEnabled);
        var view = new GameExtensionsView([card], true, VehicleStatus: Active(), RuntimeWorldReady: true);
        var activation = view.ActivationFor(card);
        Assert.False(activation.IsOn);
        Assert.False(activation.IsPerSave);
        Assert.False(activation.IsBusy);
        Assert.False(activation.CanToggle);
        Assert.False(activation.CanEditOptions);
        Assert.Null(activation.AppliedVehicleOptions);
        Assert.Equal("unsupported-capability", activation.FailureReason);
    }

    [Fact]
    public void ForceVersionCannotBypassUnsupportedCapabilityAdmission()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var definition = Definition("pztools.unknown-extension", ["unknown.feature.v1"]);
        var service = new GameExtensionService(store, () => "42.20.0", () => [definition]);
        Assert.Throws<InvalidDataException>(() => service.SetEnabled(definition.Id, true, 0));
        Assert.Throws<InvalidDataException>(() => service.SetPreference(definition.Id, true, true, 0));
        Assert.False(File.Exists(store.FilePath));
        // The override remains an editable preference even when activation itself is unavailable.
        var card = Assert.Single(service.SetPreference(definition.Id, false, true, 0));
        Assert.True(card.ForceVersion);
        Assert.False(card.Enabled);
        Assert.False(card.CanEnable);
    }

    [Theory]
    [InlineData(RuntimeExtensionState.Active)]
    [InlineData(RuntimeExtensionState.Pending)]
    [InlineData(RuntimeExtensionState.FaultedPassThrough)]
    public void VehicleRuntimeEvidenceIsNeverRoutedToAnotherContinuousModule(RuntimeExtensionState state)
    {
        var definition = Definition("pztools.another-driver", [ExtensionCapabilities.VehicleDrivetrain]);
        var card = new ExtensionCardView(definition, true, "runtime-pending", 4);
        var runtime = Active() with { State = state, Reason = state == RuntimeExtensionState.FaultedPassThrough ? "vehicle-failed" : null };
        if (state == RuntimeExtensionState.FaultedPassThrough)
            runtime = runtime with { ControlReady = false, AppliedVehicleOptions = null };
        var view = new GameExtensionsView([card], true, VehicleStatus: runtime, RuntimeWorldReady: true);
        var activation = view.ActivationFor(card);
        Assert.Equal(ExtensionActivationKind.Continuous, definition.ActivationKind);
        Assert.True(activation.IsOn); // This module's saved request, not the vehicle module's runtime evidence.
        Assert.False(activation.IsPerSave);
        Assert.False(activation.IsBusy);
        Assert.True(activation.CanToggle);
        Assert.True(activation.CanEditOptions);
        Assert.Null(activation.AppliedVehicleOptions);
        Assert.Null(activation.FailureReason);
    }

    [Fact]
    public void OwningVehicleModuleStillReceivesItsAppliedState()
    {
        var card = new ExtensionCardView(Definition(ExtensionIds.VehicleDrivetrain,
            [ExtensionCapabilities.VehicleDrivetrain]), true, "runtime-pending", 4);
        var view = new GameExtensionsView([card], true, VehicleStatus: Active(), RuntimeWorldReady: true);
        var activation = view.ActivationFor(card);
        Assert.True(activation.IsOn);
        Assert.True(activation.CanToggle);
        Assert.True(activation.CanEditOptions);
        Assert.False(activation.IsPerSave);
        Assert.Equal(new VehicleDrivetrainPreference(true, false, true), activation.AppliedVehicleOptions);
    }

    [Fact]
    public void AnotherSaveProviderUsesPerSaveSelectionWithoutInheritingVehicleFailure()
    {
        var card = new ExtensionCardView(Definition("pztools.another-save", [ExtensionCapabilities.SavePreparation]),
            true, "compatibility-on-request", 4);
        var failure = new RuntimeExtensionStatus(RuntimeExtensionState.RestartRequired, "vehicle-retirement-failed");
        var view = new GameExtensionsView([card], true, VehicleStatus: failure, RuntimeWorldReady: true);
        var activation = view.ActivationFor(card);
        Assert.True(activation.IsOn);
        Assert.True(activation.IsPerSave);
        Assert.True(activation.CanToggle);
        Assert.True(activation.CanEditOptions);
        Assert.Null(activation.FailureReason);
        Assert.Null(activation.AppliedVehicleOptions);
    }

    [Fact]
    public void CatalogueUsesTheSameClassificationAndKeepsLegacySaveRows()
    {
        var legacy = Assert.Single(ExtensionCatalog.Parse(Row("pztools.legacy-save")));
        Assert.Equal(ExtensionActivationKind.PerSave, legacy.ActivationKind);
        Assert.Equal(ExtensionCapabilities.SavePreparation, Assert.Single(legacy.Capabilities));
        Assert.Equal("compatibility-on-request", legacy.ReadinessCode);
        var continuous = Assert.Single(ExtensionCatalog.Parse(Row(ExtensionIds.VehicleDrivetrain)
            + "\t" + ExtensionCapabilities.VehicleDrivetrain));
        Assert.Equal(ExtensionActivationKind.Continuous, continuous.ActivationKind);
        Assert.Equal("runtime-pending", continuous.ReadinessCode);
        // This is an identity invariant, separate from the general capability classifier.
        Assert.Throws<InvalidDataException>(() => ExtensionCatalog.Parse(Row(ExtensionIds.VehicleDrivetrain)));
    }

    [Theory]
    [InlineData("")]
    [InlineData("unknown.feature.v1")]
    [InlineData("save.prepare.v1,vehicle.drivetrain.v1")]
    [InlineData("save.prepare.v1,save.prepare.v1")]
    public void UnsupportedCatalogueCapabilityNeverDefaultsToSave(string capability) =>
        Assert.Throws<InvalidDataException>(() => ExtensionCatalog.Parse(Row("pztools.other-extension") + "\t" + capability));

    private static ExtensionDefinition Definition(string id, IReadOnlyList<string> capabilities) =>
        new(id, "0.2.0", "title", "description", "runtime-pending", capabilities);

    private static string Row(string id) => string.Join('\t', id, "0.2.0", "pztools.extensions.test",
        "pztools.extensions.test.Provider", "test.jar", "All", "-", "-", "Extension.Test.Title", "Extension.Test.Description");

    private static RuntimeExtensionStatus Active() => new(RuntimeExtensionState.Active,
        ProcessSession: new string('a', 32), WorldSession: new string('b', 32), Generation: new string('c', 32),
        AppliedRevision: 4, ModuleVersion: "0.2.0", ModuleHash: new string('d', 64), RequestedRevision: 4,
        ControlReady: true, AppliedVehicleOptions: new(true, false, true));
}
