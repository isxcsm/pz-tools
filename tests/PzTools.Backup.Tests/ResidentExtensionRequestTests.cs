using System.Text;
using PzTools.App.Core;
using PzTools.GameExtensions;

namespace PzTools.Backup.Tests;

/// <summary>What a game the startup loader started runs while the app is away, as the app writes it for the game.</summary>
public sealed class ResidentExtensionRequestTests
{
    private static (string Bridge, string Runtime) Folders(TempDirectory temp)
    {
        var bridge = temp.GetPath("bridge");
        Directory.CreateDirectory(Path.Combine(bridge, "extensions"));
        File.WriteAllText(Path.Combine(bridge, "extensions", "vehicle-drivetrain.toml"), "schema_version = 1\nforce_scale = 1.25\n");
        return (bridge, temp.GetPath("runtime"));
    }

    private static string[] Fields(string request, string id) =>
        request.Split('\n').Single(line => line.StartsWith("module\t" + id + "\t", StringComparison.Ordinal)).Split('\t');

    [Fact]
    public void Build_NamesTheSettingsRevision_AndEachContinuousModule_WithTheConfigurationTheAppWouldSend()
    {
        using var temp = new TempDirectory();
        var (bridge, runtime) = Folders(temp);
        var store = new ExtensionSettingsStore(runtime);
        Assert.Equal(["off", "normal", ""], Fields(ResidentExtensionRequest.Build(bridge, runtime), VehicleDrivetrainExtension.Id)[2..]);

        var saved = store.SetPreference(VehicleDrivetrainExtension.Id,
            new(Enabled: true, ForceVersion: true, Options: VehicleOptions.Of(reverse: false)), store.Read().Revision);
        var request = ResidentExtensionRequest.Build(bridge, runtime);
        Assert.StartsWith($"PZTOOLS-RESIDENT\t1\nrevision\t{saved.Revision}\n", request);
        var fields = Fields(request, VehicleDrivetrainExtension.Id);
        Assert.Equal(["on", "force"], fields[2..4]);
        var expected = ContinuousConfiguration.For(VehicleDrivetrainExtension.Id, bridge, runtime, saved.Extensions[VehicleDrivetrainExtension.Id]);
        Assert.Equal(ContinuousConfiguration.Encode(expected), fields[4]);
        var sent = Encoding.UTF8.GetString(Convert.FromBase64String(fields[4]));
        Assert.Contains("force_scale\t1.25\n", sent);
        Assert.Contains("reverse_enabled\tfalse\n", sent);
    }

    [Fact]
    public void Build_TurnsOffAModuleWhoseConfigurationCannotBeBuilt()
    {
        using var temp = new TempDirectory();
        var (bridge, runtime) = Folders(temp);
        var store = new ExtensionSettingsStore(runtime);
        store.SetPreference(VehicleDrivetrainExtension.Id, new(Enabled: true, ForceVersion: true), store.Read().Revision);
        var tuning = VehicleDrivetrainConfiguration.OverridePath(runtime);
        Directory.CreateDirectory(Path.GetDirectoryName(tuning)!);
        File.WriteAllText(tuning, "force_scale = 99");
        // Off, as the app turns it off while connected (configuration-rejected): the game runs its own code. The saved
        // preference is the app's to change, not the request's.
        Assert.Equal(["off", "force", ""], Fields(ResidentExtensionRequest.Build(bridge, runtime), VehicleDrivetrainExtension.Id)[2..]);
        Assert.True(store.Read().Extensions[VehicleDrivetrainExtension.Id].Enabled);
        // Once the file can be read again, the module is on again.
        File.WriteAllText(tuning, "force_scale = 0.9");
        Assert.Equal("on", Fields(ResidentExtensionRequest.Build(bridge, runtime), VehicleDrivetrainExtension.Id)[2]);
    }

    [Fact]
    public void Write_ReplacesTheFileOnlyWhenItChanged()
    {
        using var temp = new TempDirectory();
        var folder = temp.GetPath("install");
        Directory.CreateDirectory(folder);
        Assert.True(ResidentExtensionRequest.Write(folder, "PZTOOLS-RESIDENT\t1\nrevision\t1\n"));
        var file = Path.Combine(folder, ResidentExtensionRequest.FileName);
        var written = File.GetLastWriteTimeUtc(file);
        Assert.False(ResidentExtensionRequest.Write(folder, "PZTOOLS-RESIDENT\t1\nrevision\t1\n"));
        Assert.Equal(written, File.GetLastWriteTimeUtc(file));
        Assert.True(ResidentExtensionRequest.Write(folder, "PZTOOLS-RESIDENT\t1\nrevision\t2\n"));
        Assert.Equal("PZTOOLS-RESIDENT\t1\nrevision\t2\n", File.ReadAllText(file));
        Assert.Single(Directory.GetFiles(folder));
    }

