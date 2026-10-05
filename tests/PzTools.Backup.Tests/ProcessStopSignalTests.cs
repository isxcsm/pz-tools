using System.Diagnostics;
using PzTools.Backup.Storage.Repository;
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
    // The workers those runners pass the request on to.
    [InlineData("PzTools.Maintenance.Cli")]
    [InlineData("PzTools.State.Collector.Cli")]
    [InlineData("PzTools.State.Reactor.Cli")]
    public void CancellableProcesses_ListenForTheStopEvent(string project)
    {
        var program = File.ReadAllText(Path.Combine(RepositoryRoot(), "src", project, "Program.cs"));
        Assert.Contains("ProcessStopSignal.Listen(", program);
        Assert.Contains("cancellation.Token", program);
    }

    /// <summary>The state workers end a stop with an outcome of their own: Cancelled, with its exit code.</summary>
    [Theory]
    [InlineData("PzTools.Maintenance.Cli")]
    [InlineData("PzTools.State.Collector.Cli")]
    [InlineData("PzTools.State.Reactor.Cli")]
    public void StoppedWorkers_ReportTheCancellation(string project)
    {
        var program = File.ReadAllText(Path.Combine(RepositoryRoot(), "src", project, "Program.cs"));
        Assert.Contains("catch (OperationCanceledException) when (cancellation.IsCancellationRequested)", program);
        Assert.Contains("ProcessOutcome.Cancelled", program);
        Assert.Contains("return ProcessExitCodes.Cancelled;", program);
        // Running under the state runner's lock is no reason to ignore a stop.
        Assert.DoesNotContain("CancellationToken.None))", program);
    }

    /// <summary>
    /// A maintenance lane asked to stop while it waits for the repository's writer closes its workflow as cancelled,
    /// as a yield to a backup does, instead of leaving it running for the next recovery to find abandoned.
    /// </summary>
    [RequiresEnvironmentFact("PZTOOLS_TOOLS_DIR")]
    public async Task AMaintenanceLaneAskedToStop_ClosesItsWorkflowAsCancelled()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        long sourceId;
        await using (var seed = RepositoryWriterLease.Acquire(repository.RepositoryPath))
            sourceId = (await repository.AddOrGetSourceAsync(seed, "Sandbox/Save", temp.GetPath("save"))).SourceId;
        // While the writer is held, the lane waits for it: a moment at which it can be asked to stop.
        await using var held = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var start = new ProcessStartInfo(Path.Combine(Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!,
            "PzTools.Maintenance.Cli.exe")) { UseShellExecute = false, RedirectStandardOutput = true, CreateNoWindow = true };
        foreach (var argument in new[] { "--repository", repository.RepositoryPath, "--source-id",
            sourceId.ToString(System.Globalization.CultureInfo.InvariantCulture), "--lane", "ArtifactCleanup",
            "--control-db", temp.GetPath("control.db") })
            start.ArgumentList.Add(argument);
        using var lane = System.Diagnostics.Process.Start(start)!;
        var output = lane.StandardOutput.ReadToEndAsync();
        try
        {
            var give = DateTime.UtcNow.AddSeconds(30);
            while (await RunningLaneStageAsync(repository) is null)
            {
                if (lane.HasExited) Assert.Fail("The lane ended before it reserved its workflow: " + await output);
                Assert.True(DateTime.UtcNow < give, "The lane did not reserve its workflow.");
                await Task.Delay(50);
            }
            Assert.True(ProcessStopSignal.TryRequest(lane.Id));
            await lane.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
        }
        finally { if (!lane.HasExited) lane.Kill(entireProcessTree: true); }

        Assert.True(lane.ExitCode == ProcessExitCodes.Cancelled, await output);
        var result = ProcessResultJson.Deserialize<object>(await output);
        Assert.Equal(ProcessOutcome.Cancelled, result.Outcome);
        Assert.Equal(WorkflowStatus.Cancelled, (await repository.ReadWorkflowAsync(result.RunIndex)).Status);
        Assert.Null(await RunningLaneStageAsync(repository));
    }

    private static async Task<long?> RunningLaneStageAsync(RepositoryDatabase repository)
    {
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT run_index FROM workflow_stages WHERE producer='maintenance-lane-ArtifactCleanup' AND status='Running';";
        return await command.ExecuteScalarAsync() is long run ? run : null;
    }

    private static string RepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln"))) return directory.FullName;
        throw new DirectoryNotFoundException("Repository source is required for the stop-event contract.");
    }
}
