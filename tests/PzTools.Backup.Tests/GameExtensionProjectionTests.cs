using PzTools.App.Core;
using PzTools.GameExtensions;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionProjectionTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ASaveOverAStaleCardIsRefusedAndCanBeRetriedAfterReadingAgain(bool changeVehicleOptions)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("runtime");
        var store = new ExtensionSettingsStore(root);
        var service = new GameExtensionService(store, () => "42.20");
        var first = Vehicle(service.ReadCards());
        var externalOptions = VehicleOptions.Of(false, false, true);
        var requestedOptions = VehicleOptions.Of(true, true, false);
        store.SetPreference(VehicleDrivetrainExtension.Id, new(true, false, externalOptions), first.SettingsRevision);

        IReadOnlyList<ExtensionCardView> Save(ExtensionCardView card) => service.Save(card, changeVehicleOptions
            ? card.Preference with { Options = requestedOptions } : card.Preference with { Enabled = false });

        Assert.Throws<ExtensionSettingsConflictException>(() => Save(first));
        var refreshed = Vehicle(service.ReadCards());
        Assert.True(refreshed.Enabled);
        VehicleOptions.AssertSame(externalOptions, refreshed.Options);
        Assert.Equal(1, refreshed.SettingsRevision);

        var saved = Vehicle(Save(refreshed));
        Assert.Equal(changeVehicleOptions, saved.Enabled);
        VehicleOptions.AssertSame(changeVehicleOptions ? requestedOptions : externalOptions, saved.Options);
        Assert.Equal(2, saved.SettingsRevision);
        Assert.Equal(saved.Preference, store.Read().Extensions[VehicleDrivetrainExtension.Id]);
    }

    private static ExtensionCardView Vehicle(IEnumerable<ExtensionCardView> cards) =>
        cards.Single(card => card.Definition.Id == VehicleDrivetrainExtension.Id);

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
