using System.ComponentModel;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record CheckpointBoundaryResult(
    SourceCheckpoint? Checkpoint,
    string? FallbackReason);

public interface ICheckpointBoundaryProvider
{
    CheckpointBoundaryResult Capture(string sourcePath);
}

public sealed class WindowsCheckpointBoundaryProvider(IUsnJournalSource reader)
    : ICheckpointBoundaryProvider
{
    public CheckpointBoundaryResult Capture(string sourcePath)
    {
        try
        {
            var state = reader.Query(sourcePath);
            return new CheckpointBoundaryResult(
                new SourceCheckpoint(
                    state.VolumeSerialNumber.ToString("X16"),
                    state.JournalId.ToString("X16"),
                    state.NextUsn),
                FallbackReason: null);
        }
        // No checkpoint only means the next backup scans in full; any answer of the volume is no reason to fail.
        catch (Win32Exception exception)
        {
            return new CheckpointBoundaryResult(
                Checkpoint: null,
                $"USN unavailable ({exception.NativeErrorCode}: {exception.Message})");
        }
        catch (InvalidDataException exception)
        {
            return new CheckpointBoundaryResult(Checkpoint: null, $"USN unavailable ({exception.Message})");
        }
    }
}
