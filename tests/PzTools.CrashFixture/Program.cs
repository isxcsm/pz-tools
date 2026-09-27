using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;
using PzTools.Process.Hosting;
using PzTools.Zomboid.Archive;
using System.IO.Compression;
using System.Text.Json;

// This executable is only referenced by the test project, never by the app or publisher.
var root = Path.GetFullPath(args[0]);
var mode = args[1];
if (mode == "app-instance")
{
    using var instance = ApplicationInstanceLease.TryAcquire(root);
    Console.WriteLine(instance is null ? "REJECTED" : "ACQUIRED");
    if (instance is not null) Console.ReadLine();
    return;
}
if (mode == "import")
{
    var archivePath = Path.Combine(root, "save.zip");
    using (var archive = ZipFile.Open(archivePath, ZipArchiveMode.Create))
    {
        await using (var player = archive.CreateEntry("Sandbox/Test/players.db", CompressionLevel.NoCompression).Open())
            await player.WriteAsync(new byte[2 * 1024 * 1024]);
        await using var manifest = archive.CreateEntry("Sandbox/Test/" + ZomboidArchiveService.ManifestEntryName).Open();
        await JsonSerializer.SerializeAsync(manifest, new ZomboidArchiveManifest(
            ZomboidArchiveService.FormatMarker, 2, "Sandbox/Test", "Sandbox", "Test",
            null, 0, 0, DateTimeOffset.UtcNow));
    }
    var savesRoot = Path.Combine(root, "Saves");
    await OperationMutexSet.TryRunAsync([new(OperationMutexScope.SaveWrite, savesRoot)], async token =>
    {
        await new ZomboidArchiveService().ImportAsync(archivePath, savesRoot, (progress, _) =>
        {
            if (progress.CompletedBytes > 0) PauseAt.Stop(root);
            return Task.CompletedTask;
        }, token);
        return true;
    });
    return;
}
var repositoryPath = Path.Combine(root, "repository");
var sourcePath = Path.Combine(root, "Saves", "Sandbox", "Test");
var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
await OperationMutexSet.TryRunAsync(
    [new(OperationMutexScope.RepositoryAccess, repositoryPath), new(OperationMutexScope.SaveWrite, sourcePath)],
    async token =>
    {
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", sourcePath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        var metadata = new WindowsFileMetadataReader();
        var runner = new InitialBackupRunner(new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata), new FixedBoundary(),
            mode == "restore" ? null : new PauseAt(Enum.Parse<BackupFailurePoint>(mode), root));
        await runner.RunAsync(repository, telemetry, lease, source,
            new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false),
            new TelemetryOptions(TelemetryMode.Off, 4, 5, 10, 32), cancellationToken: token);
        if (mode == "restore")
        {
            await File.WriteAllTextAsync(Path.Combine(sourcePath, "data.bin"), "original before restore", token);
            await new SafeRevisionRestoreService().RestoreReplacingAsync(repository, source.SourceId, 1, sourcePath,
                (progress, _) =>
                {
                    if (progress.Event == "file.restore.completed") PauseAt.Stop(root);
                    return Task.CompletedTask;
                }, token);
        }
        return true;
    });

sealed class FixedBoundary : ICheckpointBoundaryProvider
{
    public CheckpointBoundaryResult Capture(string path) => new(new SourceCheckpoint("1", "2", 100), null);
}

sealed class PauseAt(BackupFailurePoint point, string root) : IBackupFailureInjector
{
    public void ThrowIfRequested(BackupFailurePoint candidate)
    {
        if (point == candidate) Stop(root);
    }

    public static void Stop(string root)
    {
        File.WriteAllText(Path.Combine(root, "ready"), "ready");
        Thread.Sleep(Timeout.Infinite);
    }
}
