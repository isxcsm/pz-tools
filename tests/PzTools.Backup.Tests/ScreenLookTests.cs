using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

/// <summary>The screen look as an extension of its own: catalogue, preferences, configuration and status.</summary>
public sealed class ScreenLookTests
{
    [Fact]
    public void Catalogue_ListsTheLookAsItsOwnContinuousExtension()
    {
        var look = ExtensionCatalog.BuiltIn.Single(item => item.Id == ExtensionIds.ScreenLook);
        Assert.Equal(ExtensionActivationKind.Continuous, look.ActivationKind);
        Assert.Equal([ExtensionCapabilities.ScreenGrade], look.Capabilities);
        Assert.Equal(("Extension.ScreenLook.Title", "Extension.ScreenLook.Description"), (look.TitleKey, look.DescriptionKey));
        Assert.Equal(new GameVersionSupport(VersionSupportScope.Major, "42", "42"), look.SupportedVersions);
        Assert.Contains(ExtensionCatalog.BuiltIn, item => item.Id == ExtensionIds.VehicleDrivetrain);
    }

    [Fact]
    public void Preferences_BelongToTheLookAlone_AndSurviveItsOwnSwitches()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var service = new GameExtensionService(store, () => "42.20");
        var options = new ScreenLookPreference("cinematic", 35, true);
        var cards = service.SetScreenLookPreference(options, 0);
        var look = cards.Single(card => card.Definition.Id == ExtensionIds.ScreenLook);
        var vehicle = cards.Single(card => card.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.Equal(options, look.ScreenLook);
        Assert.False(look.Enabled);
        // Nothing of it lands on another extension.
        Assert.Null(vehicle.ScreenLook);
        Assert.Null(vehicle.VehicleDrivetrain);
        Assert.False(store.Read().Extensions.ContainsKey(ExtensionIds.VehicleDrivetrain));

        look = service.SetEnabled(ExtensionIds.ScreenLook, true, look.SettingsRevision).Single(card => card.Definition.Id == ExtensionIds.ScreenLook);
        look = service.SetPreference(ExtensionIds.ScreenLook, true, true, look.SettingsRevision).Single(card => card.Definition.Id == ExtensionIds.ScreenLook);
        Assert.Equal((true, true, options), (look.Enabled, look.ForceVersion, look.ScreenLook));
        // The vehicle's switch is its own.
        vehicle = service.SetEnabled(ExtensionIds.VehicleDrivetrain, true, look.SettingsRevision).Single(card => card.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.True(vehicle.Enabled);
        Assert.Equal(options, store.Read().Extensions[ExtensionIds.ScreenLook].ScreenLook);

        Assert.Throws<ExtensionSettingsConflictException>(() => service.SetScreenLookPreference(options with { Strength = 10 }, 0));
        Assert.Throws<InvalidDataException>(() => service.SetScreenLookPreference(options with { Preset = "neon" }, vehicle.SettingsRevision));
        Assert.Throws<InvalidDataException>(() => service.SetScreenLookPreference(options with { Strength = 101 }, vehicle.SettingsRevision));
    }

    [Theory]
    [InlineData("{\"preset\":\"neon\"}")]
    [InlineData("{\"strength\":-1}")]
    [InlineData("{\"preset\":null}")]
    public void InvalidSavedOptions_SurfaceAsASettingsError_NotAsADefault(string json)
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        File.WriteAllText(store.FilePath,
            "{\"schemaVersion\":1,\"revision\":0,\"extensions\":{\"pztools.screen-look\":{\"screenLook\":" + json + "}}}");
        Assert.Throws<InvalidDataException>(() => store.Read());
    }

    [Fact]
    public void Configuration_IsTheAppsChoicesPlusTheModulesOwnTuningFile()
    {
        using var temp = new TempDirectory();
        Directory.CreateDirectory(temp.GetPath("bridge/extensions"));
        File.WriteAllText(temp.GetPath("bridge/extensions/screen-look.toml"), "schema_version = 1\nclarity_scale = 0.5\n");
        var values = ScreenLookConfiguration.Load(temp.GetPath("bridge"), temp.GetPath("runtime"), new("vivid", 85, true));
        Assert.Equal(("vivid", "85", "true", "0.5", "0.8", "1"),
            (values["preset"], values["strength"], values["seasonal"], values["clarity_scale"], values["seasonal_amount"], values["schema_version"]));
        Assert.Equal(6, values.Count);

        Directory.CreateDirectory(temp.GetPath("runtime/extensions"));
        File.WriteAllText(temp.GetPath("runtime/extensions/screen-look.toml"), "seasonal_amount = 0.25\n");
        var tuned = ScreenLookConfiguration.Load(temp.GetPath("bridge"), temp.GetPath("runtime"));
        Assert.Equal(("realistic", "60", "false", "0.5", "0.25"),
            (tuned["preset"], tuned["strength"], tuned["seasonal"], tuned["clarity_scale"], tuned["seasonal_amount"]));

        // The choices are the app's. A file cannot set them, and anything it does not know is a mistake.
        foreach (var toml in new[] { "preset = \"vivid\"", "strength = 10", "seasonal = true", "clarity_scale = 2.5", "seasonal_amount = -0.1",
                     "schema_version = 2", "steering_enabled = true", "clarity_scale = 1\nclarity_scale = 1" })
            Assert.Throws<InvalidDataException>(() => ScreenLookConfiguration.Parse(toml));
        Assert.ThrowsAny<IOException>(() => ScreenLookConfiguration.Load(temp.GetPath("missing"), temp.Path));
        // The vehicle module's configuration knows nothing of the look.
        Assert.DoesNotContain(VehicleDrivetrainConfiguration.Parse("").Keys, key => key.Contains("screen", StringComparison.Ordinal));
        Assert.Throws<InvalidDataException>(() => VehicleDrivetrainConfiguration.Parse("screen_clarity_scale = 1"));
    }

