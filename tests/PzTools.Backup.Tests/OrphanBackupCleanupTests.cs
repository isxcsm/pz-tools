using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class OrphanBackupCleanupTests
{
    [Theory]
    [InlineData("save-missing", true)]
    [InlineData("mode-missing", true)]
    [InlineData("present", false)]
    [InlineData("empty-save", false)]
    [InlineData("root-missing", false)]
    [InlineData("wrong-root", false)]
    [InlineData("restore-journal", false)]
    [InlineData("restore-rollback", false)]
    [InlineData("mode-not-directory", false)]
    [InlineData("running-workflow", false)]
    [InlineData("mode-reparse", false)]
    public async Task Cleanup_ReclaimsOnlyConfirmedMissingSaves(string scenario, bool shouldRemove)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Save");
        var repository = await SeedAsync(temp, save);
        var source = await repository.GetSourceAsync("Sandbox/Save");
        var packs = await repository.ReadPacksAsync();
        var scanRoot = root;
        switch (scenario)
        {
            case "save-missing":
            case "restore-journal":
            case "restore-rollback":
            case "running-workflow":
                Directory.Move(save, temp.GetPath("moved-save"));
                break;
            case "mode-missing": Directory.Move(Path.GetDirectoryName(save)!, temp.GetPath("moved-mode")); break;
            case "mode-not-directory":
                Directory.Move(Path.GetDirectoryName(save)!, temp.GetPath("moved-mode"));
                await File.WriteAllTextAsync(Path.GetDirectoryName(save)!, "not a directory");
                break;
            case "root-missing": Directory.Move(root, temp.GetPath("moved-root")); break;
            case "wrong-root": scanRoot = temp.GetPath("OtherSaves"); Directory.CreateDirectory(scanRoot); break;
            case "empty-save": File.Delete(Path.Combine(save, "players.db")); break;
            case "mode-reparse":
                Directory.Move(Path.GetDirectoryName(save)!, temp.GetPath("moved-mode"));
                var junction = await new ChildProcessHost().RunAsync(
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                    ["-NoProfile", "-Command", $"New-Item -ItemType Junction -Path '{Path.GetDirectoryName(save)!.Replace("'", "''")}' -Target '{temp.GetPath("moved-mode").Replace("'", "''")}'"]);
                Assert.True(junction.ExitCode == 0, junction.StandardError);
                Directory.Move(Path.Combine(temp.GetPath("moved-mode"), "Save"), temp.GetPath("moved-save"));
                break;
        }
        if (scenario == "restore-journal")
            await File.WriteAllTextAsync(Path.Combine(root, "Sandbox", ".Save.pztools-restore.json"), "{}");
        if (scenario == "restore-rollback")
            Directory.CreateDirectory(Path.Combine(root, "Sandbox", $".Save.pztools-rollback-{Guid.NewGuid():N}"));
        if (scenario == "running-workflow")
            await repository.ReserveWorkflowAsync("restore", source.SourceId, "test-restore");
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var result = await new OrphanBackupCleanupService().RunAsync(repository, lease, scanRoot);
        var revisions = Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions;
        if (shouldRemove)
        {
            Assert.Equal(new ReclaimedSaveBackups("Sandbox/Save", 1), Assert.Single(result.Removed));
            Assert.Empty(revisions);
            Assert.Empty(await repository.ReadPacksAsync());
            Assert.Empty(Directory.GetFiles(Path.Combine(repository.RepositoryPath, "packs"), "*.pzpack"));
            Assert.Null((await repository.GetSourceStateAsync(source.SourceId)).Checkpoint);
            Assert.Empty((await new OrphanBackupCleanupService().RunAsync(repository, lease, scanRoot)).Removed);
        }
        else
        {
            Assert.Empty(result.Removed);
            Assert.Single(revisions);
            Assert.Equal(packs, await repository.ReadPacksAsync());
        }
        if (scenario == "mode-reparse") Directory.Delete(Path.GetDirectoryName(save)!);
    }

    [Fact]
    public async Task Cleanup_RemovesManualAndAutomaticHistory_AndRecreatedSaveGetsNewRevision()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Save");
        var repository = await SeedAsync(temp, save);
        var source = await repository.GetSourceAsync("Sandbox/Save");
        var workflow = await repository.ReserveWorkflowAsync("backup-maintenance", source.SourceId, "backup-scheduler");
        await File.WriteAllTextAsync(Path.Combine(save, "players.db"), "second version");
        await new OneShotBackupService(new NoJournal()).RunAsync(Options(temp, save), "Sandbox/Save",
            new BackupExecutionOptions(workflow.RunIndex));
        await repository.CompleteWorkflowAsync(workflow.RunIndex, "backup-scheduler", WorkflowStatus.Succeeded);
        var before = Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions;
        Assert.Contains(before, item => item.Kind == PzTools.Backup.Core.BackupKind.Manual);
        Assert.Contains(before, item => item.Kind == PzTools.Backup.Core.BackupKind.Automatic);
        Directory.Move(save, temp.GetPath("moved-save"));
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var result = await new OrphanBackupCleanupService().RunAsync(repository, lease, root);
            Assert.Equal(2, Assert.Single(result.Removed).Revisions);
            Assert.Empty(await repository.ReadPacksAsync());
        }
        Directory.CreateDirectory(save);
        await File.WriteAllTextAsync(Path.Combine(save, "players.db"), "new character");
        var next = await new OneShotBackupService(new NoJournal()).RunAsync(Options(temp, save), "Sandbox/Save");
        Assert.Equal(3, next.Revision);
        var restored = temp.GetPath("restored");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 3, restored);
        Assert.Equal("new character", await File.ReadAllTextAsync(Path.Combine(restored, "players.db")));
    }

    [Fact]
    public async Task Cleanup_PreservesOtherSavesAndSharedObjects()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Save");
        var repository = await SeedAsync(temp, save);
        var other = Path.Combine(root, "Sandbox", "Other");
        Directory.CreateDirectory(other);
        await File.WriteAllTextAsync(Path.Combine(other, "players.db"), "first version");
        await new OneShotBackupService(new NoJournal()).RunAsync(Options(temp, other, "Sandbox/Other"), "Sandbox/Other");
        Directory.Move(save, temp.GetPath("moved-save"));
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var result = await new OrphanBackupCleanupService().RunAsync(repository, lease, root);
            Assert.Single(result.Removed);
        }
        var source = await repository.GetSourceAsync("Sandbox/Other");
        var restored = temp.GetPath("restored");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 1, restored);
        Assert.Equal("first version", await File.ReadAllTextAsync(Path.Combine(restored, "players.db")));
    }

    [PublishedToolsOnlyFact]
    public async Task PublishedLane_RespectsRepositoryLockAndDeletesWithoutAutomaticBackup()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Save");
        var repository = await SeedAsync(temp, save);
        Directory.Move(save, temp.GetPath("moved-save"));
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        await new PzTools.Control.RunIndexAllocator(temp.GetPath("control.db")).AllocateAsync();
        async Task<ChildProcessResult> RunAsync() => await new ChildProcessHost().RunAsync(
            Path.Combine(tools, "PzTools.Maintenance.Cli.exe"),
            ["--repository", repository.RepositoryPath, "--saves-root", root,
                "--lane", "OrphanBackups", "--control-db", temp.GetPath("control.db")]);
        var locked = await OperationMutexSet.TryRunAsync(
            [new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repository.RepositoryPath)],
            async _ => await RunAsync());
        Assert.True(locked.Acquired);
        Assert.Equal(ProcessExitCodes.FromOutcome(ProcessOutcome.Busy), locked.Value!.ExitCode);
        Assert.Single(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        var result = await RunAsync();
        Assert.Equal(0, result.ExitCode);
        Assert.Empty(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
    }

    [PublishedToolsOnlyFact]
    public async Task PublishedStateScheduler_DispatchesOrphanLaneWithoutBackupTarget()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        var save = Path.Combine(root, "Sandbox", "Save");
        var repository = await SeedAsync(temp, save);
        Directory.Move(save, temp.GetPath("moved-save"));
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        await new PzTools.Control.RunIndexAllocator(temp.GetPath("control.db")).AllocateAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var result = await new ChildProcessHost().RunAsync(Path.Combine(tools, "PzTools.State.Scheduler.exe"),
            ["--scheduler-db", temp.GetPath("scheduler.db"), "--state-db", temp.GetPath("state.db"),
                "--saves-root", root, "--repository", repository.RepositoryPath, "--worker-directory", tools,
                "--control-db", temp.GetPath("control.db"), "--once"], timeout.Token);
        Assert.True(result.ExitCode == 0, result.StandardError + result.StandardOutput);
        while (Assert.Single((await repository.ReadCatalogIfChangedAsync(-1, timeout.Token)).Sources).Revisions.Count > 0
            || await MaintenanceLaneSignal.IsRunningAsync(repository.RepositoryPath, "OrphanBackups", timeout.Token))
            await Task.Delay(50, timeout.Token);
        Assert.Empty(await repository.ReadPacksAsync());
    }

    private static async Task<RepositoryDatabase> SeedAsync(TempDirectory temp, string save)
    {
        Directory.CreateDirectory(save);
        await File.WriteAllTextAsync(Path.Combine(save, "players.db"), "first version");
        await new OneShotBackupService(new NoJournal()).RunAsync(Options(temp, save), "Sandbox/Save");
        return await RepositoryDatabase.OpenExistingAsync(temp.GetPath("repository"));
    }

    private static BackupOptions Options(TempDirectory temp, string save, string key = "Sandbox/Save") => new(
        BackupConfiguration.CurrentFormatVersion, temp.GetPath("repository"), [new(key, save)],
        new(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, ContentDeduplication: true),
        new(TelemetryMode.Off, 16, 10, 10, 32), SaveGameBeforeBackup: false);

    private sealed class NoJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new System.ComponentModel.Win32Exception(50);
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }

    private sealed class PublishedToolsOnlyFactAttribute : FactAttribute
    {
        public PublishedToolsOnlyFactAttribute()
        {
            if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")))
                Skip = "Set PZTOOLS_TOOLS_DIR to run the published maintenance worker.";
        }
    }
}
