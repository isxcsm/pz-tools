using PzTools.Process.Contracts;
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

    [Fact]
    public async Task ARunnerAskedToStop_StopsItsWorker_AndReportsTheCancellation()
    {
        using var temp = new TempDirectory();
        using var cancellation = new CancellationTokenSource();
        var run = new OneShotRunnerCoordinator().RunAsync("runner", "audit", temp.Path, 7,
            Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 60"], "worker",
            cancellationToken: cancellation.Token);
        await Task.Delay(500);
        cancellation.Cancel();
        // The worker is ended once its grace is over; the runner then has an outcome to give, not an exception.
        var result = await run.WaitAsync(TimeSpan.FromSeconds(30));
        Assert.Equal(ProcessOutcome.Cancelled, result.Outcome);
        Assert.Equal(7, result.RunIndex);
        Assert.Equal("cancelled", result.Error?.Code);
        Assert.Equal(ProcessExitCodes.Cancelled, ProcessExitCodes.FromOutcome(result.Outcome));
    }

    /// <summary>
    /// A runner that does not listen is ended at once when its work is cancelled, and its worker with it: nothing then
    /// records the cancellation or closes the reserved workflow. Every runner and worker the app cancels listens.
    /// </summary>
    [Theory]
    [InlineData("PzTools.Backup.Runner")]
    [InlineData("PzTools.Maintenance.Runner")]
    [InlineData("PzTools.State.Runner")]
    [InlineData("PzTools.Zomboid.Recovery.Cli")]
    public void CancellableProcesses_ListenForTheStopEvent(string project)
    {
        var program = File.ReadAllText(Path.Combine(RepositoryRoot(), "src", project, "Program.cs"));
        Assert.Contains("ProcessStopSignal.Listen(", program);
        Assert.Contains("cancellation.Token", program);
    }

    private static string RepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln"))) return directory.FullName;
        throw new DirectoryNotFoundException("Repository source is required for the stop-event contract.");
    }
}
