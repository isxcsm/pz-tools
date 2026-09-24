using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class RepositoryRecoveryTests
{
    [Theory]
    [InlineData(BackupFailurePoint.BeforePackFlush, false, true, false)]
    [InlineData(BackupFailurePoint.AfterPackPromotion, false, false, true)]
    [InlineData(BackupFailurePoint.BeforeRepositoryCommit, false, false, true)]
    [InlineData(BackupFailurePoint.DuringRepositoryCommit, false, false, true)]
    [InlineData(BackupFailurePoint.AfterRepositoryCommit, true, false, false)]
    public async Task Recover_LeavesOldOrCompleteStateAtEveryCommitBoundary(
        BackupFailurePoint failurePoint,
        bool revisionCommitted,
        bool expectsQuarantine,
        bool expectsOrphan)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "data.bin"), "payload");
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
            sourceId = source.SourceId;
            var metadata = new WindowsFileMetadataReader();
            var runner = new InitialBackupRunner(
                new StreamingFullScanner(metadata),
                new StableFileCapturer(metadata),
                new FixedBoundaryProvider(),
                new SinglePointInjector(failurePoint));

            var exception = await Assert.ThrowsAsync<SimulatedProcessCrashException>(
                () => runner.RunAsync(
                    repository,
                    telemetry,
                    lease,
                    source,
                    new StorageOptions(
                        ChecksumAlgorithm.Sha256,
                        CompressionAlgorithm.None,
                        ContentDeduplication: false),
                    new TelemetryOptions(
                        TelemetryMode.Raw,
                        BatchSize: 4,
                        FlushIntervalMilliseconds: 5,
                        RetainRuns: 10,
                        MaxDatabaseMib: 32)));
            Assert.Equal(failurePoint, exception.Point);
        }

        var stateBeforeRecovery = await repository.GetSourceStateAsync(sourceId);
        Assert.Equal(revisionCommitted ? 1 : 0, stateBeforeRecovery.CurrentRevision);

        await using var recoveryLease = RepositoryWriterLease.Acquire(repositoryPath);
        var recovered = await new RepositoryRecoveryService().RecoverAsync(
            repository,
            telemetry,
            recoveryLease);
        var runs = await repository.ReadRunsAsync();
        var run = Assert.Single(runs);

        Assert.Equal(revisionCommitted ? RunStatus.Succeeded : RunStatus.Abandoned, run.Status);
        Assert.Equal(expectsQuarantine ? 1 : 0, recovered.QuarantinedTemporaryFiles);
        Assert.Equal(
            expectsOrphan,
            recovered.Issues.Any(item => item.Kind == RecoveryIssueKind.OrphanPack));
        Assert.False(recovered.HasMissingCommittedData);
        Assert.Equal(
            run.Status.ToString(),
            (await telemetry.ReadRunAsync(run.RunIndex))?.Status);
    }

    [Fact]
    public async Task Recover_ReportsMissingCommittedPack()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "data.bin"), "payload");
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var metadata = new WindowsFileMetadataReader();
        await new InitialBackupRunner(
            new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata),
            new FixedBoundaryProvider())
            .RunAsync(
                repository,
                telemetry,
                lease,
                source,
                new StorageOptions(
                    ChecksumAlgorithm.Sha256,
                    CompressionAlgorithm.None,
                    ContentDeduplication: false),
                new TelemetryOptions(
                    TelemetryMode.Off,
                    4,
                    5,
                    10,
                    32));
        File.Delete(Directory.GetFiles(Path.Combine(repositoryPath, "packs"), "*.pzpack").Single());

        var result = await new RepositoryRecoveryService().RecoverAsync(
            repository,
            telemetry,
            lease);

        Assert.True(result.HasMissingCommittedData);
        Assert.Contains(result.Issues, item => item.Kind == RecoveryIssueKind.MissingPack);
    }

    private sealed class FixedBoundaryProvider : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) =>
            new(new SourceCheckpoint("1", "2", 100), null);
    }

    private sealed class SinglePointInjector(BackupFailurePoint point) : IBackupFailureInjector
    {
        public void ThrowIfRequested(BackupFailurePoint candidate)
        {
            if (candidate == point)
            {
                throw new SimulatedProcessCrashException(point);
            }
        }
    }
}
