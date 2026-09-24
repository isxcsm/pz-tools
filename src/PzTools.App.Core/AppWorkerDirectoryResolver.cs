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
    ];

    public static string Resolve(string startingDirectory, string? explicitDirectory = null)
    {
        var start = Path.GetFullPath(startingDirectory);
        if (!string.IsNullOrWhiteSpace(explicitDirectory))
        {
            var explicitPath = Path.GetFullPath(explicitDirectory);
            if (ContainsRequiredTools(explicitPath)) return explicitPath;
        }
        if (ContainsRequiredTools(start)) return start;

        for (var current = new DirectoryInfo(start); current is not null; current = current.Parent)
        {
            var published = Path.Combine(current.FullName, "artifacts", "app");
            if (ContainsRequiredTools(published)) return published;
        }
        return start;
    }

    public static bool ContainsRequiredTools(string directory) =>
        Directory.Exists(directory)
        && RequiredExecutables.All(name => File.Exists(Path.Combine(directory, name)));
}
