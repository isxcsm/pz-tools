using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class OptionalWorkSupervisorTests
{
    [Fact]
    public async Task UnexpectedFailure_IsReportedAndRetried_WithoutFaultingTheCaller()
    {
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var runs = 0; var reports = 0;
        var recovered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        var supervised = OptionalWorkSupervisor.RunAsync(async token =>
        {
            if (++runs < 3) throw new NullReferenceException("unexpected controller bug");
            recovered.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
        }, () => { reports++; throw new IOException("reporting must not matter either"); },
            stop.Token, _ => TimeSpan.Zero);

        await recovered.Task.WaitAsync(stop.Token);
        Assert.Equal(2, reports);
        await stop.CancelAsync();
        await supervised; // Cancellation is a normal end, not a fault.
        Assert.Equal(3, runs);
    }

    [Fact]
    public async Task NormalCompletion_EndsWithoutRetry()
    {
        var runs = 0;
        await OptionalWorkSupervisor.RunAsync(_ => { runs++; return Task.CompletedTask; }, () => { },
            CancellationToken.None, _ => TimeSpan.Zero);
        Assert.Equal(1, runs);
    }
}
