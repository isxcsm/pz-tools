using System.Diagnostics;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class ApplicationInstanceLeaseTests
{
    [Fact]
    public void SameDataRootRejectsDuplicateRegardlessOfPathSpelling()
    {
        using var temp = new TempDirectory();
        using (var first = ApplicationInstanceLease.TryAcquire(temp.Path))
        {
            Assert.NotNull(first);
            using var duplicate = ApplicationInstanceLease.TryAcquire(Path.Combine(temp.Path, ".").ToUpperInvariant());
            Assert.Null(duplicate);
            using var independent = ApplicationInstanceLease.TryAcquire(temp.GetPath("other"));
            Assert.NotNull(independent);
        }
        using var next = ApplicationInstanceLease.TryAcquire(temp.Path);
        Assert.NotNull(next);
    }

    [Fact]
    public async Task ConcurrentStartsHaveExactlyOneWinner()
    {
        using var temp = new TempDirectory();
        var attempts = await Task.WhenAll(Enumerable.Range(0, 16)
            .Select(_ => Task.Run(() => ApplicationInstanceLease.TryAcquire(temp.Path))));
        try { Assert.Single(attempts, lease => lease is not null); }
        finally { foreach (var lease in attempts) lease?.Dispose(); }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AnotherProcessIsBlockedAndExitReleasesMarker(bool kill)
    {
        using var temp = new TempDirectory();
        using var first = StartFixture(temp.Path);
        try
        {
            Assert.Equal("ACQUIRED", await first.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30)));
            using (var second = StartFixture(temp.Path))
            {
                try
                {
                    Assert.Equal("REJECTED", await second.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30)));
                    await second.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
                    Assert.Equal(0, second.ExitCode);
                }
                finally { await StopFixtureAsync(second); }
            }
            if (kill) first.Kill(entireProcessTree: true);
            else await first.StandardInput.WriteLineAsync("exit");
            await first.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
            using var reopened = ApplicationInstanceLease.TryAcquire(temp.Path);
            Assert.NotNull(reopened);
        }
        finally { await StopFixtureAsync(first); }
    }

    private static System.Diagnostics.Process StartFixture(string root)
    {
        var info = new ProcessStartInfo("dotnet")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        foreach (var argument in new[] { "exec", "--runtimeconfig",
                     Path.Combine(AppContext.BaseDirectory, "PzTools.Backup.Tests.runtimeconfig.json"),
                     "--depsfile", Path.Combine(AppContext.BaseDirectory, "PzTools.Backup.Tests.deps.json"),
                     Path.Combine(AppContext.BaseDirectory, "PzTools.CrashFixture.dll"), root, "app-instance" })
            info.ArgumentList.Add(argument);
        return System.Diagnostics.Process.Start(info)!;
    }

    private static async Task StopFixtureAsync(System.Diagnostics.Process process)
    {
        if (!process.HasExited) process.Kill(entireProcessTree: true);
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
    }
}
