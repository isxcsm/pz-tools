using System.IO.Compression;
using PzTools.App.Core;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    /// <summary>
    /// The app starts the built install tool and reads its answer. Only <c>status</c> runs: install and uninstall
    /// write the player's install folder under ProgramData, and the Java test (StartupInstallTest) covers them.
    /// </summary>
    [Fact]
    public async Task StartupLoader_RunsTheBuiltInstallTool_AndReadsTheGameJar()
    {
        using var temp = new TempDirectory();
        var game = temp.GetPath("game");
        Directory.CreateDirectory(game);
        File.WriteAllBytes(Path.Combine(game, "ProjectZomboid64.exe"), []);
        using (var jar = ZipFile.Open(Path.Combine(game, "projectzomboid.jar"), ZipArchiveMode.Create))
            jar.CreateEntry("zombie/gameStates/MainScreenState.class");
        var loader = new StartupLoader(RuntimeBridgeDirectory(), () => game, () => false);
        await loader.RefreshAsync();
        // Reverted when this PC has a real install: its record names another jar than this one.
        Assert.Contains(loader.State.Status, new[] { StartupLoaderStatus.NotInstalled, StartupLoaderStatus.Reverted });
        Assert.Equal(game, loader.State.GameFolder);

        File.Delete(Path.Combine(game, "ProjectZomboid64.exe"));
        await loader.RefreshAsync();
        Assert.Equal(StartupLoaderStatus.NotFound, loader.State.Status);
    }
}
