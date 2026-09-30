using PzTools.App.Core;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class AppStartupSafetyTests
{
    [Fact]
    public void CrashReport_RecordsTheExceptionAndWhereItCameFrom()
    {
        using var temp = new TempDirectory();
        Exception thrown;
        try { throw new InvalidOperationException("outer", new IOException("inner cause")); }
        catch (Exception exception) { thrown = exception; }

        var path = CrashReport.TryWrite(temp.GetPath("crash"), "ui-thread", thrown, DateTimeOffset.UtcNow);

        Assert.NotNull(path);
        var text = File.ReadAllText(path);
        Assert.Contains("Origin: ui-thread", text);
        Assert.Contains("InvalidOperationException: outer", text);
        Assert.Contains("IOException: inner cause", text);
        Assert.Contains(nameof(CrashReport_RecordsTheExceptionAndWhereItCameFrom), text); // Stack trace.
    }

    [Fact]
    public void CrashReport_KeepsOnlyTheNewestReports_AndNeverThrows()
    {
        using var temp = new TempDirectory();
        var directory = temp.GetPath("crash");
        var start = new DateTimeOffset(2026, 9, 30, 0, 0, 0, TimeSpan.Zero);
        for (var index = 0; index < CrashReport.RetainedReports + 5; index++)
            Assert.NotNull(CrashReport.TryWrite(directory, "test", null, start.AddSeconds(index)));

        var files = Directory.GetFiles(directory, "crash-*.txt").Select(Path.GetFileName).Order().ToArray();
        Assert.Equal(CrashReport.RetainedReports, files.Length);
        Assert.Equal("crash-20260930-000005-000.txt", files[0]); // The five oldest are gone.

        // A location that cannot be a directory must not turn one failure into two.
        var blocker = temp.GetPath("not-a-directory");
        File.WriteAllText(blocker, "");
        Assert.Null(CrashReport.TryWrite(blocker, "test", new IOException(), start));
    }

    [Fact]
    public async Task SecondLaunch_AsksTheRunningInstanceToShowItself()
    {
        using var temp = new TempDirectory();
        Assert.False(ApplicationActivationSignal.TrySignal(temp.Path)); // Nothing is running yet.

        var activated = new SemaphoreSlim(0);
        using (ApplicationActivationSignal.Listen(temp.Path, () => activated.Release()))
        {
            Assert.True(ApplicationActivationSignal.TrySignal(temp.Path));
            Assert.True(await activated.WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.True(ApplicationActivationSignal.TrySignal(temp.Path)); // Works more than once.
            Assert.True(await activated.WaitAsync(TimeSpan.FromSeconds(5)));
            // Another data root is another app instance.
            Assert.False(ApplicationActivationSignal.TrySignal(temp.GetPath("other")));
        }

        Assert.False(ApplicationActivationSignal.TrySignal(temp.Path)); // The instance has closed.
    }
}
