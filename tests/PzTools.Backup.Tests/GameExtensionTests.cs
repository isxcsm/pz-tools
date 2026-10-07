using System.Text.Json;
using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionTests
{
    [Fact]
    public void FirstReadDoesNotCreateSettingsAndEnabledIsNotApplied()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.GetPath("runtime"));
        var service = new GameExtensionService(store, () => "42.20");
        var card = Vehicle(service.ReadCards());
        Assert.Equal(VehicleDrivetrainExtension.Id, card.Definition.Id);
        Assert.False(card.Enabled);
        Assert.False(File.Exists(store.FilePath));
        var enabled = Vehicle(service.Save(card, card.Preference with { Enabled = true }));
        Assert.True(enabled.Enabled);
        Assert.Equal("runtime-pending", enabled.StatusCode);
    }

    [Fact]
    public void PreferencesRoundTripAndStaleWritesDoNotOverwriteOtherClients()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.GetPath("runtime"));
        store.SetEnabled("pztools.other-module", true, 0);
        var current = store.SetEnabled("pztools.test-save", true, 1);
        Assert.Throws<ExtensionSettingsConflictException>(() => store.SetEnabled("pztools.test-save", false, 1));
        var reopened = new ExtensionSettingsStore(temp.GetPath("runtime"));
        Assert.True(reopened.Read().Extensions["pztools.test-save"].Enabled);
        reopened.SetEnabled("pztools.test-save", false, current.Revision);
        Assert.True(reopened.Read().Extensions["pztools.other-module"].Enabled);
    }

    [Theory]
    [InlineData("invalid json")]
    [InlineData("{\"schemaVersion\":9,\"revision\":1,\"extensions\":{}}")]
    [InlineData("{\"schemaVersion\":1,\"revision\":1,\"extensions\":{\"pztools.vehicle-drivetrain\":{\"options\":{\"torqueEnabled\":1}}}}")]
    [InlineData("{\"schemaVersion\":1,\"revision\":1,\"extensions\":{\"pztools.vehicle-drivetrain\":{\"options\":{\"not a key\":true}}}}")]
    public void RejectedSettingsAreNeverRewritten(string original)
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.GetPath("runtime"));
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        File.WriteAllText(store.FilePath, original);
        Assert.Throws<InvalidDataException>(() => store.SetEnabled("pztools.test-save", true, 0));
        Assert.Equal(original, File.ReadAllText(store.FilePath));
    }

    [Fact]
    public async Task RemovedSavePreferencesDoNotRestoreAnExtensionCardOrChangeVehicleSettings()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("runtime");
        var store = new ExtensionSettingsStore(root);
        store.SetPreference("pztools.seamless-save", new(true, true), 0);
        var vehicle = new ExtensionPreference(true, false, VehicleOptions.Of(torque: false, steering: false));
        store.SetPreference(VehicleDrivetrainExtension.Id, vehicle, 1);
        var original = File.ReadAllText(store.FilePath);
        var controller = new GameExtensionController(root, new RevisionedViewStore(), gameVersion: () => "42.20");
        var card = Vehicle((await controller.RefreshAsync()).Cards);
        Assert.Equal(vehicle, card.Preference);
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            controller.ApplyEditAsync("pztools.seamless-save", GameExtensionSetting.Enabled, true));
        Assert.Equal(original, File.ReadAllText(store.FilePath));
    }

    /// <summary>
    /// What versions before options were kept by key wrote: the vehicle's switches in an object of its own. It keeps its
    /// meaning: read as the vehicle's options, written back in the new form by the next edit, with the same values.
    /// </summary>
    [Fact]
    public async Task AnEarlierVehicleObjectIsReadAsTheVehiclesOptions_AndTheNextWriteKeepsTheirMeaning()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        File.WriteAllText(store.FilePath, """
            {
              "schemaVersion": 1,
              "revision": 7,
              "extensions": {
                "pztools.vehicle-drivetrain": {
                  "enabled": true,
                  "forceVersion": true,
                  "vehicleDrivetrain": { "torqueEnabled": false, "reverseEnabled": true, "steeringEnabled": false }
                }
              }
            }
            """);
        // The light's switch was not written then: on, as it always read.
        var expected = new ExtensionPreference(true, true, VehicleOptions.Of(torque: false, steering: false));
        Assert.Equal(expected, store.Read().Extensions[VehicleDrivetrainExtension.Id]);

        var controller = new GameExtensionController(temp.Path, new RevisionedViewStore(), gameVersion: () => "42.20");
        var card = Vehicle((await controller.ApplyEditAsync(VehicleDrivetrainExtension.Id, GameExtensionSetting.Enabled, false)).Cards);
        Assert.Equal(expected with { Enabled = false }, card.Preference);
        var written = File.ReadAllText(store.FilePath);
        Assert.DoesNotContain("vehicleDrivetrain", written, StringComparison.Ordinal);
        using (var document = JsonDocument.Parse(written))
        {
            var options = document.RootElement.GetProperty("extensions").GetProperty(VehicleDrivetrainExtension.Id).GetProperty("options");
            Assert.False(options.GetProperty("torqueEnabled").GetBoolean());
            Assert.True(options.GetProperty("reverseEnabled").GetBoolean());
            Assert.False(options.GetProperty("steeringEnabled").GetBoolean());
            Assert.True(options.GetProperty("areaLightEnabled").GetBoolean());
        }
        var reread = store.Read();
        Assert.Equal(8, reread.Revision);
        Assert.Equal(expected with { Enabled = false }, reread.Extensions[VehicleDrivetrainExtension.Id]);
    }

    [Fact]
    public void SavedOptionsWinOverAnEarlierObject_AndAnotherExtensionNeverReadsTheVehiclesObject()
    {
        using var temp = new TempDirectory();
        var store = new ExtensionSettingsStore(temp.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        File.WriteAllText(store.FilePath, """
            {
              "schemaVersion": 1,
              "revision": 3,
              "extensions": {
                "pztools.vehicle-drivetrain": { "enabled": true, "options": { "torqueEnabled": true },
                  "vehicleDrivetrain": { "torqueEnabled": false } },
                "pztools.other-module": { "enabled": true, "vehicleDrivetrain": { "torqueEnabled": false } }
              }
            }
            """);
        var read = store.Read();
        VehicleOptions.AssertSame(new Dictionary<string, bool> { ["torqueEnabled"] = true }, read.Extensions[VehicleDrivetrainExtension.Id].Options);
        Assert.Null(read.Extensions["pztools.other-module"].Options);
        Assert.Equal(new ExtensionPreference(true), read.Extensions["pztools.other-module"]);
    }

    private static ExtensionCardView Vehicle(IEnumerable<ExtensionCardView> cards) =>
        cards.Single(card => card.Definition.Id == VehicleDrivetrainExtension.Id);
}
