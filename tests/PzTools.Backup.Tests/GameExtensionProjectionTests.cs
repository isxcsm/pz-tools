using PzTools.App.Core;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class GameExtensionProjectionTests
{
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
