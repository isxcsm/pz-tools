using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class ExtensionVersionTests
{
    [Fact]
    public void VersionRangesFollowSharedComponentCasesAndRejectInvalidBounds()
    {
        foreach (var line in File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "version-support.tsv")))
        {
            var p = line.Split('|');
            var rule = new GameVersionSupport(Enum.Parse<VersionSupportScope>(p[0]), p[1] == "-" ? null : p[1], p[2] == "-" ? null : p[2]);
            Assert.Equal(bool.Parse(p[4]), rule.Matches(p[3] == "-" ? null : p[3]));
        }
        Assert.Throws<InvalidDataException>(() => new GameVersionSupport(VersionSupportScope.Minor, "42.21", "42.20").Validate());
        Assert.Throws<InvalidDataException>(() => new GameVersionSupport(VersionSupportScope.Major, "42.20").Validate());
        Assert.Throws<InvalidDataException>(() => new GameVersionSupport(VersionSupportScope.All, "42").Validate());
    }

    [Fact]
    public void SettingsSavedForTheRetiredScreenLook_AreReadAndLeftBehindOnTheNextWrite()
    {
        using var temp = new TempDirectory();
        var file = Path.Combine(temp.Path, "extensions", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        // What an earlier build wrote with the screen look on.
        File.WriteAllText(file, """
            {
              "schemaVersion": 1,
              "revision": 7,
              "extensions": {
                "pztools.screen-look": { "enabled": true, "forceVersion": false, "screenLook": { "preset": "vivid", "strength": 80, "seasonal": true } },
                "pztools.vehicle-drivetrain": { "enabled": true, "forceVersion": false }
              }
            }
            """);
        var service = new GameExtensionService(new ExtensionSettingsStore(temp.Path), () => "42.21");
        var card = Assert.Single(service.ReadCards());
        Assert.Equal((ExtensionIds.VehicleDrivetrain, true, 7L), (card.Definition.Id, card.Enabled, card.SettingsRevision));

        Assert.False(Assert.Single(service.SetEnabled(ExtensionIds.VehicleDrivetrain, false, 7)).Enabled);
        Assert.DoesNotContain("screenLook", File.ReadAllText(file), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("42.0", true)]
    [InlineData("42.19.9", true)]
    [InlineData("42.20.4", true)]
    [InlineData("42.21-unstable", true)]
    [InlineData("42.9999", true)]
    [InlineData("41.78", false)]
    [InlineData("43.0", false)]
    [InlineData(null, false)]
    public void VehicleCatalogueAdmitsOnlyMajor42WithoutAForcedVersionOverride(string? version, bool admitted)
    {
        var vehicle = ExtensionCatalog.BuiltIn.Single(item => item.Id == ExtensionIds.VehicleDrivetrain);
        Assert.Equal(ExtensionIds.VehicleDrivetrain, vehicle.Id);
        var support = Assert.IsType<GameVersionSupport>(vehicle.SupportedVersions);
        Assert.Equal(new GameVersionSupport(VersionSupportScope.Major, "42", "42"), support);
        Assert.Equal("42", support.RangeText);
        Assert.Equal(admitted, support.Matches(version));

        using var temp = new TempDirectory();
        var service = new GameExtensionService(new ExtensionSettingsStore(temp.Path), () => version);
        var initial = Vehicle(service.ReadCards());
        var enabled = Vehicle(service.SetEnabled(vehicle.Id, true, initial.SettingsRevision));
        Assert.Equal(admitted, enabled.EffectiveEnabled);
        Assert.False(enabled.ForceVersion);
    }
    [Fact]
    public void VersionAdmissionIsSeparateFromSavedPreferencesAndStillRequiresOverrideOnMismatch()
    {
        using var temp = new TempDirectory();
        string? version = "41.78";
        var definition = ExtensionCatalog.BuiltIn.Single(item => item.Id == ExtensionIds.VehicleDrivetrain) with { SupportedVersions = new(VersionSupportScope.Major, "42") };
        var store = new ExtensionSettingsStore(temp.Path);
        var service = new GameExtensionService(store, () => version, () => new[] { definition });
        var first = Vehicle(service.ReadCards());
        Assert.False(first.CanEnable);
        var requested = Vehicle(service.SetEnabled(definition.Id, true, first.SettingsRevision));
        Assert.True(requested.Enabled);
        Assert.False(requested.EffectiveEnabled);
        Assert.Equal("version-mismatch", requested.StatusCode);
        var forced = Vehicle(service.SetPreference(definition.Id, true, true, requested.SettingsRevision));
        Assert.True(forced.EffectiveEnabled);
        Assert.Equal("forced-version", forced.StatusCode);
        var off = Vehicle(service.SetEnabled(definition.Id, false, forced.SettingsRevision));
        Assert.True(off.ForceVersion);
        Assert.False(off.Enabled);
        version = "42.20";
        var normal = Vehicle(service.SetPreference(definition.Id, true, false, off.SettingsRevision));
        Assert.True(normal.EffectiveEnabled);
        version = null;
        var unknown = Vehicle(service.ReadCards());
        Assert.True(unknown.Enabled); // Desired preference is retained, but cannot be applied blindly.
        Assert.False(unknown.EffectiveEnabled);
        Assert.Equal("version-unknown", unknown.StatusCode);
        version = "43.0";
        Assert.True(Vehicle(service.ReadCards()).EffectiveEnabled);
        Assert.True(new ExtensionSettingsStore(temp.Path).Read().Extensions[definition.Id].Enabled);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void OfflineUnknownVersionAllowsSavingDesiredOnWithoutClaimingCompatibility(bool usePreferenceCommand)
    {
        using var temp = new TempDirectory();
        var definition = ExtensionCatalog.BuiltIn.Single(item => item.Id == ExtensionIds.VehicleDrivetrain);
        var service = new GameExtensionService(new ExtensionSettingsStore(temp.Path), () => null, () => [definition]);
        var initial = Vehicle(service.ReadCards());
        Assert.False(initial.CanEnable);
        var saved = Assert.Single(usePreferenceCommand
            ? service.SetPreference(definition.Id, true, false, initial.SettingsRevision)
            : service.SetEnabled(definition.Id, true, initial.SettingsRevision));
        Assert.True(saved.Enabled);
        Assert.False(saved.ForceVersion);
        Assert.False(saved.EffectiveEnabled);
        Assert.Equal("version-unknown", saved.StatusCode);
        Assert.True(new ExtensionSettingsStore(temp.Path).Read().Extensions[definition.Id].Enabled);
    }
    [Fact]
    public async Task VersionProjectionUsesTheSharedFeedWithoutRewritingSettings()
    {
        using var temp = new TempDirectory();
        string? version = "42.20";
        var store = new ExtensionSettingsStore(temp.Path);
        var views = new RevisionedViewStore();
        var controller = new GameExtensionController(temp.Path, views, gameVersion: () => version);
        var original = await controller.RefreshAsync();
        Assert.All(original.Cards, card => Assert.Equal("42.20", card.GameVersion));
        var revision = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0).ViewRevision;
        await controller.RefreshRuntimeAsync(default);
        Assert.Equal(revision, views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0).ViewRevision);
        version = null;
        await controller.RefreshRuntimeAsync(default);
        Assert.All(views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, revision).Snapshot!.Cards, card => Assert.Null(card.GameVersion));
        Assert.False(File.Exists(store.FilePath));
    }
    [Fact]
    public void VersionIsOptionalRuntimeMetadataNotASecondPauseAuthority()
    {
        var id = Guid.NewGuid().ToString("N");
        var state = new RuntimeSnapshot(id, id, id, 0, 0, 1, WorldPhase.Menu, GamePause.Unknown,
            RuntimeMode.LocalSinglePlayer, -1, 0, 0, null, "42.20").Validate();
        Assert.Equal(state, RuntimeJson.Read<RuntimeSnapshot>(RuntimeJson.Write(state)));
        string prefix = $"STATE2\t{id}\t{id}\t{id}\t0\t0\t1\tMenu\tUnknown\tLocalSinglePlayer\t-1\t0\t0\t-\t{RuntimeSnapshot.Capabilities}";
        Assert.Equal(state, RuntimeSnapshot.ParseWire(prefix + "\t" + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("42.20"))));
    }
    private static ExtensionCardView Vehicle(IEnumerable<ExtensionCardView> cards) =>
        cards.Single(card => card.Definition.Id == ExtensionIds.VehicleDrivetrain);
}
