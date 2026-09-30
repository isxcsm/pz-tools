using System.Text.Json;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class ReadOnlyRestoreTests
{
    [Fact]
    public async Task Restore_ReadOnlyOriginalAndRestoredFiles_CleansRollbackAndAllowsAnotherRestore()
    {
        using var fixture = new Fixture();
        var (repository, source) = await fixture.CreateRevisionAsync();
        var target = fixture.Path("Save");
        Fixture.WriteReadOnly(Path.Combine(target, "nested", "original.bin"), "original");
        var service = new SafeRevisionRestoreService();

        for (var attempt = 0; attempt < 2; attempt++)
        {
            var result = await service.RestoreReplacingAsync(repository, source.SourceId, 1, target);

            Assert.Equal(1, result.Files);
            AssertReadOnlyFile(Path.Combine(target, "restored.bin"), "restored");
            Assert.False(Directory.Exists(Path.Combine(target, "nested")));
            fixture.AssertNoRestoreInventory();
        }
    }

    [Fact]
    public async Task CancelledRestore_DiscardsReadOnlyStagingWithoutChangingOriginal_AndCanRetry()
    {
        using var fixture = new Fixture();
        var (repository, source) = await fixture.CreateRevisionAsync();
        var target = fixture.Path("Save");
        var original = Path.Combine(target, "original.bin");
        Fixture.WriteReadOnly(original, "original");
        var originalAttributes = File.GetAttributes(original);
        var service = new SafeRevisionRestoreService();
        var observedReadOnlyStaging = false;

        await Assert.ThrowsAsync<OperationCanceledException>(() => service.RestoreReplacingAsync(
            repository, source.SourceId, 1, target, (progress, _) =>
            {
                // Attributes are applied once every file has been written and flushed.
                if (progress.Event == "workload.completed")
                {
                    var staging = Assert.Single(Directory.GetDirectories(fixture.Root, ".Save.pztools-staging-*"));
                    AssertReadOnlyFile(Path.Combine(staging, "restored.bin"), "restored");
                    observedReadOnlyStaging = true;
                    throw new OperationCanceledException("cancel after applying file metadata");
                }
                return Task.CompletedTask;
            }));

        Assert.True(observedReadOnlyStaging);
        AssertReadOnlyFile(original, "original");
        Assert.Equal(originalAttributes, File.GetAttributes(original));
        fixture.AssertNoRestoreInventory();
        await service.RestoreReplacingAsync(repository, source.SourceId, 1, target);
        AssertReadOnlyFile(Path.Combine(target, "restored.bin"), "restored");
        fixture.AssertNoRestoreInventory();
    }

    [Fact]
    public async Task FailedRestore_WhileSaveBecomesInUse_LeavesOriginalAndNoInventory()
    {
        using var fixture = new Fixture();
        var (repository, source) = await fixture.CreateRevisionAsync();
        var target = fixture.Path("Save");
        var players = Path.Combine(target, "players.db");
        Directory.CreateDirectory(target);
        File.WriteAllText(players, "original");
        FileStream? game = null;
        try
        {
            var error = await Assert.ThrowsAsync<IOException>(() => new SafeRevisionRestoreService().RestoreReplacingAsync(
                repository, source.SourceId, 1, target, (progress, _) =>
                {
                    if (progress.Event != "file.restore.completed") return Task.CompletedTask;
                    // The game opens the save mid-restore, then the restore fails.
                    game ??= new FileStream(players, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
                    throw new IOException("restore failed for its own reason");
                }));

            Assert.Equal("restore failed for its own reason", error.Message);
            Assert.NotNull(game);
            fixture.AssertNoRestoreInventory();
        }
        finally { game?.Dispose(); }
        Assert.Equal("original", File.ReadAllText(players));
    }

    [Fact]
    public async Task Recovery_UntouchedSaveInUse_StillDiscardsJournalAndStaging()
    {
        using var fixture = new Fixture();
        var inventory = fixture.CreateInventory();
        Directory.CreateDirectory(inventory.Staging);
        var players = Path.Combine(inventory.Target, "players.db");
        Directory.CreateDirectory(inventory.Target);
        File.WriteAllText(players, "original");
        await fixture.WriteJournalAsync(inventory, "prepared");

        using (new FileStream(players, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            await new SafeRevisionRestoreService().RecoverAsync(inventory.Target);

        Assert.Equal("original", File.ReadAllText(players));
        fixture.AssertNoRestoreInventory();
    }

    [Theory]
    [InlineData("prepared")]
    [InlineData("original-moved")]
    public async Task Recovery_DiscardsReadOnlyStagingAndPreservesOriginalAttributes(string phase)
    {
        using var fixture = new Fixture();
        var inventory = fixture.CreateInventory();
        Fixture.WriteReadOnly(Path.Combine(inventory.Staging, "partial.bin"), "partial restore");
        var originalDirectory = phase == "prepared" ? inventory.Target : inventory.Rollback;
        var original = Path.Combine(originalDirectory, "original.bin");
        Fixture.WriteReadOnly(original, "irreplaceable original");
        var originalAttributes = File.GetAttributes(original);
        await fixture.WriteJournalAsync(inventory, phase);

        var service = new SafeRevisionRestoreService();
        await service.RecoverAsync(inventory.Target);
        await service.RecoverAsync(inventory.Target);

        var returnedOriginal = Path.Combine(inventory.Target, "original.bin");
        AssertReadOnlyFile(returnedOriginal, "irreplaceable original");
        Assert.Equal(originalAttributes, File.GetAttributes(returnedOriginal));
        fixture.AssertNoRestoreInventory();
    }

    [Fact]
    public async Task Recovery_InstalledReadOnlyRollback_CanRetryAfterAFileLockIsReleased()
    {
        using var fixture = new Fixture();
        var inventory = fixture.CreateInventory();
        Fixture.WriteReadOnly(Path.Combine(inventory.Staging, "restored.bin"), "restored");
        var original = Path.Combine(inventory.Rollback, "original.bin");
        Fixture.WriteReadOnly(original, "original");
        await fixture.WriteJournalAsync(inventory, "installed");
        Directory.Move(inventory.Staging, inventory.Target);
        var service = new SafeRevisionRestoreService();

        using (var locked = new FileStream(original, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        {
            var error = await Record.ExceptionAsync(() => service.RecoverAsync(inventory.Target));
            Assert.True(error is IOException or UnauthorizedAccessException, error?.ToString());
            Assert.Equal("original", await File.ReadAllTextAsync(original));
            AssertReadOnlyFile(Path.Combine(inventory.Target, "restored.bin"), "restored");
            Assert.True(File.Exists(fixture.Path(".Save.pztools-restore.json")));
        }

        await service.RecoverAsync(inventory.Target);
        await service.RecoverAsync(inventory.Target);
        AssertReadOnlyFile(Path.Combine(inventory.Target, "restored.bin"), "restored");
        fixture.AssertNoRestoreInventory();
    }

    [Fact]
    public async Task Cleanup_ReparseAnywhereInInventory_PreventsAllReadOnlyAttributeChanges()
    {
        using var fixture = new Fixture();
        var inventory = fixture.Path("inventory");
        var outside = fixture.Path("outside");
        var insideFile = Path.Combine(inventory, "inside.bin");
        var outsideFile = Path.Combine(outside, "outside.bin");
        Fixture.WriteReadOnly(insideFile, "inside");
        Fixture.WriteReadOnly(outsideFile, "outside");
        File.SetAttributes(inventory, File.GetAttributes(inventory) | FileAttributes.ReadOnly);
        var rootAttributes = File.GetAttributes(inventory);
        var insideAttributes = File.GetAttributes(insideFile);
        var outsideAttributes = File.GetAttributes(outsideFile);
        var link = Path.Combine(inventory, "linked");
        var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");
        var junction = await new ChildProcessHost().RunAsync(shell,
            ["-NoProfile", "-Command",
                $"New-Item -ItemType Junction -Path '{link.Replace("'", "''")}' -Target '{outside.Replace("'", "''")}'"]);
        Assert.True(junction.ExitCode == 0, junction.StandardError);
        try
        {
            var error = Assert.Throws<IOException>(() => SafeRevisionRestoreService.DeleteOperationDirectory(inventory));

            Assert.Contains("linked-operation-inventory", error.Message);
            Assert.Equal(rootAttributes, File.GetAttributes(inventory));
            Assert.Equal(insideAttributes, File.GetAttributes(insideFile));
            Assert.Equal(outsideAttributes, File.GetAttributes(outsideFile));
            AssertReadOnlyFile(insideFile, "inside");
            AssertReadOnlyFile(outsideFile, "outside");
        }
        finally
        {
            Directory.Delete(link);
        }
    }

    private static void AssertReadOnlyFile(string path, string expected)
    {
        Assert.Equal(expected, File.ReadAllText(path));
        Assert.True((File.GetAttributes(path) & FileAttributes.ReadOnly) != 0);
    }

    private sealed record Inventory(string Target, string Staging, string Rollback);

    private sealed class Fixture : IDisposable
    {
        private readonly TempDirectory temp = new();
        internal string Root => temp.Path;
        internal string Path(string name) => temp.GetPath(name);

        internal static void WriteReadOnly(string path, string contents)
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            File.WriteAllText(path, contents);
            File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.ReadOnly);
        }

        internal Inventory CreateInventory()
        {
            var token = Guid.NewGuid().ToString("N");
            return new(Path("Save"), Path($".Save.pztools-staging-{token}"), Path($".Save.pztools-rollback-{token}"));
        }

        internal async Task WriteJournalAsync(Inventory inventory, string phase)
        {
            await File.WriteAllTextAsync(Path(".Save.pztools-restore.json"), JsonSerializer.Serialize(new
            {
                Version = 2, TargetPath = inventory.Target, StagingPath = inventory.Staging,
                RollbackPath = inventory.Rollback, Phase = phase,
                StagingIdentity = new WindowsFileMetadataReader().ReadPath(inventory.Staging).Identity,
            }));
        }

        internal void AssertNoRestoreInventory() =>
            Assert.Empty(Directory.GetFileSystemEntries(Root, ".Save.pztools-*"));

        internal async Task<(RepositoryDatabase Repository, RepositorySource Source)> CreateRevisionAsync()
        {
            var sourcePath = Path("source");
            WriteReadOnly(System.IO.Path.Combine(sourcePath, "restored.bin"), "restored");
            var repository = await RepositoryDatabase.CreateOrOpenAsync(Path("repository"));
            var telemetry = await TelemetryStore.CreateOrOpenAsync(repository.RepositoryPath);
            await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
            var source = await repository.AddOrGetSourceAsync(lease, "test", sourcePath);
            var metadata = new WindowsFileMetadataReader();
            await new InitialBackupRunner(new StreamingFullScanner(metadata),
                new StableFileCapturer(metadata), new NoBoundary()).RunAsync(repository, telemetry, lease, source,
                new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, ContentDeduplication: false),
                new TelemetryOptions(TelemetryMode.Off, 16, 10, 10, 32));
            return (repository, source);
        }

        public void Dispose()
        {
            // Test-created originals and successful restored files intentionally
            // retain ReadOnly; normalize only this isolated fixture for teardown.
            var pending = new Stack<string>();
            pending.Push(Root);
            while (pending.TryPop(out var path))
            {
                var attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0) continue;
                if ((attributes & FileAttributes.ReadOnly) != 0)
                    File.SetAttributes(path, attributes & ~FileAttributes.ReadOnly);
                if ((attributes & FileAttributes.Directory) != 0)
                    foreach (var child in Directory.GetFileSystemEntries(path)) pending.Push(child);
            }
            temp.Dispose();
        }
    }

    private sealed class NoBoundary : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(null, "test");
    }
}
