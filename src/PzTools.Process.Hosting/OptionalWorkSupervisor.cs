namespace PzTools.Process.Hosting;

public static class OptionalWorkSupervisor
{
    /// <summary>
    /// Runs optional work beside required work in the same process. A failure is reported and the
    /// work is retried with a growing delay; only cancellation or normal completion ends the loop.
    /// </summary>
    public static async Task RunAsync(Func<CancellationToken, Task> work, Action reportFailure,
        CancellationToken token, Func<int, TimeSpan>? retryDelay = null)
    {
        ArgumentNullException.ThrowIfNull(work);
        ArgumentNullException.ThrowIfNull(reportFailure);
        retryDelay ??= failures => TimeSpan.FromSeconds(Math.Min(60, 5 << Math.Min(failures - 1, 4)));
        for (var failures = 1; !token.IsCancellationRequested; failures++)
        {
            try
            {
                await work(token);
                return;
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (Exception)
            {
                try { reportFailure(); } catch (Exception) { }
            }
            try { await Task.Delay(retryDelay(failures), token); }
            catch (OperationCanceledException) { return; }
        }
    }
}
