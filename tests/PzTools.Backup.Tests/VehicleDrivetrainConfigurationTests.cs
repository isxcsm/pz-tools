using System.Globalization;
using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class VehicleDrivetrainConfigurationTests
{
    [Fact]
    public void FlatConfigurationHasExplicitFiniteDefaultsAndCanonicalWireValues()
    {
        var values = VehicleDrivetrainConfiguration.Parse("schema_version = 1\nreverse_max_speed_kph = 10.5\n");
        Assert.Equal("1", values["force_scale"]);
        Assert.Equal("0.1", values["forward_torque_boost_fraction"]);
        Assert.Equal("1", values["low_gear_boost"]);
        Assert.Equal("1", values["reverse_force_ratio"]);
        Assert.Equal("10.5", values["reverse_max_speed_kph"]);
        Assert.Equal("0.8", values["reverse_ramp_seconds"]);
        Assert.Equal("false", values["probe_only"]);
        Assert.Equal("true", values["torque_enabled"]);
        Assert.Equal("true", values["reverse_enabled"]);
        Assert.Equal("true", values["steering_enabled"]);
        Assert.Equal("true", values["steering_precise_input"]);
        Assert.Equal("true", values["area_light_enabled"]);
        Assert.Equal("8", values["area_light_radius"]);
        Assert.Equal("0.6", values["area_light_brightness"]);
        Assert.DoesNotContain("steering_full_rate", values.Keys);
        Assert.Equal("1", values["forward_governor_start_fraction"]);
        Assert.Equal("1", values["reverse_governor_start_fraction"]);
        Assert.Equal("0", VehicleDrivetrainConfiguration.Parse("")["reverse_max_speed_kph"]);
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("de-DE");
            Assert.Equal("0.8", VehicleDrivetrainConfiguration.Parse("reverse_ramp_seconds = 0.8")["reverse_ramp_seconds"]);
        }
        finally { CultureInfo.CurrentCulture = previous; }
    }

    [Theory]
    [InlineData("force_scale = nan")]
    [InlineData("force_scale = inf")]
    [InlineData("force_scale = '1.0'")]
    [InlineData("force_scale = 0")]
    [InlineData("forward_torque_boost_fraction = -0.001")]
    [InlineData("forward_torque_boost_fraction = 0.1001")]
    [InlineData("forward_torque_boost_fraction = nan")]
    [InlineData("forward_torque_boost_fraction = inf")]
    [InlineData("forward_torque_boost_fraction = '0.05'")]
    [InlineData("force_scale = 1\nforce_scale = 1")]
    [InlineData("force_scale = 1\n'force_scale' = 0.8")]
    [InlineData("force_scale = 1\n\"force_\\u0073cale\" = 0.8")]
    [InlineData("reverse_force_ratio = 0.3")]
    [InlineData("reverse_force_ratio = 1.01")]
    [InlineData("low_mode = 'true'")]
    [InlineData("probe_only = 1")]
    [InlineData("schema_version = 1.0")]
    [InlineData("schema_version = 2")]
    [InlineData("unknown = true")]
    [InlineData("[vehicle]\nforce_scale = 1")]
    [InlineData("upshift_rpm_fraction = 0.65\ndownshift_rpm_fraction = 0.55")]
    [InlineData("gear_ratio_span = 5.1")]
    [InlineData("idle_rpm = 499")]
    [InlineData("launch_rpm = 2501")]
    [InlineData("generic_redline_rpm = 6501")]
    [InlineData("utility_redline_rpm = nan")]
    [InlineData("sport_redline_rpm = 2999")]
    [InlineData("generic_torque_peak_fraction = 0.9")]
    [InlineData("utility_torque_peak_fraction = 0.1")]
    [InlineData("sport_torque_peak_fraction = inf")]
    [InlineData("idle_torque_fraction = 1.0")]
    [InlineData("rpm_response_seconds = 0")]
    [InlineData("direction_speed_mps = 0")]
    [InlineData("forward_governor_start_fraction = 1.01")]
    [InlineData("reverse_governor_start_fraction = 0.49")]
    [InlineData("reverse_governor_start_fraction = 1.01")]
    [InlineData("shift_hysteresis_fraction = 0")]
    [InlineData("demand_downshift_fraction = 0.9")]
    [InlineData("idle_rpm = 1200\nlaunch_rpm = 1000")]
    [InlineData("launch_rpm = 2500\nutility_redline_rpm = 3000")]
    [InlineData("torque_enabled = 1")]
    [InlineData("reverse_enabled = 'true'")]
    [InlineData("steering_enabled = 0")]
    [InlineData("reverse_max_speed_kph = -0.1")]
    [InlineData("reverse_max_speed_kph = 1e-300")]
    [InlineData("reverse_max_speed_kph = 0.1")]
    [InlineData("reverse_max_speed_kph = 1")]
    [InlineData("reverse_max_speed_kph = 3.999")]
    [InlineData("reverse_max_speed_kph = 36")]
    [InlineData("reverse_max_speed_kph = nan")]
    [InlineData("reverse_max_speed_kph = inf")]
    [InlineData("steering_precise_input = 1")]
    [InlineData("steering_full_rate = 'fast'")]
    public void InvalidOrAmbiguousConfigurationIsRejected(string text) =>
        Assert.Throws<InvalidDataException>(() => VehicleDrivetrainConfiguration.Parse(text));

    [Theory]
    [InlineData("reverse_max_speed_kph", "0", "0")]
    [InlineData("reverse_max_speed_kph", "0.0", "0")]
    [InlineData("reverse_max_speed_kph", "4", "4")]
    [InlineData("reverse_max_speed_kph", "35", "35")]
    [InlineData("reverse_governor_start_fraction", "0.5", "0.5")]
    [InlineData("reverse_governor_start_fraction", "1.0", "1")]
    [InlineData("reverse_force_ratio", "0.4", "0.4")]
    [InlineData("reverse_force_ratio", "1.0", "1")]
    [InlineData("forward_torque_boost_fraction", "0", "0")]
    [InlineData("forward_torque_boost_fraction", "0.05", "0.05")]
    [InlineData("forward_torque_boost_fraction", "0.10", "0.1")]
    public void VehicleRelativeReverseSentinelAndExplicitBoundaryValuesAreAccepted(string key, string value, string canonical)
    {
        var parsed = VehicleDrivetrainConfiguration.Parse($"{key} = {value}");
        Assert.Equal(canonical, parsed[key]);
    }

    [Fact]
    public void VehicleRelativeReverseSentinelIsPreservedAcrossLayersAndInvalidGapIsRejected()
    {
        using var temp = new TempDirectory();
        var bridge = temp.GetPath("bridge");
        var runtime = temp.GetPath("runtime");
        Directory.CreateDirectory(Path.Combine(bridge, "extensions"));
        Directory.CreateDirectory(Path.Combine(runtime, "extensions"));
        var package = Path.Combine(bridge, "extensions", "vehicle-drivetrain.toml");
        var overrides = Path.Combine(runtime, "extensions", "vehicle-drivetrain.toml");
        const string packaged = "schema_version = 1\nreverse_max_speed_kph = 0\n";
        File.WriteAllText(package, packaged);
        Assert.Equal("0", VehicleDrivetrainConfiguration.Load(bridge, runtime)["reverse_max_speed_kph"]);
        File.WriteAllText(overrides, "reverse_max_speed_kph = 22");
        Assert.Equal("22", VehicleDrivetrainConfiguration.Load(bridge, runtime)["reverse_max_speed_kph"]);
        File.WriteAllText(overrides, "reverse_max_speed_kph = 0.0");
        Assert.Equal("0", VehicleDrivetrainConfiguration.Load(bridge, runtime)["reverse_max_speed_kph"]);
        File.WriteAllText(overrides, "reverse_max_speed_kph = 3.99");
        Assert.Throws<InvalidDataException>(() => VehicleDrivetrainConfiguration.Load(bridge, runtime));
        Assert.Equal(packaged, File.ReadAllText(package));
        Assert.Equal("reverse_max_speed_kph = 3.99", File.ReadAllText(overrides));
        File.WriteAllText(package, "reverse_max_speed_kph = 1");
        File.WriteAllText(overrides, "reverse_max_speed_kph = 0");
        Assert.Throws<InvalidDataException>(() => VehicleDrivetrainConfiguration.Load(bridge, runtime));
    }

    [Fact]
    public void RetiredSteeringRatesInAnOlderOverrideFileAreIgnoredNotRejected()
    {
        var values = VehicleDrivetrainConfiguration.Parse("steering_full_rate = 7.5\nsteering_high_speed_rate_factor = 0.6\nforce_scale = 0.9\nsteering_precise_input = false\n");
        Assert.Equal("0.9", values["force_scale"]);
        Assert.Equal("false", values["steering_precise_input"]);
        Assert.DoesNotContain(values.Keys, key => key.StartsWith("steering_", StringComparison.Ordinal) && key is not ("steering_enabled" or "steering_precise_input"));
    }

    [Fact]
    public void BoundedProfileTuningIsIncludedInTheFlatWireContract()
    {
        var values = VehicleDrivetrainConfiguration.Parse("""
            gear_ratio_span = 4.0
            idle_rpm = 700.0
            launch_rpm = 1200.0
            generic_redline_rpm = 6000.0
            utility_redline_rpm = 5000.0
            sport_redline_rpm = 6200.0
            generic_torque_peak_fraction = 0.6
            utility_torque_peak_fraction = 0.45
            sport_torque_peak_fraction = 0.7
            idle_torque_fraction = 0.4
            forward_torque_boost_fraction = 0.05
            rpm_response_seconds = 0.2
            direction_speed_mps = 0.2
            forward_governor_start_fraction = 0.85
            reverse_governor_start_fraction = 0.6
            shift_hysteresis_fraction = 0.1
            demand_downshift_fraction = 0.5
            """);
        Assert.Equal(39, values.Count);
        Assert.Equal("4", values["gear_ratio_span"]);
        Assert.Equal("700", values["idle_rpm"]);
        Assert.Equal("6000", values["generic_redline_rpm"]);
        Assert.Equal("0.4", values["idle_torque_fraction"]);
        Assert.Equal("0.05", values["forward_torque_boost_fraction"]);
        Assert.Equal("0.2", values["rpm_response_seconds"]);
        Assert.Equal("0.1", values["shift_hysteresis_fraction"]);
    }

    [Fact]
    public void ForwardTorqueBoostOverridePreservesOldDefaultsAndDoesNotRewriteFiles()
    {
        using var temp = new TempDirectory();
        Directory.CreateDirectory(temp.GetPath("bridge/extensions"));
        Directory.CreateDirectory(temp.GetPath("runtime/extensions"));
        var package = temp.GetPath("bridge/extensions/vehicle-drivetrain.toml");
        var overrides = temp.GetPath("runtime/extensions/vehicle-drivetrain.toml");
        const string oldPackage = "schema_version = 1\nforce_scale = 0.9\n";
        File.WriteAllText(package, oldPackage);
        Assert.Equal("0.1", VehicleDrivetrainConfiguration.Load(temp.GetPath("bridge"), temp.GetPath("runtime"))["forward_torque_boost_fraction"]);
        File.WriteAllText(overrides, "forward_torque_boost_fraction = 0\n");
        var values = VehicleDrivetrainConfiguration.Load(temp.GetPath("bridge"), temp.GetPath("runtime"));
        Assert.Equal("0", values["forward_torque_boost_fraction"]);
        Assert.Equal("0.9", values["force_scale"]);
        Assert.Equal("true", values["torque_enabled"]);
        Assert.Equal(oldPackage, File.ReadAllText(package));
        Assert.Equal("forward_torque_boost_fraction = 0\n", File.ReadAllText(overrides));
    }

    [Fact]
    public void PackagedRuntimeAndUiLayersAreReadOnlyAndHaveExplicitPriority()
    {
        using var temp = new TempDirectory();
        var bridge = temp.GetPath("bridge");
        var runtime = temp.GetPath("runtime");
        Directory.CreateDirectory(Path.Combine(bridge, "extensions"));
        Directory.CreateDirectory(Path.Combine(runtime, "extensions"));
        var package = Path.Combine(bridge, "extensions", "vehicle-drivetrain.toml");
        var overrides = Path.Combine(runtime, "extensions", "vehicle-drivetrain.toml");
        const string original = "schema_version = 1\nforce_scale = 0.8\nlow_mode = true\n";
        File.WriteAllText(package, original);
        Assert.Equal("0.8", VehicleDrivetrainConfiguration.Load(bridge, runtime)["force_scale"]);
        Assert.Equal("true", VehicleDrivetrainConfiguration.Load(bridge, runtime)["low_mode"]);
        Assert.False(File.Exists(overrides));
        File.WriteAllText(overrides, "force_scale = 0.9\nprobe_only = true\ndiagnostics_enabled = true\nsteering_enabled = false\n");
        var values = VehicleDrivetrainConfiguration.Load(bridge, runtime, new(TorqueEnabled: false, ReverseEnabled: false));
        Assert.Equal("0.9", values["force_scale"]);
        Assert.Equal("true", values["low_mode"]);
        Assert.Equal("true", values["probe_only"]);
        Assert.Equal("true", values["diagnostics_enabled"]);
        Assert.Equal("false", values["torque_enabled"]);
        Assert.Equal("false", values["reverse_enabled"]);
        Assert.Equal("true", values["steering_enabled"]);
        Assert.Equal(original, File.ReadAllText(package));
        File.WriteAllText(overrides, "force_scale = 'bad'");
        Assert.Throws<InvalidDataException>(() => VehicleDrivetrainConfiguration.Load(bridge, runtime));
        Assert.Equal("force_scale = 'bad'", File.ReadAllText(overrides));
    }

    [Fact]
    public void MissingPackageDoesNotSilentlyUseBuiltInCalibration()
    {
        using var temp = new TempDirectory();
        Assert.ThrowsAny<IOException>(() => VehicleDrivetrainConfiguration.Load(temp.GetPath("bridge"), temp.Path));
    }

    [Fact]
    public void UnwrittenUiDefaultsAlsoOverrideTheThreeTomlFeatureFlags()
    {
        using var temp = new TempDirectory();
        Directory.CreateDirectory(temp.GetPath("bridge/extensions"));
        Directory.CreateDirectory(temp.GetPath("runtime/extensions"));
        File.WriteAllText(temp.GetPath("bridge/extensions/vehicle-drivetrain.toml"), "schema_version = 1");
        File.WriteAllText(temp.GetPath("runtime/extensions/vehicle-drivetrain.toml"),
            "torque_enabled = false\nreverse_enabled = false\nsteering_enabled = false\narea_light_enabled = false\nprobe_only = true\n");
        var defaults = VehicleDrivetrainConfiguration.Load(temp.GetPath("bridge"), temp.GetPath("runtime"));
        Assert.Equal("true", defaults["area_light_enabled"]);
        Assert.Equal("true", defaults["torque_enabled"]);
        Assert.Equal("true", defaults["reverse_enabled"]);
        Assert.Equal("true", defaults["steering_enabled"]);
        Assert.Equal("true", defaults["probe_only"]);
        Assert.False(File.Exists(temp.GetPath("runtime/extensions/settings.json")));
    }

    [Fact]
    public void VehicleOptionsSurviveToggleAndVersionChangesAndRejectStaleWrites()
    {
        using var temp = new TempDirectory();
        var definition = VehicleDefinition();
        var service = new GameExtensionService(new ExtensionSettingsStore(temp.Path), () => "42.20", () => [definition]);
        var options = new VehicleDrivetrainPreference(true, true, true);
        var saved = Assert.Single(service.SetVehicleDrivetrainPreference(options, 0));
        Assert.False(saved.Enabled);
        Assert.Equal(options, saved.VehicleDrivetrain);
        var on = Assert.Single(service.SetPreference(definition.Id, true, true, saved.SettingsRevision));
        Assert.Equal(options, on.VehicleDrivetrain);
        Assert.True(on.Enabled && on.ForceVersion);
        Assert.Throws<ExtensionSettingsConflictException>(() => service.SetVehicleDrivetrainPreference(new(), saved.SettingsRevision));
        var off = Assert.Single(service.SetEnabled(definition.Id, false, on.SettingsRevision));
        Assert.Equal(options, off.VehicleDrivetrain);
        Assert.True(off.ForceVersion);
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, false, true)]
    [InlineData(false, true, false)]
    [InlineData(false, true, true)]
    [InlineData(true, false, false)]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    [InlineData(true, true, true)]
    public void AllThreeSwitchCombinationsRoundTripIndependently(bool torque, bool reverse, bool steering)
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var options = new VehicleDrivetrainPreference(torque, reverse, steering);
        store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, false, options), 0);
        var saved = store.Read().Extensions[ExtensionIds.VehicleDrivetrain];
        Assert.Equal(options, saved.VehicleDrivetrain);
        Directory.CreateDirectory(temp.GetPath("extensions"));
        File.WriteAllText(temp.GetPath("extensions/vehicle-drivetrain.toml"), "schema_version = 1");
        var values = VehicleDrivetrainConfiguration.Load(temp.Path, temp.GetPath("overrides"), saved.VehicleDrivetrain);
        Assert.Equal(torque ? "true" : "false", values["torque_enabled"]);
        Assert.Equal(reverse ? "true" : "false", values["reverse_enabled"]);
        Assert.Equal(steering ? "true" : "false", values["steering_enabled"]);
        Assert.Equal("true", values["area_light_enabled"]);
        Assert.DoesNotContain("probeOnly", File.ReadAllText(store.FilePath));
        Assert.DoesNotContain("lowMode", File.ReadAllText(store.FilePath));
    }

    [Theory]
    [InlineData("area_light_radius = 2")]
    [InlineData("area_light_radius = 21")]
    [InlineData("area_light_brightness = 0")]
    [InlineData("area_light_brightness = 1.1")]
    [InlineData("area_light_enabled = 1")]
    public void AreaLightTuningIsBounded(string toml) =>
        Assert.Throws<InvalidDataException>(() => VehicleDrivetrainConfiguration.Parse(toml));

    [Fact]
    public void AFractionalLightRadiusIsPassedOnForTheGameToRound() =>
        // The game's module rounds it to whole tiles (DrivetrainConfig), as the defaults file says.
        Assert.Equal("7.6", VehicleDrivetrainConfiguration.Parse("area_light_radius = 7.6")["area_light_radius"]);

    [Fact]
    public void AreaLightSwitchRoundTripsAndTuningComesFromToml()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        var options = new VehicleDrivetrainPreference(AreaLightEnabled: true);
        store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, false, options), 0);
        var saved = store.Read().Extensions[ExtensionIds.VehicleDrivetrain];
        Assert.Equal(options, saved.VehicleDrivetrain);
        Assert.Matches("\"areaLightEnabled\":\\s*true", File.ReadAllText(store.FilePath));
        Directory.CreateDirectory(temp.GetPath("extensions"));
        File.WriteAllText(temp.GetPath("extensions/vehicle-drivetrain.toml"), "schema_version = 1\narea_light_radius = 12\narea_light_brightness = 0.35\n");
        var values = VehicleDrivetrainConfiguration.Load(temp.Path, temp.GetPath("overrides"), saved.VehicleDrivetrain);
        Assert.Equal("true", values["area_light_enabled"]);
        Assert.Equal("12", values["area_light_radius"]);
        Assert.Equal("0.35", values["area_light_brightness"]);
        // On when not written, like the other switches (files from before the light existed lack it);
        // an old observation-only file still turns it off.
        foreach (var json in new[] { "{}", "{\"steeringEnabled\":true}" })
            Assert.True(System.Text.Json.JsonSerializer.Deserialize<VehicleDrivetrainPreference>(json)!.AreaLightEnabled);
        foreach (var json in new[] { "{\"areaLightEnabled\":false}", "{\"probeOnly\":true}", "{\"probeOnly\":true,\"areaLightEnabled\":true}" })
            Assert.False(System.Text.Json.JsonSerializer.Deserialize<VehicleDrivetrainPreference>(json)!.AreaLightEnabled);
    }

    [Theory]
    [InlineData("{}", true, true, true)]
    [InlineData("{\"lowMode\":true,\"probeOnly\":false,\"diagnosticsEnabled\":true}", true, true, true)]
    [InlineData("{\"probeOnly\":true}", false, false, false)]
    [InlineData("{\"probeOnly\":true,\"steeringEnabled\":true}", false, false, true)]
    [InlineData("{\"TorqueEnabled\":false,\"ReverseEnabled\":true,\"SteeringEnabled\":false}", false, true, false)]
    public void OldObservationOnlyPreferencesNeverSilentlyEnableDrivingChanges(string json, bool torque, bool reverse, bool steering)
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        var original = "{\"schemaVersion\":1,\"revision\":7,\"extensions\":{\"pztools.vehicle-drivetrain\":{\"enabled\":true,\"vehicleDrivetrain\":" + json + "}}}";
        File.WriteAllText(store.FilePath, original);
        var read = store.Read();
        Assert.Equal(7, read.Revision);
        // The light was never written by these files: on, unless the file is an old observation-only one.
        var light = !json.Contains("\"probeOnly\":true", StringComparison.Ordinal);
        Assert.Equal(new VehicleDrivetrainPreference(torque, reverse, steering, light), read.Extensions[ExtensionIds.VehicleDrivetrain].VehicleDrivetrain);
        Assert.Equal(original, File.ReadAllText(store.FilePath));
    }

    [Theory]
    [InlineData("{\"torqueEnabled\":\"false\"}")]
    [InlineData("{\"reverseEnabled\":null}")]
    [InlineData("{\"steeringEnabled\":1}")]
    [InlineData("{\"probeOnly\":1}")]
    [InlineData("[]")]
    public void MalformedVehiclePreferencesSurfaceAsSettingsErrors(string json)
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        var original = "{\"schemaVersion\":1,\"revision\":0,\"extensions\":{\"pztools.vehicle-drivetrain\":{\"vehicleDrivetrain\":" + json + "}}}";
        File.WriteAllText(store.FilePath, original);
        Assert.Throws<InvalidDataException>(() => store.Read());
        Assert.Equal(original, File.ReadAllText(store.FilePath));
    }

    [Fact]
    public void CatalogueSeparatesLegacySavingFromExplicitVehicleCapability()
    {
        const string save = "pztools.example\t1.0.0\tpztools.example\tpztools.example.Provider\tmodule.jar\tAll\t-\t-\tExtension.Example.Title\tExtension.Example.Description";
        Assert.Equal("save.prepare.v1", Assert.Single(ExtensionCatalog.Parse(save)).Capabilities.Single());
        var vehicle = save.Replace("pztools.example", ExtensionIds.VehicleDrivetrain);
        Assert.Throws<InvalidDataException>(() => ExtensionCatalog.Parse(vehicle));
        Assert.Equal("vehicle.drivetrain.v1", Assert.Single(ExtensionCatalog.Parse(vehicle + "\tvehicle.drivetrain.v1")).Capabilities.Single());
        Assert.Throws<InvalidDataException>(() => ExtensionCatalog.Parse(save + "\tunknown.v1"));
    }

    [Fact]
    public async Task AppliedRuntimeStatusChangesProjectionWithoutChangingPreferencesOrSavePolicy()
    {
        using var temp = new TempDirectory();
        var views = new RevisionedViewStore();
        RuntimeExtensionStatus? state = null;
        var controller = new GameExtensionController(temp.Path, views, () => false, extensionStatus: _ => state);
        var before = await controller.RefreshAsync();
        Assert.Null(before.StatusOf(ExtensionIds.VehicleDrivetrain));
        state = new(RuntimeExtensionState.Pending, "waiting-for-game");
        await controller.RefreshRuntimeAsync(default);
        var first = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0);
        Assert.Equal(state, first.Snapshot!.StatusOf(ExtensionIds.VehicleDrivetrain));
        Assert.False(first.Snapshot.GameSavingEnabled);
        Assert.All(first.Snapshot.Cards, card => Assert.False(card.Enabled));
        await controller.RefreshRuntimeAsync(default);
        Assert.False(views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, first.ViewRevision).Modified);
        state = new(RuntimeExtensionState.FaultedPassThrough, "unsupported-controller");
        await controller.RefreshRuntimeAsync(default);
        Assert.True(views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, first.ViewRevision).Modified);
        Assert.False(File.Exists(new ExtensionSettingsStore(temp.Path).FilePath));
    }

    private static ExtensionDefinition VehicleDefinition() => new(ExtensionIds.VehicleDrivetrain, "0.1.0",
        "Extension.VehicleDrivetrain.Title", "Extension.VehicleDrivetrain.Description", "runtime-pending",
        ["vehicle.drivetrain.v1"], GameVersionSupport.All);
}
