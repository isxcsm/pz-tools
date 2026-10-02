using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class ProcessStopSignalTests
{
    [Fact]
    public async Task AStopRequestCancelsAListeningProcess_AndIsRefusedWhereNobodyListens()
    {
        using var cancellation = new CancellationTokenSource();
        Assert.False(ProcessStopSignal.TryRequest(Environment.ProcessId)); // Not listening yet: the parent would end it.

        using (ProcessStopSignal.Listen(cancellation))
        {
            Assert.True(ProcessStopSignal.TryRequest(Environment.ProcessId));
            await Task.Delay(Timeout.Infinite, cancellation.Token).ContinueWith(_ => { });
            Assert.True(cancellation.IsCancellationRequested);
        }

        // Once the listener is gone the event is too, so a later process with the same id is not stopped by it.
        Assert.False(ProcessStopSignal.TryRequest(Environment.ProcessId));
    }
}
