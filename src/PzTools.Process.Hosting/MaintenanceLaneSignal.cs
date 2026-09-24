namespace PzTools.Process.Hosting;

/// <summary>각 점검 레인은 별도 프로세스와 뮤텍스를 사용합니다.</summary>
public static class MaintenanceLaneSignal
{
    public static readonly string[] HeavyLanes =
        ["RevisionReclamation", "ArtifactCleanup", "OrphanBackups"];

    public static string MutexName(string repositoryPath, string lane) =>
        NamedMutexRunner.CreateName($"MaintenanceLane.{lane}", Path.GetFullPath(repositoryPath));

    private static string YieldName(string repositoryPath, string lane) =>
        NamedMutexRunner.CreateName($"MaintenanceLaneYield.{lane}", Path.GetFullPath(repositoryPath));

    public static async Task<bool> IsRunningAsync(
        string repositoryPath, string lane, CancellationToken cancellationToken = default)
    {
        var probe = await NamedMutexRunner.TryRunAsync(
            MutexName(repositoryPath, lane), _ => Task.FromResult(true), cancellationToken);
        return !probe.Acquired;
    }

    public static async Task RequestYieldForRunningLanesAsync(
        string repositoryPath, CancellationToken cancellationToken = default)
    {
        foreach (var lane in HeavyLanes)
        {
            if (!await IsRunningAsync(repositoryPath, lane, cancellationToken)) continue;
            using var signal = new EventWaitHandle(
                false, EventResetMode.AutoReset, YieldName(repositoryPath, lane));
            signal.Set();
        }
    }

    public static IDisposable WatchForYield(
        string repositoryPath, string lane, CancellationTokenSource cancellation)
    {
        ArgumentNullException.ThrowIfNull(cancellation);
        var signal = new EventWaitHandle(
            false, EventResetMode.AutoReset, YieldName(repositoryPath, lane));
        var registration = ThreadPool.RegisterWaitForSingleObject(
            signal,
            (_, timedOut) =>
            {
                if (timedOut) return;
                try { cancellation.Cancel(); }
                catch (ObjectDisposedException) { }
            },
            null, Timeout.Infinite, executeOnlyOnce: true);
        return new YieldWatch(signal, registration);
    }

    private sealed class YieldWatch(
        EventWaitHandle signal, RegisteredWaitHandle registration) : IDisposable
    {
        public void Dispose()
        {
            registration.Unregister(null);
            signal.Dispose();
        }
    }
}
