using PzTools.Backup.ChangeTracking.Windows;

namespace PzTools.Backup.Tests;

public sealed class UsnCheckpointEvaluatorTests
{
    [Theory]
    [InlineData(100, UsnCheckpointDecisionKind.FullScanJournalGap)]
    [InlineData(200, UsnCheckpointDecisionKind.Incremental)]
    [InlineData(500, UsnCheckpointDecisionKind.Incremental)]
    [InlineData(501, UsnCheckpointDecisionKind.FullScanCheckpointAhead)]
    public void Evaluate_UsesReadableJournalRange(long checkpointUsn, UsnCheckpointDecisionKind expected)
    {
        var checkpoint = new UsnCheckpoint(10, 20, checkpointUsn);
        var current = new UsnJournalState(10, 20, FirstUsn: 200, NextUsn: 500, LowestValidUsn: 50);

        var decision = UsnCheckpointEvaluator.Evaluate(checkpoint, current);

        Assert.Equal(expected, decision.Kind);
        Assert.Equal(expected == UsnCheckpointDecisionKind.Incremental, decision.CanReadIncrementally);
    }

    [Fact]
    public void Evaluate_RejectsDifferentJournalBeforeRangeCheck()
    {
        var checkpoint = new UsnCheckpoint(10, 19, 300);
        var current = new UsnJournalState(10, 20, FirstUsn: 200, NextUsn: 500, LowestValidUsn: 50);

        var decision = UsnCheckpointEvaluator.Evaluate(checkpoint, current);

        Assert.Equal(UsnCheckpointDecisionKind.FullScanJournalChanged, decision.Kind);
    }

    [Fact]
    public void Evaluate_RejectsDifferentVolume()
    {
        var checkpoint = new UsnCheckpoint(9, 20, 300);
        var current = new UsnJournalState(10, 20, FirstUsn: 200, NextUsn: 500, LowestValidUsn: 50);

        var decision = UsnCheckpointEvaluator.Evaluate(checkpoint, current);

        Assert.Equal(UsnCheckpointDecisionKind.FullScanVolumeChanged, decision.Kind);
    }
}

