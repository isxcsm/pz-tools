using System.Text.RegularExpressions;

namespace PzTools.Backup.Tests;

/// <summary>
/// The game shows a note only by a key of its own list; a key the app sends that the list lacks is refused, and the
/// player hears the sound with nothing over the character. Every key the hotkeys send must be in the list.
/// </summary>
public sealed partial class GameNoticeCatalogTests
{
    [Fact]
    public void EveryNoteTheHotkeysSend_IsInTheGamesList()
    {
        var root = RepositoryRoot();
        var catalog = File.ReadLines(Path.Combine(root, "src", "PzTools.GameBridge.Agent", "notices.tsv")).Skip(1)
            .Select(line => line.Split('\t')[0]).Where(key => key.Length > 0).ToHashSet();
        var sent = new HashSet<string>();
        foreach (var line in File.ReadLines(Path.Combine(root, "src", "PzTools.App", "HotKeyController.cs")))
        {
            if (!line.Contains("Note(", StringComparison.Ordinal) && !line.Contains("NotifyGameAsync", StringComparison.Ordinal)
                && !line.Contains("items.Add(", StringComparison.Ordinal)) continue;
            foreach (Match match in NoteKey().Matches(line)) sent.Add(match.Groups[1].Value);
        }
        // The keys the hotkeys are known to send, so the scan itself cannot quietly find nothing.
        Assert.Contains("next-recording-detailed", sent);
        Assert.Contains("saved-last", sent);
        Assert.Contains("busy", sent);
        Assert.Empty(sent.Except(catalog));
    }

    // A note's key in a string literal, alone ("busy") or with its number ($"saved-last:{minutes}").
    [GeneratedRegex("\"([a-z]+(?:-[a-z]+)*)(?=[\":])")]
    private static partial Regex NoteKey();

    private static string RepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "PzTools.sln"))) return directory.FullName;
        throw new DirectoryNotFoundException("The repository root was not found above the test binaries.");
    }
}
