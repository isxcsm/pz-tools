using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Engine;

internal sealed class TelemetryHeartbeat : IAsyncDisposable
{
    private readonly CancellationTokenSource cancellation = new();
    private readonly Task loop;

    private TelemetryHeartbeat(TelemetryRunSession session, TimeSpan interval)
    {
        loop = RunAsync(session, interval, cancellation.Token);
    }

    public static TelemetryHeartbeat Start(
        TelemetryRunSession session,
        TimeSpan? interval = null) =>
        new(session, interval ?? TimeSpan.FromSeconds(2));

    public async ValueTask DisposeAsync()
    {
        cancellation.Cancel();
        try { await loop.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        cancellation.Dispose();
    }

    private static async Task RunAsync(
        TelemetryRunSession session,
        TimeSpan interval,
        CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(interval);
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
        {
            // The run's liveness, not a detail: kept at every recording level. As a raw event it was dropped at
            // the default (phase), and a phase that reported no progress for ten seconds read as a stalled worker.
            await session.EmitAsync(
                new TelemetryEvent(TelemetryEventScope.Run, "operation.heartbeat"),
                cancellationToken).ConfigureAwait(false);
        }
    }
}
