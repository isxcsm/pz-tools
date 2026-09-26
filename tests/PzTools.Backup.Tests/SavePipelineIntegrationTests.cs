using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.SaveBridge;
using System.Text.Json;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task SavePipeline_ReadinessPauseAndWriteCompletionFenceInitialAndIncrementalBackups()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("world");
        var bridge = temp.GetPath("bridge");
        Directory.CreateDirectory(source);
        foreach (var path in Directory.EnumerateFiles(RuntimeBridgeDirectory(), "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(bridge, Path.GetRelativePath(RuntimeBridgeDirectory(), path));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(path, target);
        }
        File.Copy(Environment.GetEnvironmentVariable("PZTOOLS_EXTENSION_FIXTURE_JAR")!,
            Path.Combine(bridge, "extensions", "pztools-seamless-save.jar"), true);
        await File.WriteAllTextAsync(Path.Combine(source, "flush-game"), "require full fixture game save");
        await File.WriteAllTextAsync(Path.Combine(source, "cooperative-fixture"), "incremental capture");
        await File.WriteAllTextAsync(Path.Combine(source, "block-preparation"), "busy prior writes");
        await using var game = await FakeGame.StartAsync(source, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid, bridge);
        var options = new BackupOptions(BackupConfiguration.CurrentFormatVersion, temp.GetPath("repository"),
            [new BackupSourceOptions("world", source)],
            new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false),
            new TelemetryOptions(TelemetryMode.Phase, 16, 10, 10, 32))
            { AlwaysIncludePaths = ["memory-only-state.txt", "calls.txt", "extension-written"] };
        long ordinal = 0;
        Task<OneShotBackupResult> BackupAsync(RuntimeSnapshot snapshot) =>
            new OneShotBackupService(new UsnJournalReader(), async (path, token) =>
            {
                var client = new GameSaveClient(bridge, runtimeTicket: Ticket(snapshot, ++ordinal));
                try
                {
                    var receipt = await client.RequestProviderAsync(game.Pid, path, "pztools.seamless-save", token);
                    Assert.Equal(GameSaveCompletion.DetachedWritesCommitted, receipt.Completion);
                    Assert.Contains("captureStatsV1=", receipt.Detail);
                    Assert.Contains("maxCaptureSliceMs=", receipt.Detail);
                    return new BackupPreparationResult("saved", receipt.Detail);
                }
                catch (GameSaveException error) when (error.Code == "runtime-deferred")
                { throw new BackupPreparationDeferredException(error.Message, error.Diagnostics); }
            }).RunAsync(options, "world");

        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        var waiting = BackupAsync(ready);
        await AwaitExtensionFileAsync(Path.Combine(source, "preparation-waiting"));
        await watch.WaitAsync(s => s.Sequence > ready.Sequence + 1);
        Assert.False(File.Exists(Path.Combine(source, "calls.txt"))); // No partial save during readiness.
        await File.WriteAllTextAsync(Path.Combine(source, "pause-game"), "pause");
        var paused = await watch.WaitAsync(s => s.Pause == GamePause.Paused);
        var deferred = await Assert.ThrowsAsync<BackupPreparationDeferredException>(() => waiting);
        Assert.Contains("bridgeAdmissionStatsV1=", deferred.Diagnostics);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(options.RepositoryPath);
        using (var cancelled = JsonDocument.Parse(Assert.Single(await telemetry.ReadEventsAsync(1),
            item => item.Name == "run.cancelled").PayloadJson!))
        {
            Assert.Equal("source-deferred", cancelled.RootElement.GetProperty("code").GetString());
            Assert.Equal(deferred.Diagnostics, cancelled.RootElement.GetProperty("diagnostics").GetString());
        }
        Assert.False(File.Exists(Path.Combine(source, "extension-started")));

        File.Delete(Path.Combine(source, "block-preparation"));
        await File.WriteAllTextAsync(Path.Combine(source, "resume-game"), "resume");
        await watch.WaitAsync(s => s.Pause == GamePause.Running && s.EligibilityEpoch >= paused.EligibilityEpoch);
        for (int revision = 1; revision <= 2; revision++)
        {
            File.Delete(Path.Combine(source, "extension-started"));
            File.Delete(Path.Combine(source, "release-extension"));
            var current = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
            await File.WriteAllTextAsync(Path.Combine(source, "block-cooperative"), "busy capture inputs");
            File.Delete(Path.Combine(source, "cooperative-waiting"));
            var backup = BackupAsync(current);
            try
            {
                await AwaitExtensionFileAsync(Path.Combine(source, "cooperative-waiting"));
                await watch.WaitAsync(s => s.Sequence > current.Sequence + 1);
                Assert.False(backup.IsCompleted);
                File.Delete(Path.Combine(source, "block-cooperative"));
                await AwaitExtensionFileAsync(Path.Combine(source, "extension-started"));
                Assert.False(backup.IsCompleted); // Source capture cannot precede the provider's final write.
                Assert.Equal(revision.ToString(), await File.ReadAllTextAsync(Path.Combine(source, "memory-only-state.txt")));
            }
            finally {
                File.Delete(Path.Combine(source, "block-cooperative"));
                await File.WriteAllTextAsync(Path.Combine(source, "release-extension"), "complete");
            }
            Assert.Equal(revision, (await backup).Revision);
        }
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        var identity = await repository.GetSourceAsync("world");
        for (int revision = 1; revision <= 2; revision++)
        {
            var restored = temp.GetPath($"restore-{revision}");
            await new RevisionRestorer().RestoreAsync(repository, identity.SourceId, revision, restored);
            Assert.Equal(revision.ToString(), await File.ReadAllTextAsync(Path.Combine(restored, "memory-only-state.txt")));
            Assert.Equal(revision, File.ReadAllLines(Path.Combine(restored, "calls.txt")).Length);
            Assert.True(File.Exists(Path.Combine(restored, "extension-written")));
        }
    }
}