    [Fact]
    public async Task TheLoader_WritesTheRequestIntoItsInstallFolder_OnlyWhileInstalled()
    {
        using var temp = new TempDirectory();
        var (bridge, runtime) = Folders(temp);
        var install = temp.GetPath("install");
        Directory.CreateDirectory(install);
        string status = "PZTOOLS-STARTUP\tnot-installed";
        var loader = new StartupLoader(bridge, () => @"C:\Game", () => [],
            (_, _) => Task.FromResult((0, status)));
        await loader.RefreshAsync();
        Assert.False(await loader.UpdateResidentExtensionsAsync(runtime));
        Assert.Empty(Directory.GetFiles(install));

        status = $"PZTOOLS-STARTUP\tinstalled\tabc\t{install}";
        await loader.RefreshAsync();
        Assert.Equal(install, loader.State.InstallFolder);
        Assert.True(await loader.UpdateResidentExtensionsAsync(runtime));
        Assert.False(await loader.UpdateResidentExtensionsAsync(runtime));
        Assert.Equal(ResidentExtensionRequest.Build(bridge, runtime),
            File.ReadAllText(Path.Combine(install, ResidentExtensionRequest.FileName)));
    }

    [Fact]
    public async Task TheLoader_BuildsTheRequestAgain_OnlyWhenAFileItIsBuiltFromChanged()
    {
        using var temp = new TempDirectory();
        var (bridge, runtime) = Folders(temp);
        var install = temp.GetPath("install");
        Directory.CreateDirectory(install);
        var loader = new StartupLoader(bridge, () => @"C:\Game", () => [],
            (_, _) => Task.FromResult((0, $"PZTOOLS-STARTUP\tinstalled\tabc\t{install}")));
        await loader.RefreshAsync();
        var target = Path.Combine(install, ResidentExtensionRequest.FileName);
        Assert.True(await loader.UpdateResidentExtensionsAsync(runtime));
        var written = File.ReadAllText(target);

        // A request file changed in place but keeping its time and length: the inputs did not move, so it is not built
        // again (and so not compared). This is how the skip shows.
        var time = File.GetLastWriteTimeUtc(target);
        File.WriteAllText(target, written.Replace("PZTOOLS-RESIDENT", "PZTOOLS-RESIDENX"));
        File.SetLastWriteTimeUtc(target, time);
        Assert.False(await loader.UpdateResidentExtensionsAsync(runtime));
        Assert.StartsWith("PZTOOLS-RESIDENX", File.ReadAllText(target));

        // The request file's own time moved: built and written again.
        File.SetLastWriteTimeUtc(target, time.AddSeconds(-5));
        Assert.True(await loader.UpdateResidentExtensionsAsync(runtime));
        Assert.Equal(written, File.ReadAllText(target));

        // A saved setting changed.
        var store = new ExtensionSettingsStore(runtime);
        store.SetPreference(VehicleDrivetrainExtension.Id, new(Enabled: true, ForceVersion: false), store.Read().Revision);
        Assert.True(await loader.UpdateResidentExtensionsAsync(runtime));
        Assert.Equal(ResidentExtensionRequest.Build(bridge, runtime), File.ReadAllText(target));
        Assert.False(await loader.UpdateResidentExtensionsAsync(runtime));

        // A tuning file the extension's configuration names appeared.
        var tuning = VehicleDrivetrainConfiguration.OverridePath(runtime);
        Directory.CreateDirectory(Path.GetDirectoryName(tuning)!);
        File.WriteAllText(tuning, "force_scale = 0.75\n");
        Assert.True(await loader.UpdateResidentExtensionsAsync(runtime));
        Assert.Contains("force_scale\t0.75\n", Encoding.UTF8.GetString(Convert.FromBase64String(
            Fields(File.ReadAllText(target), VehicleDrivetrainExtension.Id)[4])));

        // The request file is gone.
        File.Delete(target);
        Assert.True(await loader.UpdateResidentExtensionsAsync(runtime));
        Assert.True(File.Exists(target));
    }
}
