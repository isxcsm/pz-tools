using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;

namespace PzTools.Scheduling;

// Independent of automatic backups: a save may disappear when no backup target remains.
public sealed class OrphanCleanupDispatcher(
    string repositoryPath, string savesRoot, string workerDirectory, string? controlDatabasePath = null,
    int intervalSeconds = 60, Func<bool>? shouldDefer = null,
    Action<string, IReadOnlyList<string>, string>? startDetached = null)
{
    private DateTimeOffset nextDue = DateTimeOffset.MinValue;

    /// <summary>
    /// Makes the next tick dispatch without waiting out the interval. Used when the game has just
    /// exited: many users close the app right after the game, before a periodic pass would come due.
    /// </summary>
    public void RequestNow() => nextDue = DateTimeOffset.MinValue;

    public async Task TickAsync(DateTimeOffset now, CancellationToken cancellationToken = default)
    {
        if (now < nextDue) return;
        if (intervalSeconds is < 10 or > 86400) throw new ArgumentOutOfRangeException(nameof(intervalSeconds));
        nextDue = now.AddSeconds(intervalSeconds);
        cancellationToken.ThrowIfCancellationRequested();
        if ((shouldDefer ?? GameplayWorkGate.ShouldDeferMaintenance)()) return;
        try
        {
            if (await MaintenanceLaneSignal.IsRunningAsync(repositoryPath, "OrphanBackups", cancellationToken)) return;
            var arguments = new List<string>
            {
                "--repository", repositoryPath, "--saves-root", savesRoot, "--lane", "OrphanBackups",
            };
            if (controlDatabasePath is not null) arguments.AddRange(["--control-db", controlDatabasePath]);
            // Detached: the pass finishes on its own even if the app closes right after dispatching it.
            (startDetached ?? ((executable, launchArguments, directory) =>
                DetachedProcessLauncher.Start(executable, launchArguments, directory)))(
                Path.Combine(workerDirectory, "PzTools.Maintenance.Cli.exe"), arguments, workerDirectory);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            var run = await new RunIndexAllocator(controlDatabasePath).AllocateAsync(cancellationToken: cancellationToken);
            await BestEffortProcessTelemetry.TryRecordAsync(repositoryPath, "maintenance-worker", run,
                "maintenance.orphanbackups.failed", FailureTelemetry.FromException(
                    "orphan-cleanup-launch-failed", exception, operation: "maintenance"));
        }
    }
}
