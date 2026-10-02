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
    // A pass only has work when a save folder or the backup catalog changed: backups, deletions and
    // maintenance all move the catalog's change counter. Unchanged since the last pass, the next one
    // is skipped (it would start a process, reserve a workflow and scan the repository for nothing),
    // except once an hour so that time-based housekeeping still runs.
    private static readonly TimeSpan UnchangedRecheck = TimeSpan.FromHours(1);
    private DateTimeOffset nextDue = DateTimeOffset.MinValue;
    private string? lastStamp;
    private DateTimeOffset lastDispatch = DateTimeOffset.MinValue;
    private bool requested;

    /// <summary>
    /// Makes the next tick dispatch without waiting out the interval. Used when the game has just
    /// exited: many users close the app right after the game, before a periodic pass would come due.
    /// </summary>
    public void RequestNow() { nextDue = DateTimeOffset.MinValue; requested = true; }

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
            var stamp = await ReadStampAsync(cancellationToken);
            if (!requested && stamp is not null && stamp == lastStamp && now - lastDispatch < UnchangedRecheck) return;
            requested = false;
            lastStamp = stamp;
            lastDispatch = now;
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

    /// <summary>The saves present and the catalog's change counter; null when either cannot be read (then the pass runs).</summary>
    private async Task<string?> ReadStampAsync(CancellationToken cancellationToken)
    {
        try
        {
            if (!File.Exists(Path.Combine(repositoryPath,
                    PzTools.Backup.Storage.Repository.RepositoryDatabase.DatabaseFileName))) return null;
            var repository = await PzTools.Backup.Storage.Repository.RepositoryDatabase.OpenExistingAsync(repositoryPath, cancellationToken);
            var revision = await repository.ReadChangeRevisionAsync(cancellationToken);
            IEnumerable<string> saves = Directory.Exists(savesRoot)
                ? Directory.EnumerateDirectories(savesRoot)
                    .SelectMany(mode => Directory.EnumerateDirectories(mode))
                    .Select(save => save.ToUpperInvariant()).Order(StringComparer.Ordinal)
                : [];
            return revision.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + string.Join("|", saves);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return null;
        }
    }
}
