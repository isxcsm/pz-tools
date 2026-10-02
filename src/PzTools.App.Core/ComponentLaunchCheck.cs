using PzTools.Process.Hosting;

namespace PzTools.App.Core;

/// <summary>Executables Windows currently refuses to start, by file name. Empty when nothing is blocked.</summary>
public sealed record BlockedComponentsView(IReadOnlyList<string> Components)
{
    public static IEqualityComparer<BlockedComponentsView> Comparer { get; } =
        PzTools.Projections.ViewComparers.ListView<BlockedComponentsView, string>(x => x.Components);
}

/// <summary>
/// Windows application-control features judge each executable separately and can change their mind
/// between days. Starting every worker once with a no-op argument finds a blocked one when the app
/// starts, instead of when an automatic backup silently fails to launch mid-session.
/// </summary>
public sealed class ComponentLaunchCheck(IManagedProcessLauncher launcher)
{
    public static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(15);

    public async Task<IReadOnlyList<string>> FindBlockedAsync(string workerDirectory, CancellationToken cancellationToken)
    {
        var probes = AppWorkerDirectoryResolver.RequiredExecutables
            .Select(name => (Path: Path.Combine(workerDirectory, name), Arguments: (IReadOnlyList<string>)["--probe"]))
            // The bundled runtime that attaches to the game is a separate executable with its own verdict.
            .Append((Path: Path.Combine(workerDirectory, "save-bridge", "runtime", "bin", "java.exe"), Arguments: (IReadOnlyList<string>)["-version"]))
            .Where(probe => File.Exists(probe.Path)).ToArray();
        var results = await Task.WhenAll(probes.Select(async probe =>
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(ProbeTimeout);
            try
            {
                var exit = await launcher.RunAsync(probe.Path, probe.Arguments, null, null, timeout.Token).ConfigureAwait(false);
                return !exit.Started && exit.FailureCode == LaunchFailure.Blocked ? Path.GetFileName(probe.Path) : null;
            }
            // A slow or otherwise failing probe is not evidence of a policy block.
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return null; }
        })).ConfigureAwait(false);
        return results.OfType<string>().Order(StringComparer.OrdinalIgnoreCase).ToArray();
    }
}
