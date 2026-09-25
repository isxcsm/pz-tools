using PzTools.Zomboid.State;

namespace PzTools.Zomboid.Backup;

/// <summary>An obsolete automatic reservation is skipped, not an offline/manual backup.</summary>
public sealed class AutomaticBackupSkippedException(string reason)
    : OperationCanceledException(reason) { }

/// <summary>Checks automatic eligibility on both sides of game save/clock waits.</summary>
public sealed class BackupTimingPreparation(
    Func<string, CancellationToken, Task<GameSaveResult>> prepareGameSave,
    Func<string, ActivityState>? activityProbe = null,
    TimeProvider? timeProvider = null,
    Func<TimeSpan, CancellationToken, Task>? delay = null)
{
    public async Task<GameSaveResult> PrepareAsync(
        string sourcePath, DateTimeOffset? scheduledUtc, bool requireActiveGame,
        CancellationToken cancellationToken = default)
    {
        CheckActivity();
        var result = await prepareGameSave(sourcePath, cancellationToken);
        if (requireActiveGame && result.Outcome is "not-in-world" or "game-not-running" or "save-mismatch")
            throw new AutomaticBackupSkippedException(result.Outcome);
        if (scheduledUtc is { } due)
        {
            var remaining = due - (timeProvider ?? TimeProvider.System).GetUtcNow();
            if (remaining > TimeSpan.Zero)
            {
                if (delay is not null) await delay(remaining, cancellationToken);
                else await Task.Delay(remaining, timeProvider ?? TimeProvider.System, cancellationToken);
            }
        }
        // Covers exit during the in-game countdown or during preparation with game saving disabled.
        CheckActivity();
        return result;

        void CheckActivity()
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (requireActiveGame && (activityProbe ?? AutomaticBackupActivity.Probe)(sourcePath) != ActivityState.Active)
                throw new AutomaticBackupSkippedException("The selected world is no longer confirmed active.");
        }
    }
}
