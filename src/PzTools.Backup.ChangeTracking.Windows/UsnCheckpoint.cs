namespace PzTools.Backup.ChangeTracking.Windows;

public sealed record UsnCheckpoint(
    ulong VolumeSerialNumber,
    ulong JournalId,
    long NextUsn);

public sealed record UsnJournalState(
    ulong VolumeSerialNumber,
    ulong JournalId,
    long FirstUsn,
    long NextUsn,
    long LowestValidUsn);

public enum UsnCheckpointDecisionKind
{
    Incremental,
    FullScanVolumeChanged,
    FullScanJournalChanged,
    FullScanJournalGap,
    FullScanCheckpointAhead,
}

public sealed record UsnCheckpointDecision(
    UsnCheckpointDecisionKind Kind,
    string Reason)
{
    public bool CanReadIncrementally => Kind == UsnCheckpointDecisionKind.Incremental;
}

