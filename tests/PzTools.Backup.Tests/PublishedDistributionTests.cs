using System.IO.Compression;
using System.Text.Json;
using PzTools.GameExtensions;

namespace PzTools.Backup.Tests;

public sealed class PublishedDistributionTests
{
    private static string Root => Environment.GetEnvironmentVariable("PZTOOLS_DISTRIBUTION_DIR")!;

    [DistributionFact]
    public void AllEntryPointsTargetWindowsX64AndUseTheSharedDotNetRuntime()
    {
        string[] components = ["App", "Backup.Cli", "Backup.Runner", "Backup.Scheduler",
            "Maintenance.Cli", "Maintenance.Runner", "State.Collector.Cli", "State.Reactor.Cli",
            "State.Runner", "State.Scheduler", "Zomboid.Archive.Cli", "Zomboid.Recovery.Cli"];
        foreach (var component in components)
        {
            var prefix = Path.Combine(Root, "PzTools." + component);
            Assert.True(File.Exists(prefix + ".exe"), component);
            Assert.True(File.Exists(prefix + ".dll"), component);
            using var deps = JsonDocument.Parse(File.ReadAllText(prefix + ".deps.json"));
            Assert.EndsWith("/win-x64", deps.RootElement.GetProperty("runtimeTarget").GetProperty("name").GetString());
            using var config = JsonDocument.Parse(File.ReadAllText(prefix + ".runtimeconfig.json"));
            Assert.Equal("Microsoft.NETCore.App", config.RootElement.GetProperty("runtimeOptions")
                .GetProperty("framework").GetProperty("name").GetString());
        }
    }

