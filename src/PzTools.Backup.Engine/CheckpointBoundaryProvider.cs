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
        catch (Win32Exception exception) when (exception.NativeErrorCode is 1 or 5 or 50 or 1179)
        {
            return new CheckpointBoundaryResult(
                Checkpoint: null,
                $"USN unavailable ({exception.NativeErrorCode}: {exception.Message})");
        }
    }
}
