using System.Diagnostics;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class InterruptedOperationRecoveryTests
{
    [Theory]
    [InlineData("BeforePackFlush", false)]
    [InlineData("AfterPackPromotion", false)]
    [InlineData("BeforeRepositoryCommit", false)]
    [InlineData("DuringRepositoryCommit", false)]
    [InlineData("AfterRepositoryCommit", true)]
    [InlineData("restore", true)]
    public async Task KilledProcess_RecoversOldOrCommittedState(string mode, bool committed)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("crash");
        var save = Path.Combine(root, "Saves", "Sandbox", "Test");
        Directory.CreateDirectory(save);
        await File.WriteAllTextAsync(Path.Combine(save, "data.bin"), "backup payload");
        var info = new ProcessStartInfo("dotnet") { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in new[] { "exec", "--runtimeconfig",
                     Path.Combine(AppContext.BaseDirectory, "PzTools.Backup.Tests.runtimeconfig.json"),
                     "--depsfile", Path.Combine(AppContext.BaseDirectory, "PzTools.Backup.Tests.deps.json"),
                     Path.Combine(AppContext.BaseDirectory, "PzTools.CrashFixture.dll"), root, mode })
            info.ArgumentList.Add(argument);
        using var process = System.Diagnostics.Process.Start(info)!;
        var error = process.StandardError.ReadToEndAsync();
        var output = process.StandardOutput.ReadToEndAsync();
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            while (!File.Exists(Path.Combine(root, "ready")))
            {
                if (process.HasExited) Assert.Fail($"Fixture exited: {await error} {await output}");
                await Task.Delay(25, timeout.Token);
            }
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(timeout.Token);
        }
        finally
        {
            if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
        }
        var repository = await RepositoryDatabase.CreateOrOpenAsync(Path.Combine(root, "repository"));
        var recovery = new InterruptedOperationRecoveryService();
        var result = await recovery.TryRunAsync(repository, Path.Combine(root, "Saves"));
        Assert.False(result.Busy);
        Assert.Empty(result.Problems);
        var run = Assert.Single(await repository.ReadRunsAsync());
        Assert.Equal(committed ? RunStatus.Succeeded : RunStatus.Abandoned, run.Status);
        Assert.Equal(committed ? 1 : 0, (await repository.GetSourceStateAsync(run.SourceId)).CurrentRevision);
        Assert.Empty(Directory.GetFiles(Path.Combine(root, "repository", "staging"), "*.tmp", SearchOption.AllDirectories));
        Assert.Equal(committed ? 1 : 0, Directory.GetFiles(Path.Combine(root, "repository", "packs"), "*.pzpack").Length);
        Assert.Empty(Directory.GetFileSystemEntries(Path.GetDirectoryName(save)!, ".Test.pztools-*"));
        Assert.Equal(mode == "restore" ? "original before restore" : "backup payload",
            await File.ReadAllTextAsync(Path.Combine(save, "data.bin")));
        if (committed)
        {
            var restored = Path.Combine(root, "verify");
            await new RevisionRestorer().RestoreAsync(repository, run.SourceId, 1, restored);
            Assert.Equal("backup payload", await File.ReadAllTextAsync(Path.Combine(restored, "data.bin")));
        }
        var repeated = await recovery.TryRunAsync(repository, Path.Combine(root, "Saves"));
        Assert.Empty(repeated.Problems);
        Assert.Equal(0, repeated.RecoveredWorkflows + repeated.RecoveredSaves + repeated.DeletedArtifacts);
    }

    [Theory]
    [InlineData("{")]
    [InlineData("{\"Version\":9}")]
    public async Task CorruptJournal_DoesNotBlockOtherSaves_AndRetainsUncertainOriginal(string badJournal)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var mode = Path.Combine(root, "Sandbox");
        Directory.CreateDirectory(mode);
        var good = Path.Combine(mode, "Good");
        var staging = Path.Combine(mode, $".Good.pztools-staging-{Guid.NewGuid():N}");
        var rollback = staging.Replace(".pztools-staging-", ".pztools-rollback-");
        Directory.CreateDirectory(staging);
        Directory.CreateDirectory(rollback);
        await File.WriteAllTextAsync(Path.Combine(rollback, "original"), "keep");
        await File.WriteAllTextAsync(Path.Combine(mode, ".Good.pztools-restore.json"), JsonSerializer.Serialize(new
        { Version = 1, TargetPath = good, StagingPath = staging, RollbackPath = rollback, Phase = "original-moved" }));
        await File.WriteAllTextAsync(Path.Combine(mode, ".Bad.pztools-restore.json"), badJournal);
        var uncertain = Path.Combine(mode, $".Bad.pztools-rollback-{Guid.NewGuid():N}");
        Directory.CreateDirectory(uncertain);
        var result = await InterruptedOperationRecoveryService.RecoverSavesAsync(root);
        Assert.Equal(1, result.Recovered);
        Assert.Single(result.Problems);
        Assert.True(File.Exists(Path.Combine(good, "original")));
        Assert.False(Directory.Exists(staging));
        Assert.True(Directory.Exists(uncertain));
    }

    [Fact]
    public async Task UnjournaledHealStagingAndJournalTemporary_AreCleaned_ButRollbackIsPreserved()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var mode = Path.Combine(root, "Sandbox");
        Directory.CreateDirectory(Path.Combine(mode, "Heal"));
        var staging = Path.Combine(mode, $".Heal.pztools-staging-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        await File.WriteAllTextAsync(Path.Combine(staging, "players.db"), "partial");
        await File.WriteAllTextAsync(Path.Combine(mode, ".Heal.pztools-restore.json.tmp"), "partial");
        Directory.CreateDirectory(Path.Combine(mode, "Uncertain"));
        var rollback = Path.Combine(mode, $".Uncertain.pztools-rollback-{Guid.NewGuid():N}");
        Directory.CreateDirectory(rollback);
        var result = await InterruptedOperationRecoveryService.RecoverSavesAsync(root);
        Assert.Equal(2, result.DeletedArtifacts);
        Assert.Single(result.Problems);
        Assert.True(Directory.Exists(rollback));
        Assert.False(Directory.Exists(staging));
    }

    [Fact]
    public async Task RepositoryLockAndSaveLock_PreventCleanup_UntilReleased()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Test");
        Directory.CreateDirectory(save);
        var staging = Path.Combine(Path.GetDirectoryName(save)!, $".Test.pztools-staging-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        var service = new InterruptedOperationRecoveryService();
        await OperationMutexSet.TryRunAsync([new(OperationMutexScope.RepositoryAccess, repository.RepositoryPath)], async _ =>
        {
            Assert.True((await service.TryRunAsync(repository, root)).Busy);
            Assert.True(Directory.Exists(staging));
            return true;
        });
        await OperationMutexSet.TryRunAsync([new(OperationMutexScope.SaveWrite, save)], async _ =>
        {
            Assert.Equal(0, (await service.TryRunAsync(repository, root)).DeletedArtifacts);
            Assert.True(Directory.Exists(staging));
            return true;
        });
        Assert.Equal(1, (await service.TryRunAsync(repository, root)).DeletedArtifacts);
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(true, false, true)]
    [InlineData(true, true, false)]
    public async Task Ownership_ProtectsLiveProcessesAndDetectsReusedPid(bool stale, bool liveStage, bool recovered)
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var workflow = await repository.ReserveWorkflowAsync("backup", null, "test");
        if (liveStage) await repository.AttachWorkflowStageAsync(workflow.RunIndex, "worker");
        if (stale)
        {
            await using var db = new SqliteConnection($"Data Source={repository.DatabasePath};Pooling=False");
            await db.OpenAsync();
            await using var command = db.CreateCommand();
            // Same PID with a different start time must not be mistaken for this process.
            command.CommandText = "UPDATE workflow_runs SET owner_start_ticks=1;";
            await command.ExecuteNonQueryAsync();
        }
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var result = await repository.RecoverInterruptedWorkflowsAsync(lease);
        Assert.Equal(recovered ? 1 : 0, result.Recovered);
        Assert.Equal(recovered ? WorkflowStatus.Abandoned : WorkflowStatus.Running,
            (await repository.ReadWorkflowAsync(workflow.RunIndex)).Status);
    }

    [Fact]
    public async Task UnknownOwner_IsReportedAndPreserved()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var workflow = await repository.ReserveWorkflowAsync("backup", null, "test");
        await using (var db = await repository.OpenConnectionAsync())
        await using (var command = db.CreateCommand())
        {
            command.CommandText = "UPDATE workflow_runs SET owner_pid=NULL,owner_start_ticks=NULL;";
            await command.ExecuteNonQueryAsync();
        }
        var result = await new InterruptedOperationRecoveryService().TryRunAsync(repository, temp.GetPath("Saves"));
        Assert.Equal(0, result.RecoveredWorkflows);
        Assert.Single(result.Problems);
        Assert.Equal(WorkflowStatus.Running, (await repository.ReadWorkflowAsync(workflow.RunIndex)).Status);
    }

    [Fact]
    public async Task NestedJunctionInStaging_IsPreservedWithoutTouchingItsTarget()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Test");
        Directory.CreateDirectory(save);
        var staging = Path.Combine(Path.GetDirectoryName(save)!, $".Test.pztools-staging-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        var outside = temp.GetPath("unrelated");
        Directory.CreateDirectory(outside);
        await File.WriteAllTextAsync(Path.Combine(outside, "keep"), "original");
        var link = Path.Combine(staging, "link");
        var result = await new ChildProcessHost().RunAsync(
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            ["-NoProfile", "-Command", $"New-Item -ItemType Junction -Path '{link.Replace("'", "''")}' -Target '{outside.Replace("'", "''")}'"]);
        Assert.True(result.ExitCode == 0, result.StandardError);
        try
        {
            var sweep = await InterruptedOperationRecoveryService.RecoverSavesAsync(root);
            Assert.Single(sweep.Problems);
            Assert.Equal(0, sweep.DeletedArtifacts);
            Assert.Equal("original", await File.ReadAllTextAsync(Path.Combine(outside, "keep")));
            Assert.True(Directory.Exists(staging));
        }
        finally { Directory.Delete(link); }
    }

    [Fact]
    public async Task ActiveSave_IsNotCleanedUntilExclusiveAccessIsAvailable()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Test");
        Directory.CreateDirectory(save);
        var staging = Path.Combine(Path.GetDirectoryName(save)!, $".Test.pztools-staging-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        using (var active = new FileStream(Path.Combine(save, "players.db"), FileMode.Create, FileAccess.ReadWrite, FileShare.ReadWrite))
        {
            var result = await InterruptedOperationRecoveryService.RecoverSavesAsync(root);
            Assert.Single(result.Problems);
            Assert.Equal(0, result.DeletedArtifacts);
            Assert.True(Directory.Exists(staging));
        }
        Assert.Equal(1, (await InterruptedOperationRecoveryService.RecoverSavesAsync(root)).DeletedArtifacts);
    }
}
