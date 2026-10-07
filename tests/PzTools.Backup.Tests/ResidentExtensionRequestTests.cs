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
        Assert.Equal(["off", "normal", ""], Fields(ResidentExtensionRequest.Build(bridge, runtime), ExtensionIds.VehicleDrivetrain)[2..]);

        var saved = store.SetPreference(ExtensionIds.VehicleDrivetrain,
            new(Enabled: true, ForceVersion: true, VehicleDrivetrain: new(ReverseEnabled: false)), store.Read().Revision);
        var request = ResidentExtensionRequest.Build(bridge, runtime);
        Assert.StartsWith($"PZTOOLS-RESIDENT\t1\nrevision\t{saved.Revision}\n", request);
        var fields = Fields(request, ExtensionIds.VehicleDrivetrain);
        Assert.Equal(["on", "force"], fields[2..4]);
        var expected = ContinuousConfiguration.For(ExtensionIds.VehicleDrivetrain, bridge, runtime, saved.Extensions[ExtensionIds.VehicleDrivetrain]);
        Assert.Equal(ContinuousConfiguration.Encode(expected), fields[4]);
        var sent = Encoding.UTF8.GetString(Convert.FromBase64String(fields[4]));
        Assert.Contains("force_scale\t1.25\n", sent);
        Assert.Contains("reverse_enabled\tfalse\n", sent);
    }

    [Fact]
    public void Build_LeavesOutAModuleWhoseTuningCannotBeRead()
    {
        using var temp = new TempDirectory();
        var (bridge, runtime) = Folders(temp);
        var store = new ExtensionSettingsStore(runtime);
        store.SetEnabled(ExtensionIds.VehicleDrivetrain, true, store.Read().Revision);
        var tuning = VehicleDrivetrainConfiguration.OverridePath(runtime);
        Directory.CreateDirectory(Path.GetDirectoryName(tuning)!);
        File.WriteAllText(tuning, "force_scale = 99");
        // The game keeps what it runs, as the app does while connected when a tuning file is refused.
        Assert.DoesNotContain("module\t", ResidentExtensionRequest.Build(bridge, runtime));
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
}
