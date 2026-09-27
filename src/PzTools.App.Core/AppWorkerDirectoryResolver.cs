namespace PzTools.App.Core;

public static class AppWorkerDirectoryResolver
{
    private static readonly string[] RequiredExecutables =
    [
        "PzTools.Backup.Scheduler.exe",
        "PzTools.State.Scheduler.exe",
        "PzTools.Backup.Runner.exe",
        "PzTools.Maintenance.Runner.exe",
        "PzTools.State.Runner.exe",
        "PzTools.Zomboid.Archive.Cli.exe",
        "PzTools.Backup.Cli.exe",
        "PzTools.Maintenance.Cli.exe",
        "PzTools.State.Collector.Cli.exe",
        "PzTools.State.Reactor.Cli.exe",
        "PzTools.Zomboid.Recovery.Cli.exe",
    ];

    public static string Resolve(string startingDirectory, string? explicitDirectory = null)
    {
        var start = Path.GetFullPath(startingDirectory);
        if (!string.IsNullOrWhiteSpace(explicitDirectory))
        {
            var explicitPath = Path.GetFullPath(explicitDirectory);
            if (ContainsRequiredTools(explicitPath)) return explicitPath;
            throw new DirectoryNotFoundException($"The configured worker directory is incomplete: {explicitPath}");
        }
        var bundled = Path.Combine(start, "workers");
        if (ContainsRequiredTools(bundled)) return bundled;
        if (ContainsRequiredTools(start)) return start;
        throw new DirectoryNotFoundException($"Application workers are missing. Rebuild or reinstall the complete application: {start}");
    }

    public static bool ContainsRequiredTools(string directory) =>
        Directory.Exists(directory)
        && RequiredExecutables.All(name => File.Exists(Path.Combine(directory, name)));
}
