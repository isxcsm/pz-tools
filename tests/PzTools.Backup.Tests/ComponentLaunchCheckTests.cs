using System.ComponentModel;
using PzTools.App.Core;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class ComponentLaunchCheckTests
{
    [Theory]
    [InlineData(4551, LaunchFailure.Blocked)] // An Application Control policy has blocked this file.
    [InlineData(1260, LaunchFailure.Blocked)] // Blocked by group policy.
    [InlineData(225, LaunchFailure.Blocked)]  // Blocked as unwanted software.
    [InlineData(2, LaunchFailure.Failed)]     // File not found is a broken install, not a policy decision.
    [InlineData(5, LaunchFailure.Failed)]
    public void OnlyPolicyRefusalsAreReportedAsBlocked(int nativeError, string expected) =>
        Assert.Equal(expected, LaunchFailure.Classify(new Win32Exception(nativeError)));

    [Fact]
    public void BlockedLaunchMapsToItsOwnUserMessage()
    {
        Assert.Equal("OperationError.BlockedByPolicy",
            UserFacingErrorCatalog.FromProcessError($"{LaunchFailure.Blocked}: An Application Control policy has blocked this file."));
        Assert.Equal(UserFacingErrorCatalog.Generic, UserFacingErrorCatalog.FromProcessError(LaunchFailure.Failed));
    }

    [Fact]
    public async Task FindsExactlyTheComponentsWindowsRefusesToStart()
    {
        using var temp = new TempDirectory();
        var workers = temp.GetPath("workers");
        Directory.CreateDirectory(workers);
        foreach (var name in AppWorkerDirectoryResolver.RequiredExecutables)
            await File.WriteAllTextAsync(Path.Combine(workers, name), "");
        var launcher = new Launcher(executable => Path.GetFileName(executable) switch
        {
            "PzTools.Backup.Cli.exe" => new(false, null, LaunchFailure.Blocked),
            "PzTools.State.Runner.exe" => new(false, null, LaunchFailure.Failed), // Broken, but not blocked.
            "PzTools.Maintenance.Cli.exe" => new(true, 64, "child-failed"),       // Started: allowed.
            _ => new(true, 0, null),
        });

        var blocked = await new ComponentLaunchCheck(launcher).FindBlockedAsync(workers, CancellationToken.None);

        Assert.Equal(["PzTools.Backup.Cli.exe"], blocked);
        // Every worker is asked to do nothing; the bundled Java runtime is absent here and is skipped.
        Assert.Equal(AppWorkerDirectoryResolver.RequiredExecutables.Count, launcher.Calls.Count);
        Assert.All(launcher.Calls, call => Assert.Equal(["--probe"], call.Arguments));
    }

    private sealed class Launcher(Func<string, ManagedProcessExit> result) : IManagedProcessLauncher
    {
        public System.Collections.Concurrent.ConcurrentBag<(string Executable, IReadOnlyList<string> Arguments)> Calls { get; } = [];

        public Task<ManagedProcessExit> RunAsync(string executable, IReadOnlyList<string> arguments,
            Action<string>? standardOutput, Action<string>? standardError, CancellationToken cancellationToken)
        {
            Calls.Add((executable, arguments));
            return Task.FromResult(result(executable));
        }
    }
}
