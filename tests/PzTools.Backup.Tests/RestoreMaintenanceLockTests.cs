using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class RestoreMaintenanceLockTests
{
    [RequiresEnvironmentTheory("PZTOOLS_TOOLS_DIR")]
    [InlineData("prune")]
    [InlineData("gc")]
    public async Task DirectMaintenance_RespectsAnActiveRestoreRepositoryMutex(string operation)
    {
        using var temp = new TempDirectory();
        var repository = await CreateRepositoryAsync(temp);
        var orphan = Path.Combine(repository.RepositoryPath, "packs", "orphan.pzpack");
        await File.WriteAllTextAsync(orphan, "unreferenced fixture");

        var locked = await OperationMutexSet.TryRunAsync(
            [new(OperationMutexScope.RepositoryAccess, repository.RepositoryPath)], async token =>
            {
                List<string> arguments = ["maintenance", operation, "--repository", repository.RepositoryPath];
                if (operation == "prune") arguments.AddRange(["--source-id", "test", "--keep", "1"]);
                var child = await new ChildProcessHost().RunAsync(CliPath, arguments, cancellationToken: token);
                Assert.True(child.Started);
                Assert.Equal(ProcessExitCodes.Busy, child.ExitCode);
                Assert.Contains("repository_busy", child.StandardError);
                return true;
            });

        Assert.True(locked.Acquired);
        Assert.True(File.Exists(orphan));
        Assert.Equal(2, Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions.Count);
    }

    [RequiresEnvironmentFact("PZTOOLS_TOOLS_DIR")]
    public async Task Restore_ReportsBusyWhileMaintenanceOwnsWriterLease_ThenSucceedsAfterRelease()
    {
        using var temp = new TempDirectory();
        var repository = await CreateRepositoryAsync(temp);
        var target = temp.GetPath("target");
        Directory.CreateDirectory(target);
        var original = Path.Combine(target, "original.txt");
        await File.WriteAllTextAsync(original, "preserve me until restore succeeds");
        var config = temp.GetPath("restore.toml");
        await File.WriteAllTextAsync(config, "[telemetry]\nenabled=false\n");
        string[] arguments = ["restore", "--repository", repository.RepositoryPath,
            "--source-id", "test", "--revision", "1", "--target", target,
            "--run-index", "42", "--config", config, "--telemetry-identity", temp.GetPath("restore-telemetry")];

        using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var blocked = await new ChildProcessHost().RunAsync(CliPath, arguments);
            Assert.Equal(ProcessExitCodes.Busy, blocked.ExitCode);
            Assert.Equal(ProcessOutcome.Busy,
                ProcessResultJson.Deserialize<SafeRestoreResult>(blocked.StandardOutput).Outcome);
            Assert.Equal("preserve me until restore succeeds", await File.ReadAllTextAsync(original));
        }

        var completed = await new ChildProcessHost().RunAsync(CliPath, arguments);
        Assert.True(completed.ExitCode == ProcessExitCodes.Success, completed.StandardOutput + completed.StandardError);
        Assert.Equal(ProcessOutcome.Succeeded,
            ProcessResultJson.Deserialize<SafeRestoreResult>(completed.StandardOutput).Outcome);
        Assert.True(Directory.Exists(Path.Combine(target, "folder")));
        Assert.False(File.Exists(original));
    }

    private static string CliPath => Path.Combine(
        Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!, "PzTools.Backup.Cli.exe");

    private static async Task<RepositoryDatabase> CreateRepositoryAsync(TempDirectory temp)
    {
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "test", temp.GetPath("source"));
        var now = DateTimeOffset.UtcNow;
        await RevisionReadConsistencyTests.CommitDirectoryAsync(repository, lease, source.SourceId, now);
        await RevisionReadConsistencyTests.CommitDirectoryAsync(repository, lease, source.SourceId, now.AddSeconds(1));
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "UPDATE revisions SET backup_kind='Automatic';";
        await command.ExecuteNonQueryAsync();
        return repository;
    }
}
