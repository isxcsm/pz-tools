using System.Diagnostics;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class TelemetryFlushWindowTests
{
    [Fact]
    public async Task ContinuousArrivalsDoNotPostponeTheFlushWindow()
    {
        using var temp = new TempDirectory();
        var store = await TelemetryStore.CreateOrOpenAsync(temp.Path);
        await using var session = await store.BeginRunAsync(1, 1, DateTimeOffset.UtcNow,
            new TelemetryOptions(TelemetryMode.Phase, 4096, 250, 10, 32));
        using var stop = new CancellationTokenSource();
        var producer = Task.Run(async () =>
        {
            try
            {
                while (!stop.IsCancellationRequested)
                {
                    await session.EmitAsync(new TelemetryEvent(TelemetryEventScope.Phase, "progress.snapshot", "{}"), stop.Token);
                    await Task.Delay(10, stop.Token);
                }
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        });
        try
        {
            var elapsed = Stopwatch.StartNew();
            while ((await store.ReadEventsAfterAsync(0)).Count == 0 && elapsed.Elapsed < TimeSpan.FromSeconds(3))
                await Task.Delay(25);
            Assert.NotEmpty(await store.ReadEventsAfterAsync(0));
            Assert.False(producer.IsCompleted);
        }
        finally
        {
            await stop.CancelAsync();
            await producer;
            await session.CompleteAsync(RunStatus.Succeeded);
        }
    }
}
