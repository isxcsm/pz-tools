using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionProjectionTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PreferenceCommandsRejectStaleWritesAndCanRetryAfterRefreshing(bool changeVehicleOptions)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("runtime");
        var store = new ExtensionSettingsStore(root);
        var controller = new GameExtensionController(root, new RevisionedViewStore(), gameVersion: () => "42.20");
        var first = (await controller.RefreshAsync()).Cards.Single(card => card.Definition.Id == ExtensionIds.VehicleDrivetrain);
        var externalOptions = new VehicleDrivetrainPreference(false, false, true);
        var requestedOptions = new VehicleDrivetrainPreference(true, true, false);
        store.SetPreference(ExtensionIds.VehicleDrivetrain, new(true, false, externalOptions), first.SettingsRevision);

        Task<GameExtensionsView> Save(long revision) => changeVehicleOptions
            ? controller.SetVehicleDrivetrainPreferenceAsync(requestedOptions, revision)
            : controller.SetPreferenceAsync(ExtensionIds.VehicleDrivetrain, false, false, revision);

        await Assert.ThrowsAsync<ExtensionSettingsConflictException>(() => Save(first.SettingsRevision));
        var refreshed = (await controller.RefreshAsync()).Cards.Single(card => card.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.True(refreshed.Enabled);
        Assert.Equal(externalOptions, refreshed.VehicleDrivetrain);
        Assert.Equal(1, refreshed.SettingsRevision);

        var saved = (await Save(refreshed.SettingsRevision)).Cards.Single(card => card.Definition.Id == ExtensionIds.VehicleDrivetrain);
        Assert.Equal(changeVehicleOptions, saved.Enabled);
        Assert.Equal(changeVehicleOptions ? requestedOptions : externalOptions, saved.VehicleDrivetrain);
        Assert.Equal(2, saved.SettingsRevision);
        Assert.Equal(saved.VehicleDrivetrain, store.Read().Extensions[ExtensionIds.VehicleDrivetrain].VehicleDrivetrain);
    }

    [Fact]
    public async Task ProjectionReflectsGlobalSavePolicyWithoutPublishingUnchangedViews()
    {
        using var temp = new TempDirectory();
        var views = new RevisionedViewStore();
        var saveEnabled = false;
        var controller = new GameExtensionController(temp.GetPath("runtime"), views, () => saveEnabled);
        Assert.False((await controller.RefreshAsync()).GameSavingEnabled);
        var first = views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, 0);
        await controller.RefreshAsync();
        Assert.False(views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, first.ViewRevision).Modified);
        saveEnabled = true;
        Assert.True((await controller.RefreshAsync()).GameSavingEnabled);
        Assert.True(views.ReadIfChanged<GameExtensionsView>(GameExtensionController.ViewKey, first.ViewRevision).Modified);
    }
}
