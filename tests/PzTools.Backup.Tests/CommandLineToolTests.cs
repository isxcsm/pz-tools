using System.Diagnostics;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

/// <summary>The published command-line programs: what a bad command line returns, and what they lock.</summary>
public sealed class CommandLineToolTests
{
    [RequiresEnvironmentTheory("PZTOOLS_TOOLS_DIR")]
    [InlineData("restore", "--repository", "{repository}", "--source-id", "test", "--revision", "1", "--target", "{target}", "--targte", "x")]
    [InlineData("restore", "--repository", "{repository}", "--source-id", "test", "--revision", "1")]
    [InlineData("restore", "--repository", "{repository}", "--source-id", "test", "--revision", "0", "--target", "{target}")]
    [InlineData("restore", "--repository", "{repository}", "--source-id", "test", "--revision", "1", "--target", "{target}", "--run-index", "x")]
    [InlineData("maintenance", "prune", "--repository", "{repository}", "--source-id", "test", "--keep", "0")]
    [InlineData("verify", "--repository", "{repository}", "--repositroy", "x")]
    [InlineData("backup", "--repository", "{repository}", "--source-id", "test", "--revision", "0")]
    [InlineData("restroe", "--repository", "{repository}")]
    public async Task BackupCli_BadCommandLine_ExitsWithTheUsageCode(params string[] arguments)
    {
        using var temp = new TempDirectory();
        var result = await RunAsync("PzTools.Backup.Cli.exe", Fill(arguments, temp));
        Assert.True(result.ExitCode == ProcessExitCodes.InvalidArguments, result.Output + result.Error);
        Assert.False(Directory.Exists(temp.GetPath("repository")));
        Assert.False(Directory.Exists(temp.GetPath("target")));
    }

    [RequiresEnvironmentFact("PZTOOLS_TOOLS_DIR")]
    public async Task BackupCli_BackupWithoutRepository_CreatesNothingInTheCurrentFolder()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        await File.WriteAllTextAsync(Path.Combine(source, "map.bin"), "save");
        var config = temp.GetPath("backup.toml");
        await File.WriteAllTextAsync(config, "format_version = 1\n[telemetry]\nmode = 'off'\n");
        var current = temp.GetPath("current");
        Directory.CreateDirectory(current);

        var result = await RunAsync("PzTools.Backup.Cli.exe",
            ["backup", "--source-id", "test", "--source", $"test={source}", "--config", config,
                "--run-index", "7", "--control-db", temp.GetPath("control.db")], current);

