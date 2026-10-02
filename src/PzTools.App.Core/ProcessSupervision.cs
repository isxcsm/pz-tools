using System.Diagnostics;
using PzTools.Process.Hosting;

namespace PzTools.App.Core;

// NativeErrorCode: why Windows would not start it, as its own number (5 is access denied).
public sealed record ManagedProcessExit(bool Started, int? ExitCode, string? FailureCode, int? NativeErrorCode = null);

public interface IManagedProcessLauncher
{
    Task<ManagedProcessExit> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        Action<string>? standardOutput,
        Action<string>? standardError,
        CancellationToken cancellationToken);
}

public sealed class ManagedProcessLauncher(int shutdownGraceMs = 2000) : IManagedProcessLauncher
{
    public async Task<ManagedProcessExit> RunAsync(
        string executable, IReadOnlyList<string> arguments,
        Action<string>? standardOutput, Action<string>? standardError,
        CancellationToken cancellationToken)
    {
        var result = await new ChildProcessHost().RunAsync(executable, arguments,
            cancellationToken, standardOutput, standardError, captureOutput: false, shutdownGraceMs: shutdownGraceMs).ConfigureAwait(false);
        if (!result.Started && !string.IsNullOrWhiteSpace(result.StandardError)) standardError?.Invoke(result.StandardError);
        return new(result.Started, result.ExitCode, result.FailureCode, result.NativeErrorCode);
    }
}

public enum SchedulerHostState { Stopped, Starting, Running, Restarting, Faulted }
public sealed record SchedulerHostStatus(
    string Name,
    SchedulerHostState State,
    int RestartCount,
    int? LastExitCode,
    string? Message);

public sealed record SchedulerHostView(IReadOnlyList<SchedulerHostStatus> Schedulers)
{
    public static IEqualityComparer<SchedulerHostView> Comparer { get; } =
        PzTools.Projections.ViewComparers.ListView<SchedulerHostView, SchedulerHostStatus>(x => x.Schedulers);
}
