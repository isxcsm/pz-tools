using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Backup.Tests;

public sealed class ExtensionCapabilityClassificationTests
{
    [Theory]
    [InlineData(ExtensionCapabilities.SavePreparation, ExtensionActivationKind.PerSave)]
    [InlineData(ExtensionCapabilities.Continuous, ExtensionActivationKind.Continuous)]
    [InlineData(ExtensionCapabilities.LegacyContinuous, ExtensionActivationKind.Continuous)]
    public void ARecognizedSingleCapabilityDeterminesBehaviorIndependentlyOfIdentity(string capability, ExtensionActivationKind expected)
    {
        foreach (var id in new[] { "pztools.test-save", VehicleDrivetrainExtension.Id, "pztools.another-extension" })
            Assert.Equal(expected, Definition(id, [capability]).ActivationKind);
    }

    public static IEnumerable<object?[]> UnsupportedCapabilities()
    {
        yield return [null];
        yield return [Array.Empty<string>()];
        yield return [new[] { "" }];
        yield return [new[] { "unknown.feature.v1" }];
        yield return [new[] { "SAVE.PREPARE.V1" }];
        yield return [new[] { ExtensionCapabilities.SavePreparation, ExtensionCapabilities.Continuous }];
        yield return [new[] { ExtensionCapabilities.SavePreparation, ExtensionCapabilities.SavePreparation }];
        yield return [new[] { ExtensionCapabilities.SavePreparation, "unknown.feature.v1" }];
    }

    [Theory]
    [MemberData(nameof(UnsupportedCapabilities))]
    public void MissingUnknownDuplicateAndCompositeCapabilitiesAreFailClosed(string[]? capabilities)
    {
        var definition = Definition(VehicleDrivetrainExtension.Id, capabilities!);
        Assert.Equal(ExtensionActivationKind.Unsupported, definition.ActivationKind);
        var card = new ExtensionCardView(definition, true, "runtime-pending", 4, ForceVersion: true);
        Assert.False(card.CanEnable);
        Assert.False(card.EffectiveEnabled);
        var view = new GameExtensionsView([card], Statuses: new Dictionary<string, RuntimeExtensionStatus> { [card.Definition.Id] = Active() }, RuntimeWorldReady: true);
        var activation = view.ActivationFor(card);
        Assert.False(activation.IsOn);
        Assert.False(activation.IsBusy);
        Assert.False(activation.CanToggle);
        Assert.Equal("unsupported-capability", activation.FailureReason);
    }

    /// <summary>
    /// Only continuous modules have a card: nothing in the app asks the game for a save provider, so a switch for one
    /// would save a preference nothing reads; an unknown capability has nothing to run.
    /// </summary>
    [Fact]
    public async Task OnlyContinuousModulesHaveACard()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var continuous = Definition("pztools.continuous-extension", [ExtensionCapabilities.Continuous]);
        var service = new GameExtensionService(store, () => "42.20.0", () =>
            [Definition("pztools.unknown-extension", ["unknown.feature.v1"]),
                Definition("pztools.test-save", [ExtensionCapabilities.SavePreparation]), continuous]);
        Assert.Equal(continuous.Id, Assert.Single(service.ReadCards()).Definition.Id);

        var catalogue = temp.GetPath("catalog.tsv");
        File.WriteAllText(catalogue, string.Join('\t', "pztools.test-save", "0.2.0", "pztools.extensions.test", "pztools.extensions.test.Provider",
            "test.jar", "All", "-", "-", "Extension.Test.Title", "Extension.Test.Description", ExtensionCapabilities.SavePreparation));
        var controller = new GameExtensionController(temp.Path, new PzTools.Projections.RevisionedViewStore(), cataloguePath: catalogue);
        Assert.Empty((await controller.RefreshAsync()).Cards);
        await Assert.ThrowsAsync<InvalidDataException>(() => controller.ApplyEditAsync("pztools.test-save", GameExtensionSetting.Enabled, true));
        Assert.False(File.Exists(store.FilePath));
    }

    [Theory]
    [InlineData(RuntimeExtensionState.Active)]
    [InlineData(RuntimeExtensionState.Pending)]
    [InlineData(RuntimeExtensionState.FaultedPassThrough)]
    public void VehicleRuntimeEvidenceIsNeverRoutedToAnotherContinuousModule(RuntimeExtensionState state)
    {
        var definition = Definition("pztools.another-driver", [ExtensionCapabilities.Continuous]);
        var card = new ExtensionCardView(definition, true, "runtime-pending", 4);
        var runtime = Active() with { State = state, Reason = state == RuntimeExtensionState.FaultedPassThrough ? "vehicle-failed" : null };
        if (state == RuntimeExtensionState.FaultedPassThrough)
            runtime = runtime with { ControlReady = false, AppliedConfiguration = null };
        var view = new GameExtensionsView([card], Statuses: new Dictionary<string, RuntimeExtensionStatus> { [VehicleDrivetrainExtension.Id] = runtime }, RuntimeWorldReady: true);
        var activation = view.ActivationFor(card);
        Assert.Equal(ExtensionActivationKind.Continuous, definition.ActivationKind);
        Assert.True(activation.IsOn); // This module's saved request, not the vehicle module's runtime evidence.
        Assert.False(activation.IsBusy);
        Assert.True(activation.CanToggle);
        Assert.Null(activation.FailureReason);
    }

    [Fact]
    public void OwningVehicleModuleStillReceivesItsAppliedState()
    {
        var card = new ExtensionCardView(Definition(VehicleDrivetrainExtension.Id,
            [ExtensionCapabilities.Continuous]), true, "runtime-pending", 4);
        var view = new GameExtensionsView([card], Statuses: new Dictionary<string, RuntimeExtensionStatus> { [card.Definition.Id] = Active() }, RuntimeWorldReady: true);
        var activation = view.ActivationFor(card);
        Assert.True(activation.IsOn);
        Assert.True(activation.CanToggle);
        Assert.False(activation.IsBusy);
        // Its own evidence: saved off while the game still runs it, turning it off is in progress.
        Assert.True(view.ActivationFor(card with { Enabled = false }).IsBusy);
    }

    [Fact]
    public void CatalogueUsesTheSameClassification_AndEveryRowNamesItsCapability()
    {
        var save = Assert.Single(ExtensionCatalog.Parse(Row("pztools.test-save") + "\t" + ExtensionCapabilities.SavePreparation));
        Assert.Equal(ExtensionActivationKind.PerSave, save.ActivationKind);
        Assert.Equal("compatibility-on-request", save.ReadinessCode);
        foreach (var capability in new[] { ExtensionCapabilities.Continuous, ExtensionCapabilities.LegacyContinuous })
        {
            var continuous = Assert.Single(ExtensionCatalog.Parse(Row("pztools.another-extension") + "\t" + capability));
            Assert.Equal(ExtensionActivationKind.Continuous, continuous.ActivationKind);
            Assert.Equal(capability, Assert.Single(continuous.Capabilities));
            Assert.Equal("runtime-pending", continuous.ReadinessCode);
        }
        // A row without a capability is refused, whichever module it names: it never quietly becomes a save provider.
        Assert.Throws<InvalidDataException>(() => ExtensionCatalog.Parse(Row("pztools.legacy-save")));
        Assert.Throws<InvalidDataException>(() => ExtensionCatalog.Parse(Row(VehicleDrivetrainExtension.Id)));
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
        ControlReady: true, AppliedConfiguration: new string('e', 64));
}
