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
            await session.EmitAsync(
                new TelemetryEvent(TelemetryEventScope.Raw, "operation.heartbeat"),
                cancellationToken).ConfigureAwait(false);
        }
    }
}