    [DistributionFact]
    public void RuntimePayloadPreservesUiSqliteAndSaveBridgeWithoutUnusedComponents()
    {
        string[] required = ["PzTools.App.pri", "Microsoft.ui.xaml.dll", "Microsoft.WinUI.dll",
            "Microsoft.WindowsAppRuntime.dll", "CommunityToolkit.WinUI.Controls.SettingsControls.dll",
            "e_sqlite3.dll", "THIRD_PARTY_NOTICES.md", "save-bridge/pztools-save-bridge.jar", "save-bridge/pztools-save-bootstrap.jar",
            "save-bridge/pztools-attach-bootstrap.dll", "save-bridge/runtime/bin/java.exe",
            "save-bridge/runtime/bin/server/jvm.dll", "save-bridge/runtime/lib/modules",
            "save-bridge/runtime/release", "Assets/Brand/pztools.png", "Assets/Brand/pztools-home.png",
            "Assets/Navigation/home.svg", "Assets/Navigation/extensions.svg", "Assets/Navigation/pztools.ico"];
        foreach (var path in required)
            Assert.True(File.Exists(Path.Combine(Root, path)), path);
        Assert.NotEmpty(Directory.GetFiles(Path.Combine(Root, "save-bridge/runtime/legal"), "*", SearchOption.AllDirectories));
        Assert.NotEmpty(Directory.GetFiles(Path.Combine(Root, "defaults"), "*.toml", SearchOption.AllDirectories));
        Assert.False(Directory.Exists(Path.Combine(Root, "runtimes")));
        Assert.False(Directory.Exists(Path.Combine(Root, "workers")));
        Assert.False(File.Exists(Path.Combine(Root, "Assets/Brand/pztools-master.png")));
        Assert.False(File.Exists(Path.Combine(Root, "Assets/Navigation/pztools.svg")));
        var files = Directory.GetFiles(Root, "*", SearchOption.AllDirectories);
        Assert.Single(files, path => Path.GetFileName(path).Equals("e_sqlite3.dll", StringComparison.OrdinalIgnoreCase));
        Assert.Single(files, path => Path.GetFileName(path).Equals("java.exe", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(files, path => Path.GetExtension(path) is ".pdb" or ".lib");
        Assert.DoesNotContain(files, path => Path.GetFileName(path).StartsWith("Microsoft.Windows.AI.", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(path).StartsWith("Microsoft.Windows.Widgets", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(path).StartsWith("onnxruntime", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(path).Equals("DirectML.dll", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(path).Equals("System.Numerics.Tensors.dll", StringComparison.OrdinalIgnoreCase));
    }

    [DistributionFact]
    public void VehicleExtensionPublishesAnAbiConsistentCatalogueModuleAndValidatedConfiguration()
    {
        var bridge = Path.Combine(Root, "save-bridge");
        var extensions = Path.Combine(bridge, "extensions");
        string[] payload = ["pztools-extension-runtime.jar",
            "pztools-vehicle-drivetrain.jar", "catalog.tsv", "vehicle-drivetrain.toml"];
        foreach (var name in payload) Assert.True(File.Exists(Path.Combine(extensions, name)), name);
        Assert.Equal(payload.Where(name => name.EndsWith(".jar", StringComparison.Ordinal)).Order(),
            Directory.GetFiles(extensions, "*.jar").Select(Path.GetFileName).Order());
        Assert.False(File.Exists(Path.Combine(extensions, "pztools-seamless-save.jar")));
        Assert.False(File.Exists(Path.Combine(extensions, "pztools-test-save.jar")));
        foreach (var name in payload.Where(name => name.EndsWith(".jar", StringComparison.Ordinal)))
        {
            using var jar = ZipFile.OpenRead(Path.Combine(extensions, name));
            Assert.Equal("3", Manifest(jar)["PzTools-Extension-Api"]);
        }
        using (var runtime = ZipFile.OpenRead(Path.Combine(extensions, "pztools-extension-runtime.jar")))
        {
            Assert.NotNull(runtime.GetEntry("pztools/extensions/api/ContinuousProvider.class"));
            Assert.NotNull(runtime.GetEntry("pztools/extensions/api/VehicleHooks.class"));
            Assert.NotNull(runtime.GetEntry("pztools/extensions/runtime/ContinuousRuntime.class"));
        }
        var cataloguePath = Path.Combine(extensions, "catalog.tsv");
        var vehicle = Assert.Single(ExtensionCatalog.ReadFile(cataloguePath));
        Assert.Equal(ExtensionIds.VehicleDrivetrain, vehicle.Id);
        Assert.Equal("vehicle.drivetrain.v1", Assert.Single(vehicle.Capabilities));
        Assert.Equal(new GameVersionSupport(VersionSupportScope.Major, "42", "42"), vehicle.SupportedVersions);
        var row = Assert.Single(File.ReadLines(cataloguePath), line => line.StartsWith(ExtensionIds.VehicleDrivetrain + "\t", StringComparison.Ordinal)).Split('\t');
        Assert.Equal(11, row.Length);
        Assert.Equal("pztools-vehicle-drivetrain.jar", row[4]);
        using (var module = ZipFile.OpenRead(Path.Combine(extensions, row[4])))
        {
            Assert.NotNull(module.GetEntry(row[3].Replace('.', '/') + ".class"));
            Assert.NotNull(module.GetEntry("pztools/extensions/vehicle/model/DrivetrainModel.class"));
            Assert.NotNull(module.GetEntry("pztools/extensions/vehicle/model/SteeringModel.class"));
            Assert.NotNull(module.GetEntry("pztools/extensions/vehicle/model/VehicleProfile.class"));
        }
        foreach (var name in new[] { "pztools-save-bootstrap.jar", "pztools-save-bridge.jar" })
        {
            using var jar = ZipFile.OpenRead(Path.Combine(bridge, name));
            Assert.Equal("10", Manifest(jar)["PzTools-Bootstrap-Api"]);
            if (name == "pztools-save-bootstrap.jar")
            {
                Assert.NotNull(jar.GetEntry("pztools/bridge/AgentEntry.class"));
                Assert.NotNull(jar.GetEntry("pztools/extensions/api/VehicleHooks.class"));
                Assert.Null(jar.GetEntry("pztools/extensions/vehicle/VehicleDrivetrainProvider.class"));
            }
            else Assert.NotNull(jar.GetEntry("pztools/bridge/AttachMain.class"));
        }
        using var temporaryRuntime = new TempDirectory();
        var configuration = VehicleDrivetrainConfiguration.Load(bridge, temporaryRuntime.Path);
        var packagedConfiguration = Tomlyn.TomlSerializer.Deserialize<Tomlyn.Model.TomlTable>(
            File.ReadAllText(Path.Combine(extensions, "vehicle-drivetrain.toml")))!;
        Assert.Equal(configuration.Keys.Order(StringComparer.Ordinal), packagedConfiguration.Keys.Order(StringComparer.Ordinal));
        Assert.Equal(40, configuration.Count);
        Assert.Equal("1", configuration["schema_version"]);
        Assert.Equal("1", configuration["low_gear_boost"]);
        Assert.Equal("1", configuration["reverse_force_ratio"]);
        Assert.Equal("3.6", configuration["gear_ratio_span"]);
        Assert.Equal("false", configuration["probe_only"]);
        Assert.Equal("true", configuration["torque_enabled"]);
        Assert.Equal("true", configuration["reverse_enabled"]);
        Assert.Equal("true", configuration["steering_enabled"]);
        Assert.Equal("0", configuration["reverse_max_speed_kph"]);
        Assert.Equal("1", configuration["reverse_governor_start_fraction"]);
        Assert.Equal("0.8", configuration["reverse_ramp_seconds"]);
        Assert.Equal("1.8", configuration["steering_initial_rate"]);
        Assert.Equal("7.5", configuration["steering_full_rate"]);
        Assert.Equal("0.1", configuration["steering_ramp_seconds"]);
        Assert.Equal("8", configuration["steering_return_rate"]);
        Assert.Equal("8", configuration["steering_countersteer_rate"]);
        Assert.False(Directory.Exists(Path.Combine(temporaryRuntime.Path, "extensions")));
    }

    private static IReadOnlyDictionary<string, string> Manifest(ZipArchive archive)
    {
        var entry = archive.GetEntry("META-INF/MANIFEST.MF");
        Assert.NotNull(entry);
        using var reader = new StreamReader(entry.Open());
        // JAR manifests fold long logical headers using a leading space on the next line.
        var lines = reader.ReadToEnd().Replace("\r\n ", "", StringComparison.Ordinal)
            .Replace("\n ", "", StringComparison.Ordinal).Split('\n');
        return lines.Select(line => line.TrimEnd('\r')).TakeWhile(line => line.Length != 0)
            .Select(line => line.Split(": ", 2, StringSplitOptions.None))
            .ToDictionary(parts => parts[0], parts => parts[1], StringComparer.OrdinalIgnoreCase);
    }

    private sealed class DistributionFactAttribute : FactAttribute
    {
        public DistributionFactAttribute()
        {
            if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("PZTOOLS_DISTRIBUTION_DIR")))
                Skip = "Set PZTOOLS_DISTRIBUTION_DIR to a fresh publish-app output directory.";
        }
    }
}
