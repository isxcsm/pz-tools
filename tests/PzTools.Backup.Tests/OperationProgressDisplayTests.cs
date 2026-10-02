using PzTools.App.Core;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class OperationProgressDisplayTests
{
    [Theory]
    [InlineData("deduplication")]
    [InlineData("archive.snapshot")]
    [InlineData("archive.compress")]
    [InlineData("archive.restore")]
    [InlineData("restore")]
    [InlineData("import")]
    public void LargeFileUsesByteProgressBeforeAnyFileCompletes(string phase)
    {
        var operation = Operation(OperationStatus.Running, TelemetryHealth.Healthy, null) with
        { Phase = phase, CompletedItems = 0, CompletedBytes = 500, TotalBytes = 1000 };
        Assert.True(OperationProgressDisplay.UsesBytes(operation));
        Assert.False(OperationProgressDisplay.From(operation).IsIndeterminate);
    }

    [Fact]
    public void LocalDeletionCountsDoNotDependOnWorkerTelemetryHealth()
    {
        var operation = Operation(OperationStatus.Running, TelemetryHealth.Healthy, 20) with { Kind = "delete-save" };
        Assert.False(OperationProgressDisplay.From(operation, telemetryFaulted: true).IsIndeterminate);
    }

    [Fact]
    public void NonRunningOrMissingOperationNeverShowsOrAnimatesProgress()
    {
        Assert.Equal(new OperationProgressDisplay(false, false), OperationProgressDisplay.From(null));
        foreach (var status in Enum.GetValues<OperationStatus>().Where(status => status != OperationStatus.Running))
        foreach (var health in Enum.GetValues<TelemetryHealth>())
        foreach (var total in new long?[] { null, 0, 10 })
        foreach (var faulted in new[] { false, true })
            Assert.Equal(new OperationProgressDisplay(false, false),
                OperationProgressDisplay.From(Operation(status, health, total), faulted));
    }

    [Theory]
    [InlineData(TelemetryHealth.Healthy, 10L, false, false)]
    [InlineData(TelemetryHealth.Healthy, 10L, true, true)]
    [InlineData(TelemetryHealth.Healthy, null, false, true)]
    [InlineData(TelemetryHealth.Healthy, 0L, false, true)]
    [InlineData(TelemetryHealth.Waiting, null, false, true)]
    [InlineData(TelemetryHealth.Stale, 10L, false, true)]
    [InlineData(TelemetryHealth.Unreadable, 10L, false, true)]
    public void RunningProgressUsesTotalsOnlyWhenTelemetryIsHealthy(
        TelemetryHealth health, long? total, bool faulted, bool indeterminate)
    {
        Assert.Equal(new OperationProgressDisplay(true, indeterminate),
            OperationProgressDisplay.From(Operation(OperationStatus.Running, health, total), faulted));
    }

    private static OperationView Operation(OperationStatus status, TelemetryHealth health, long? total) =>
        new("source", "operation", "restore", "restore-worker", 1, status,
            null, 3, total, 0, null, health, null, null);
}
