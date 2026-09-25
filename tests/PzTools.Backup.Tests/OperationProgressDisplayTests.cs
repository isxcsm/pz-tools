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

    [Theory]
    [InlineData("restore")]
    [InlineData("import")]
    [InlineData("character-recovery")]
    public void PlaceholderIsReplacedOnlyByTheNewMatchingWorker(string kind)
    {
        var local = Operation(OperationStatus.Running, TelemetryHealth.Waiting, null) with { Kind = kind, RunIndex = 0 };
        var old = local with { RunIndex = 10 };
        var current = local with { RunIndex = 11, TotalItems = 10, TelemetryHealth = TelemetryHealth.Healthy };
        Assert.Same(local, OperationProgressDisplay.SelectForeground(new OperationsView([old]), local, 10));
        Assert.Same(current, OperationProgressDisplay.SelectForeground(new OperationsView([old, current]), local, 10));
        Assert.Same(local, OperationProgressDisplay.SelectForeground(new OperationsView([current with { Kind = "export" }]), local, 10));
    }

    [Theory]
    [InlineData(OperationStatus.Running)]
    [InlineData(OperationStatus.Succeeded)]
    [InlineData(OperationStatus.Failed)]
    public void LocalDeletionRemainsVisibleDespiteOlderWorkerProjections(OperationStatus status)
    {
        var local = Operation(status, TelemetryHealth.Waiting, null) with { Kind = "delete-save", RunIndex = 0 };
        var old = Operation(OperationStatus.Running, TelemetryHealth.Healthy, 10) with { RunIndex = 12 };
        var selected = OperationProgressDisplay.SelectForeground(new OperationsView([old]), local, 12);
        Assert.Same(local, selected);
        Assert.Equal(status == OperationStatus.Running, OperationProgressDisplay.From(selected).IsIndeterminate);
        Assert.Same(old, OperationProgressDisplay.SelectForeground(new OperationsView([old]), null, 12));
    }

    [Fact]
    public void NewForegroundWorkReplacesCompletedDeletion()
    {
        var local = Operation(OperationStatus.Succeeded, TelemetryHealth.Waiting, null) with { Kind = "delete-save", RunIndex = 0 };
        var next = Operation(OperationStatus.Running, TelemetryHealth.Healthy, 10) with { RunIndex = 13, OperationId = "next" };
        Assert.Same(next, OperationProgressDisplay.SelectForeground(new OperationsView([next]), local, 12));
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

    [Fact]
    public void ExportCardReplacesLocalSpinnerWithProjectedProgress()
    {
        var local = Operation(OperationStatus.Running, TelemetryHealth.Waiting, null)
            with { Kind = "export", RunIndex = 0, OperationId = "current" };
        var previous = local with { OperationId = "previous", RunIndex = 10,
            Status = OperationStatus.Succeeded };
        var projected = local with { OperationId = "current", RunIndex = 11,
            Phase = "archive.snapshot", CompletedItems = 123, TotalItems = 2502,
            TelemetryHealth = TelemetryHealth.Healthy };

        Assert.Same(local, OperationProgressDisplay.SelectExport(
            new OperationsView([previous]), local, 10));
        var selected = OperationProgressDisplay.SelectExport(
            new OperationsView([projected, previous]), local, 10);
        Assert.Same(projected, selected);
        Assert.Equal(new OperationProgressDisplay(true, false),
            OperationProgressDisplay.From(selected));
    }

    [Fact]
    public void CompletedExportDoesNotRevertToStaleRunningProjection()
    {
        var completed = Operation(OperationStatus.Succeeded, TelemetryHealth.Waiting, null)
            with { Kind = "export", RunIndex = 11 };
        var staleRunning = completed with { Status = OperationStatus.Running,
            TotalItems = 5, TelemetryHealth = TelemetryHealth.Healthy };

        Assert.Same(completed, OperationProgressDisplay.SelectExport(
            new OperationsView([staleRunning]), completed, 10));
    }

    private static OperationView Operation(OperationStatus status, TelemetryHealth health, long? total) =>
        new("source", "operation", "restore", "restore-worker", 1, status,
            null, 3, total, 0, null, health, null, null);

    [Fact]
    public void ExceptionBeforeResultCannotBeReplacedByStaleProgressOfTheSameOperation()
    {
        var failed = Operation(OperationStatus.Failed, TelemetryHealth.Waiting, null)
            with { RunIndex = 0 };
        var stale = failed with { RunIndex = 11, Status = OperationStatus.Running };
        Assert.Same(failed, OperationProgressDisplay.SelectLocal([stale], failed, 10));
    }

    [Fact]
    public void NewerUnrelatedRunCannotHijackAnActiveLocalOperation()
    {
        var local = Operation(OperationStatus.Running, TelemetryHealth.Waiting, null) with { RunIndex = 0 };
        var other = local with { OperationId = "other", RunIndex = 12 };
        Assert.Same(local, OperationProgressDisplay.SelectLocal([other], local, 10));
    }
}
