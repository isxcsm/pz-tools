namespace PzTools.Backup.Engine;

public enum BackupFailurePoint
{
    BeforePackFlush,
    AfterPackPromotion,
    BeforeRepositoryCommit,
    DuringRepositoryCommit,
    AfterRepositoryCommit,
}

public interface IBackupFailureInjector
{
    void ThrowIfRequested(BackupFailurePoint point);
}

public sealed class NoBackupFailureInjector : IBackupFailureInjector
{
    public static NoBackupFailureInjector Instance { get; } = new();

    private NoBackupFailureInjector()
    {
    }

    public void ThrowIfRequested(BackupFailurePoint point)
    {
    }
}

public sealed class SimulatedProcessCrashException(BackupFailurePoint point)
    : Exception($"Simulated process crash at {point}.")
{
    public BackupFailurePoint Point { get; } = point;
}
