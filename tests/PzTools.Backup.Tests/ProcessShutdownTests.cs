using System.Diagnostics;
using PzTools.App.Core;
using Xunit.Abstractions;

namespace PzTools.Backup.Tests;

public sealed class ProcessShutdownTests(ITestOutputHelper output)
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task WindowlessProcess_CancellationTerminatesTheProcessTree(bool withChild)
    {
        using var cancellation = new CancellationTokenSource();
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var childId = 0;
        var command = withChild
            ? "$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe')); "
                + "$start.UseShellExecute = $false; $start.CreateNoWindow = $true; "
                + "$start.Arguments = '-NoProfile -NonInteractive -Command \"Start-Sleep -Seconds 30\"'; "
                + "$child = [Diagnostics.Process]::Start($start); [Console]::WriteLine($child.Id); "
                + "[Console]::WriteLine('ready'); Start-Sleep -Seconds 30"
            : "[Console]::WriteLine('ready'); Start-Sleep -Seconds 30";
        var running = new ManagedProcessLauncher().RunAsync(
            Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            ["-NoProfile", "-NonInteractive", "-Command", command],
            line =>
            {
                if (line == "ready") ready.TrySetResult();
                else if (int.TryParse(line, out var pid)) childId = pid;
            }, null, cancellation.Token);
        try
        {
            await ready.Task.WaitAsync(TimeSpan.FromSeconds(15));
            using var child = withChild ? System.Diagnostics.Process.GetProcessById(childId) : null;
            var timer = Stopwatch.StartNew();
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => running.WaitAsync(TimeSpan.FromSeconds(10)));
            output.WriteLine($"Cancellation and process cleanup: {timer.ElapsedMilliseconds} ms");
            // Assert termination, not sub-two-second performance on a shared CI machine.
            if (child is not null)
                await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally
        {
            cancellation.Cancel();
            try { await running; }
            catch (OperationCanceledException) { }
        }
    }

    [Fact]
    public async Task AlreadyCancelled_DoesNotLaunchAProcess()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new ManagedProcessLauncher().RunAsync(
            "missing.exe", [], null, null, cancellation.Token));
    }

    [Fact]
    public async Task ExitedParentDoesNotWaitForDescendantsHoldingOutputPipes()
    {
        var childId = 0;
        var command = "$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe')); "
            + "$start.UseShellExecute = $false; $start.CreateNoWindow = $true; "
            + "$start.Arguments = '-NoProfile -NonInteractive -Command \"Start-Sleep -Seconds 30\"'; "
            + "$child = [Diagnostics.Process]::Start($start); [Console]::WriteLine($child.Id)";
        try
        {
            var result = await new ManagedProcessLauncher().RunAsync(
                Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                ["-NoProfile", "-NonInteractive", "-Command", command],
                line => { if (int.TryParse(line, out var id)) childId = id; }, null, CancellationToken.None)
                .WaitAsync(TimeSpan.FromSeconds(10));
            Assert.True(result.Started);
            Assert.Equal(0, result.ExitCode);
            Assert.True(childId > 0);
            try
            {
                using var child = System.Diagnostics.Process.GetProcessById(childId);
                await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
            }
            catch (ArgumentException) { /* The child has already exited and been reaped. */ }
        }
        finally
        {
            if (childId > 0)
            {
                try
                {
                    using var child = System.Diagnostics.Process.GetProcessById(childId);
                    if (!child.HasExited) child.Kill(entireProcessTree: true);
                }
                catch (ArgumentException) { }
            }
        }
    }
}
