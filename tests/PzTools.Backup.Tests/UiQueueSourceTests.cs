using System.Text.RegularExpressions;

namespace PzTools.Backup.Tests;

/// <summary>
/// A failure in a raw DispatcherQueue callback ends the app without reaching Application.UnhandledException, so without
/// a crash report. The app queues UI work only through UiQueue, which passes such a failure on to that handler.
/// </summary>
public sealed class UiQueueSourceTests
{
    [Fact]
    public void TheAppQueuesUiWorkOnlyThroughUiQueue()
    {
        var root = Path.Combine(RepositoryRoot(), "src", "PzTools.App");
        var raw = new Regex(@"\.TryEnqueue\(|\.CreateTimer\(");
        var offenders = Directory.EnumerateFiles(root, "*.cs", SearchOption.AllDirectories)
            .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                && !path.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")
                && Path.GetFileName(path) != "UiQueue.cs")
            .SelectMany(path => File.ReadLines(path).Select((line, index) => (path, line, index)))
            .Where(item => raw.IsMatch(item.line))
            .Select(item => $"{Path.GetRelativePath(root, item.path)}:{item.index + 1}")
            .ToList();
        Assert.Empty(offenders);
    }

    private static string RepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln"))) return directory.FullName;
        throw new DirectoryNotFoundException("Repository source is required for the UI queue contract.");
    }
}
