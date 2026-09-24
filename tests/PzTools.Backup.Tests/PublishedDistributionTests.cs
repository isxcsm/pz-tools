using System.Text.Json;

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
            "save-bridge/runtime/release"];
        foreach (var path in required)
            Assert.True(File.Exists(Path.Combine(Root, path)), path);
        Assert.NotEmpty(Directory.GetFiles(Path.Combine(Root, "save-bridge/runtime/legal"), "*", SearchOption.AllDirectories));
        Assert.NotEmpty(Directory.GetFiles(Path.Combine(Root, "defaults"), "*.toml", SearchOption.AllDirectories));
        Assert.False(Directory.Exists(Path.Combine(Root, "runtimes")));
        var files = Directory.GetFiles(Root, "*", SearchOption.AllDirectories);
        Assert.Single(files, path => Path.GetFileName(path).Equals("e_sqlite3.dll", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(files, path => Path.GetExtension(path) is ".pdb" or ".lib");
        Assert.DoesNotContain(files, path => Path.GetFileName(path).StartsWith("Microsoft.Windows.AI.", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(path).StartsWith("Microsoft.Windows.Widgets", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(path).StartsWith("onnxruntime", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(path).Equals("DirectML.dll", StringComparison.OrdinalIgnoreCase)
            || Path.GetFileName(path).Equals("System.Numerics.Tensors.dll", StringComparison.OrdinalIgnoreCase));
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
