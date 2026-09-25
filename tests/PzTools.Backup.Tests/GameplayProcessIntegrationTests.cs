using System.Diagnostics;
using PzTools.Backup.Engine;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

[CollectionDefinition("Gameplay process isolation", DisableParallelization = true)]
public sealed class GameplayProcessIsolation { }

[Collection("Gameplay process isolation")]
public sealed class GameplayProcessIntegrationTests
{
    [PublishedGameplayFact]
    public async Task PublishedMaintenance_DefersBeforeOpeningRepository_WhenGameProcessExists()
    {
        using var temp = new TempDirectory();
        // A renamed Windows command interpreter simulates process presence only, never a game install.
        var executable = temp.GetPath("ProjectZomboid64.exe");
        File.Copy(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"), executable);
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        foreach (var argument in new[] { "/d", "/q", "/c", "echo READY & set /p hold=" }) start.ArgumentList.Add(argument);
        using var game = System.Diagnostics.Process.Start(start)!;
        try
        {
            Assert.Equal("READY", (await game.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10)))?.Trim());
            Assert.True(GameplayWorkGate.ShouldDeferMaintenance());
            var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
            var configuration = temp.GetPath("maintenance.toml");
            await File.WriteAllTextAsync(configuration, "[telemetry]\nenabled=false\n");
            var child = await new ChildProcessHost().RunAsync(Path.Combine(tools, "PzTools.Maintenance.Cli.exe"),
                ["--repository", temp.GetPath("must-not-open"), "--saves-root", temp.GetPath("saves"),
                    "--lane", "OrphanBackups", "--config", configuration, "--control-db", temp.GetPath("control.db")]);
            Assert.True(child.Started);
            Assert.True(child.ExitCode == ProcessExitCodes.FromOutcome(ProcessOutcome.Skipped), child.StandardError + child.StandardOutput);
            var result = ProcessResultJson.Deserialize<MaintenanceLaneResult>(child.StandardOutput);
            Assert.Equal(ProcessOutcome.Skipped, result.Outcome);
            Assert.Equal("deferred-during-gameplay", result.Result!.Detail);
            Assert.False(File.Exists(temp.GetPath("must-not-open/repository.db")));
            Assert.False(File.Exists(temp.GetPath("control.db")));
        }
        finally
        {
            if (!game.HasExited) game.Kill();
            await game.WaitForExitAsync();
        }
    }

    private sealed class PublishedGameplayFactAttribute : FactAttribute
    {
        public PublishedGameplayFactAttribute()
        {
            if (!OperatingSystem.IsWindows() || string.IsNullOrEmpty(Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")))
                Skip = "Requires the fresh Windows published distribution.";
        }
    }
}