    [Fact]
    public async Task Controller_EditsTheLooksOptions_AndKeepsEachExtensionsStatusApart()
    {
        using var temp = new TempDirectory();
        var id = new string('a', 32);
        var applied = new RuntimeExtensionStatus(RuntimeExtensionState.Active, null, id, id, id, AppliedRevision: 2,
            ModuleVersion: "1", ModuleHash: new string('0', 64), RequestedRevision: 2, ControlReady: true,
            AppliedVehicleOptions: new(false, false, false));
        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore(), gameVersion: () => "42.20",
            extensionStatus: module => module == ExtensionIds.ScreenLook ? applied : null, runtimeWorldReady: () => true);
        await controller.ApplyEditAsync(ExtensionIds.ScreenLook, GameExtensionSetting.Enabled, true);
        var view = await controller.ApplyScreenLookAsync(look => look with { Preset = "cinematic", Strength = 80 });
        var card = view.Cards.Single(item => item.Definition.Id == ExtensionIds.ScreenLook);
        var vehicle = view.Cards.Single(item => item.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.Equal((true, new ScreenLookPreference("cinematic", 80)), (card.Enabled, card.ScreenLook));
        Assert.False(vehicle.Enabled);
        Assert.Equal(2, card.SettingsRevision);

        // The look is on and applied at this revision: not busy. The vehicle has no status of its own and is off: not busy either.
        Assert.Equal(applied, view.StatusOf(ExtensionIds.ScreenLook));
        Assert.Null(view.StatusOf(ExtensionIds.VehicleDrivetrain));
        Assert.Equal((true, false), (view.ActivationFor(card).IsOn, view.ActivationFor(card).IsBusy));
        Assert.Equal((false, false), (view.ActivationFor(vehicle).IsOn, view.ActivationFor(vehicle).IsBusy));
        // A vehicle option is not an option of the look.
        await Assert.ThrowsAsync<InvalidDataException>(() => controller.ApplyEditAsync(ExtensionIds.ScreenLook, GameExtensionSetting.Steering, false));
    }

    [Fact]
    public void Statuses_ArePublishedPerModule_AndAConnectionWideStateStandsForAll()
    {
        var store = new RuntimeExtensionStatusStore();
        Assert.Equal("not-connected", store.Read(ExtensionIds.ScreenLook).Reason);
        store.Publish(ExtensionIds.ScreenLook, new(RuntimeExtensionState.Pending, "connecting"));
        store.Publish(ExtensionIds.VehicleDrivetrain, new(RuntimeExtensionState.Disabled, "waiting-for-local-world"));
        Assert.Equal("connecting", store.Read(ExtensionIds.ScreenLook).Reason);
        Assert.Equal("waiting-for-local-world", store.Read(ExtensionIds.VehicleDrivetrain).Reason);
        Assert.Equal("not-connected", store.Read().Reason);
        Assert.Equal(2, store.ReadModules().Count);

        // No game, no lease: what each module last said is no longer true.
        store.Publish(new(RuntimeExtensionState.Disabled, "no-game-process"));
        Assert.Empty(store.ReadModules());
        Assert.Equal("no-game-process", store.Read(ExtensionIds.ScreenLook).Reason);
        Assert.Equal("no-game-process", store.Read(ExtensionIds.VehicleDrivetrain).Reason);

        // The feed carries both forms; a reader asks for its module and falls back to the connection.
        var own = new RuntimeExtensionStatus(RuntimeExtensionState.Pending, "connecting");
        var observation = new RuntimeObservation("", RuntimeQuality.Unknown, null,
            Extension: new(RuntimeExtensionState.Disabled, "no-game-process"),
            Extensions: new Dictionary<string, RuntimeExtensionStatus> { [ExtensionIds.ScreenLook] = own }).Validate();
        Assert.Equal(own, observation.ExtensionFor(ExtensionIds.ScreenLook));
        Assert.Equal("no-game-process", observation.ExtensionFor(ExtensionIds.VehicleDrivetrain)!.Reason);
        var restored = RuntimeJson.Read<RuntimeObservation>(RuntimeJson.Write(observation)).Validate();
        Assert.Equal(own, restored.ExtensionFor(ExtensionIds.ScreenLook));
        Assert.Equal("connecting", ExtensionActivationView.SelectCurrentStatus(restored, ExtensionIds.ScreenLook)!.Reason);
        Assert.Equal("no-game-process", ExtensionActivationView.SelectCurrentStatus(restored, ExtensionIds.VehicleDrivetrain)!.Reason);
        Assert.Equal("no-game-process", ExtensionActivationView.SelectCurrentStatus(restored)!.Reason);
    }
}
