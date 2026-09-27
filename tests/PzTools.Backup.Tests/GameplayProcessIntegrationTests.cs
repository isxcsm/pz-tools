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
        // The private fixture must not inherit a system binary's read-only attributes.
        File.SetAttributes(executable, FileAttributes.Normal);
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
            try
            {
                if (!game.HasExited)
                {
                    // EOF releases set /p without forcibly terminating a mapped image.
                    game.StandardInput.Close();
                    try { await game.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
                    catch (TimeoutException)
                    {
                        if (!game.HasExited) game.Kill();
                    }
                }
                await game.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
            }
            finally { game.Dispose(); }
            await DeleteFixtureExecutableAsync(executable);
        }
    }

    private static async Task DeleteFixtureExecutableAsync(string path)
    {
        // Only this test-owned executable gets a bounded retry after confirmed exit
        // and handle disposal. Never ignore cleanup failure or retry product work.
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                File.Delete(path);
                Assert.False(File.Exists(path));
                return;
            }
            catch (Exception exception) when (attempt < 49
                && (exception is IOException or UnauthorizedAccessException)
                && ((exception.HResult & 0xFFFF) is 5 or 32 or 33))
            {
                await Task.Delay(100);
            }
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