        Assert.True(result.ExitCode == ProcessExitCodes.InvalidArguments, result.Output + result.Error);
        Assert.Contains("--repository", ProcessResultJson.Deserialize<object>(result.Output).Error?.Message);
        Assert.Empty(Directory.GetFileSystemEntries(current));
    }

    [RequiresEnvironmentFact("PZTOOLS_TOOLS_DIR")]
    public async Task BackupCli_Verify_IsBusyWhileCleanupHoldsTheBackupFolder()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));

        var locked = await OperationMutexSet.TryRunAsync(
            [new(OperationMutexScope.RepositoryAccess, repository.RepositoryPath)],
            _ => RunAsync("PzTools.Backup.Cli.exe", ["verify", "--repository", repository.RepositoryPath]));
        await using (RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var leased = await RunAsync("PzTools.Backup.Cli.exe", ["verify", "--repository", repository.RepositoryPath]);
            Assert.True(leased.ExitCode == ProcessExitCodes.Busy, leased.Output + leased.Error);
        }
        var free = await RunAsync("PzTools.Backup.Cli.exe", ["verify", "--repository", repository.RepositoryPath]);

        Assert.True(locked.Acquired);
        Assert.True(locked.Value!.ExitCode == ProcessExitCodes.Busy, locked.Value.Output + locked.Value.Error);
        Assert.True(free.ExitCode == ProcessExitCodes.Success, free.Output + free.Error);
    }

    [RequiresEnvironmentTheory("PZTOOLS_TOOLS_DIR")]
    [InlineData("inspect", "--archive", "{archive}", "--achive", "x")]
    [InlineData("import", "--archive", "{archive}", "--saves-root", "{saves}", "--saves-rot", "x")]
    [InlineData("export", "--repository", "{repository}", "--source-id", "x", "--revision", "1", "--output", "{archive}")]
    [InlineData("export-live", "--source", "{saves}", "--save-id", "Sandbox/Save", "--output", "{archive}", "--sav-id", "x")]
    [InlineData("exprot", "--archive", "{archive}")]
    public async Task ArchiveCli_BadCommandLine_ExitsWithTheUsageCode(params string[] arguments)
    {
        using var temp = new TempDirectory();
        var result = await RunAsync("PzTools.Zomboid.Archive.Cli.exe",
            [.. Fill(arguments, temp), "--run-index", "5", "--telemetry-identity", temp.GetPath("telemetry")]);
        Assert.True(result.ExitCode == ProcessExitCodes.InvalidArguments, result.Output + result.Error);
        Assert.Equal("invalid-arguments", ProcessResultJson.Deserialize<object>(result.Output).Error?.Code);
        Assert.False(Directory.Exists(temp.GetPath("saves")));
    }

    [RequiresEnvironmentFact("PZTOOLS_TOOLS_DIR")]
    public async Task ArchiveCli_ExportFromAMistypedBackupFolder_CreatesNothingThere()
    {
        using var temp = new TempDirectory();
        var mistyped = temp.GetPath("Backpus");

        var result = await RunAsync("PzTools.Zomboid.Archive.Cli.exe",
            ["export", "--repository", mistyped, "--source-id", "1", "--revision", "1",
                "--output", temp.GetPath("save.zip"), "--run-index", "5", "--telemetry-identity", temp.GetPath("telemetry")]);

        Assert.True(result.ExitCode == ProcessExitCodes.Failure, result.Output + result.Error);
        Assert.False(Directory.Exists(mistyped));
    }

    [RequiresEnvironmentTheory("PZTOOLS_TOOLS_DIR")]
    [InlineData("--repository", "{repository}", "--source-id", "0")]
    [InlineData("--repository", "{repository}", "--source-id", "1", "--retain-lates", "3")]
    [InlineData("--repository", "{repository}", "--source-id", "1", "--lane", "Everything")]
    [InlineData("--repository", "{repository}", "--lane", "OrphanBackups")]
    [InlineData("--repository", "{repository}", "--source-id", "1", "--dispatch-lanes", "true")]
    public async Task MaintenanceCli_BadCommandLine_ExitsWithTheUsageCode(params string[] arguments)
    {
        using var temp = new TempDirectory();
        var result = await RunAsync("PzTools.Maintenance.Cli.exe", Fill(arguments, temp));
        Assert.True(result.ExitCode == ProcessExitCodes.InvalidArguments, result.Output + result.Error);
        Assert.Equal("invalid-arguments", ProcessResultJson.Deserialize<object>(result.Output).Error?.Code);
    }

    [RequiresEnvironmentTheory("PZTOOLS_TOOLS_DIR")]
    [InlineData("PzTools.State.Collector.Cli.exe", "--state-db", "{state}", "--saves-root", "{saves}", "--stat-db", "x")]
    [InlineData("PzTools.State.Collector.Cli.exe", "--state-db", "{state}")]
    [InlineData("PzTools.State.Reactor.Cli.exe", "--state-db", "{state}", "--run-index", "0")]
    public async Task StatePrograms_BadCommandLine_ExitWithTheUsageCode(string program, params string[] arguments)
    {
        using var temp = new TempDirectory();
        var result = await RunAsync(program, Fill(arguments, temp));
        Assert.True(result.ExitCode == ProcessExitCodes.InvalidArguments, result.Output + result.Error);
        Assert.False(File.Exists(temp.GetPath("state.db")));
    }

    [RequiresEnvironmentFact("PZTOOLS_TOOLS_DIR")]
    public async Task StatePrograms_TakeTheCollectionLock_UnlessTheRunnerHoldsIt()
    {
        using var temp = new TempDirectory();
        var saves = temp.GetPath("saves");
        Directory.CreateDirectory(saves);
        var statePath = temp.GetPath("state.db");
        string[] collect = ["--state-db", statePath, "--saves-root", saves, "--run-index", "3"];
        string[] react = ["--state-db", statePath, "--run-index", "3"];

        var whileHeld = await NamedMutexRunner.TryRunAsync(
            NamedMutexRunner.CreateName("StateCollection", Path.GetFullPath(statePath)), async _ =>
            (
                Collector: await RunAsync("PzTools.State.Collector.Cli.exe", collect),
                Reactor: await RunAsync("PzTools.State.Reactor.Cli.exe", react),
                // The state runner holds the lock itself while its children run.
                FromRunner: await RunAsync("PzTools.State.Collector.Cli.exe", [.. collect, "--runner-holds-lock"])
            ));

        Assert.True(whileHeld.Acquired);
        var (collector, reactor, fromRunner) = whileHeld.Value;
        Assert.True(collector.ExitCode == ProcessExitCodes.Busy, collector.Output + collector.Error);
        Assert.Equal(ProcessOutcome.Busy, ProcessResultJson.Deserialize<object>(collector.Output).Outcome);
        Assert.True(reactor.ExitCode == ProcessExitCodes.Busy, reactor.Output + reactor.Error);
        Assert.True(fromRunner.ExitCode == ProcessExitCodes.Success, fromRunner.Output + fromRunner.Error);
        var alone = await RunAsync("PzTools.State.Reactor.Cli.exe", react);
        Assert.True(alone.ExitCode == ProcessExitCodes.Success, alone.Output + alone.Error);
        Assert.False(await (await StateDatabase.CreateOrOpenAsync(statePath)).HasPendingBatchesAsync());
    }

    private static string[] Fill(string[] arguments, TempDirectory temp) =>
        arguments.Select(argument => argument switch
        {
            "{repository}" => temp.GetPath("repository"),
            "{target}" => temp.GetPath("target"),
            "{archive}" => temp.GetPath("save.zip"),
            "{saves}" => temp.GetPath("saves"),
            "{state}" => temp.GetPath("state.db"),
            _ => argument,
        }).ToArray();

    private static async Task<ToolResult> RunAsync(string program, IReadOnlyList<string> arguments,
        string? workingDirectory = null)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!, program),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        if (workingDirectory is not null) startInfo.WorkingDirectory = workingDirectory;
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        using var process = System.Diagnostics.Process.Start(startInfo)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return new ToolResult(process.ExitCode, await output, await error);
    }

    private sealed record ToolResult(int ExitCode, string Output, string Error);
}
