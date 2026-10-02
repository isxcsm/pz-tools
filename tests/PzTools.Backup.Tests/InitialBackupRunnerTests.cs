using Microsoft.Data.Sqlite;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class InitialBackupRunnerTests
{
    private static readonly StorageOptions Storage = new(
        ChecksumAlgorithm.Sha256,
        CompressionAlgorithm.None,
        ContentDeduplication: false);

    private static readonly TelemetryOptions Telemetry = new(
        TelemetryMode.Raw,
        BatchSize: 8,
        FlushIntervalMilliseconds: 10,
        RetainRuns: 100,
        MaxDatabaseMib: 64);

    [Fact]
    public async Task Run_CommitsCompleteInitialRevisionAndCheckpoint()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(Path.Combine(sourcePath, "empty"));
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "one.txt"), "one");
        await File.WriteAllBytesAsync(Path.Combine(sourcePath, "two.bin"), [1, 2, 3, 4]);
        var checkpoint = new SourceCheckpoint("volume", "journal", 42);
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var runner = CreateRunner(new FixedBoundaryProvider(checkpoint));

        var result = await runner.RunAsync(
            repository,
            telemetry,
            lease,
            source,
            Storage,
            Telemetry);

        Assert.Equal(1, result.RunIndex);
        Assert.Equal(1, result.Revision);
        Assert.Equal(3, result.EntryCount);
        Assert.Equal(checkpoint, result.Checkpoint);
        var state = await repository.GetSourceStateAsync(source.SourceId);
        Assert.Equal(1, state.CurrentRevision);
        Assert.Equal(checkpoint, state.Checkpoint);

        await using var connection = await repository.OpenConnectionAsync();
        Assert.Equal(3, await ScalarAsync(connection, "SELECT COUNT(*) FROM entry_versions;"));
        Assert.Equal(2, await ScalarAsync(connection, "SELECT COUNT(*) FROM stored_objects;"));
        Assert.Equal(1, await ScalarAsync(connection, "SELECT COUNT(*) FROM packs;"));
        Assert.Equal("Succeeded", await TextScalarAsync(
            connection,
            "SELECT status FROM worker_runs WHERE run_index = 1;"));

        var packPath = Directory.GetFiles(Path.Combine(repositoryPath, "packs"), "*.pzpack").Single();
        await using var pack = await PackReader.OpenAsync(packPath, verifyPayloads: true);
        Assert.Equal(2, pack.Objects.Count);
        Assert.Equal("Succeeded", (await telemetry.ReadRunAsync(1))?.Status);
    }

    [Fact]
    public async Task Run_CaptureFailureCreatesNoRevisionOrCheckpoint()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "one.txt"), "one");
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "two.txt"), "two");
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var capturer = new FailingCapturer(new StableFileCapturer(new WindowsFileMetadataReader()));
        var runner = new InitialBackupRunner(
            new StreamingFullScanner(new WindowsFileMetadataReader()),
            capturer,
            new FixedBoundaryProvider(new SourceCheckpoint("volume", "journal", 42)));

        await Assert.ThrowsAsync<UnstableFileException>(() => runner.RunAsync(
            repository,
            telemetry,
            lease,
            source,
            Storage,
            Telemetry));

        var state = await repository.GetSourceStateAsync(source.SourceId);
        Assert.Equal(0, state.CurrentRevision);
        Assert.Null(state.Checkpoint);
        await using var connection = await repository.OpenConnectionAsync();
        Assert.Equal(0, await ScalarAsync(connection, "SELECT COUNT(*) FROM revisions;"));
        Assert.Equal(0, await ScalarAsync(connection, "SELECT COUNT(*) FROM packs;"));
        Assert.Equal("Failed", await TextScalarAsync(
            connection,
            "SELECT status FROM worker_runs WHERE run_index = 1;"));
        var failure = Assert.Single(await telemetry.ReadEventsAsync(1),
            item => item.Name == "run.failed");
        using (var details = System.Text.Json.JsonDocument.Parse(failure.PayloadJson!))
        {
            var root = details.RootElement;
            Assert.Equal("UnstableFileException", root.GetProperty("failureCode").GetString());
            Assert.Equal("capture", root.GetProperty("phase").GetString());
            Assert.EndsWith(".txt", root.GetProperty("path").GetString());
            Assert.False(Path.IsPathRooted(root.GetProperty("path").GetString()));
            Assert.Equal("file changed during capture", root.GetProperty("reason").GetString());
            Assert.Equal("file changed during capture", root.GetProperty("message").GetString());
        }
        Assert.Empty(Directory.GetFiles(Path.Combine(repositoryPath, "staging")));
        Assert.Empty(Directory.GetFiles(Path.Combine(repositoryPath, "packs")));
    }

    [Fact]
    public async Task Run_EmptySourceAdvancesCheckpointWithoutRevision()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var checkpoint = new SourceCheckpoint("volume", "journal", 99);
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);

        var result = await CreateRunner(new FixedBoundaryProvider(checkpoint)).RunAsync(
            repository,
            telemetry,
            lease,
            source,
            Storage,
            Telemetry);

        Assert.Null(result.Revision);
        var state = await repository.GetSourceStateAsync(source.SourceId);
        Assert.Equal(0, state.CurrentRevision);
        Assert.Equal(checkpoint, state.Checkpoint);
        await using var connection = await repository.OpenConnectionAsync();
        Assert.Equal(0, await ScalarAsync(connection, "SELECT COUNT(*) FROM revisions;"));
        Assert.Equal("Succeeded", await TextScalarAsync(
            connection,
            "SELECT status FROM worker_runs WHERE run_index = 1;"));
    }

    private static InitialBackupRunner CreateRunner(ICheckpointBoundaryProvider boundaryProvider)
    {
        var metadata = new WindowsFileMetadataReader();
        return new InitialBackupRunner(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata),
            boundaryProvider);
    }

    private static async Task<long> ScalarAsync(SqliteConnection connection, string sql)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToInt64(await command.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture);
    }

    private static async Task<string> TextScalarAsync(SqliteConnection connection, string sql)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToString(
            await command.ExecuteScalarAsync(),
            System.Globalization.CultureInfo.InvariantCulture)!;
    }

    private sealed class FixedBoundaryProvider(SourceCheckpoint? checkpoint)
        : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) =>
            new(checkpoint, FallbackReason: null);
    }

    private sealed class FailingCapturer(IStableFileCapturer inner) : IStableFileCapturer
    {
        private int count;

        public Task<StableFileCaptureResult> CaptureAsync(
            string path,
            PackWriter packWriter,
            ChecksumAlgorithm checksumAlgorithm,
            CompressionAlgorithm compressionAlgorithm,
            CancellationToken cancellationToken = default,
            Func<FileCopyProgress, ValueTask>? progress = null)
        {
            if (Interlocked.Increment(ref count) == 2)
            {
                throw new UnstableFileException(path, "file changed during capture");
            }

            return inner.CaptureAsync(
                path,
                packWriter,
                checksumAlgorithm,
                compressionAlgorithm,
                cancellationToken,
                progress);
        }
    }
}
