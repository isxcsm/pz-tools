namespace PzTools.Backup.ChangeTracking.Windows;

public static class UsnCheckpointEvaluator
{
    public static UsnCheckpointDecision Evaluate(UsnCheckpoint checkpoint, UsnJournalState current)
    {
        ArgumentNullException.ThrowIfNull(checkpoint);
        ArgumentNullException.ThrowIfNull(current);

        if (checkpoint.VolumeSerialNumber != current.VolumeSerialNumber)
        {
            return new(
                UsnCheckpointDecisionKind.FullScanVolumeChanged,
                "The source volume identity changed.");
        }

        if (checkpoint.JournalId != current.JournalId)
        {
            return new(
                UsnCheckpointDecisionKind.FullScanJournalChanged,
                "The USN journal identity changed.");
        }

        if (checkpoint.NextUsn < current.FirstUsn)
        {
            return new(
                UsnCheckpointDecisionKind.FullScanJournalGap,
                "The saved checkpoint is older than the first readable USN record.");
        }

        if (checkpoint.NextUsn > current.NextUsn)
        {
            return new(
                UsnCheckpointDecisionKind.FullScanCheckpointAhead,
                "The saved checkpoint is ahead of the current journal.");
        }

        return new(
            UsnCheckpointDecisionKind.Incremental,
            "The saved checkpoint is inside the readable USN range.");
    }
}

