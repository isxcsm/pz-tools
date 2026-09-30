using System.Text.Json;

namespace PzTools.App.Core;

public enum SaveVersionBasis { RunningGame, LastSeen, LatestBackup }

/// <summary>Which game version a save belongs to, and where that knowledge comes from.</summary>
public sealed record SaveGameVersion(string Version, SaveVersionBasis Basis, DateTimeOffset? AsOfUtc = null);

/// <summary>
/// A save records no game version of its own (only an internal world format number that several builds
/// share). The only reliable source is the running game while it has the save loaded, so the app remembers
/// the last version it saw each save loaded with, in <c>save-versions.json</c> under the app data folder.
/// </summary>
public sealed class SaveGameVersionMemory(string runtimeRoot)
{
    private const int MaximumEntries = 200;
    private readonly string path = Path.Combine(runtimeRoot, "save-versions.json");
    private readonly Lock gate = new();
    private Dictionary<string, Entry>? entries;

    private sealed record Entry(string Version, DateTimeOffset SeenUtc);

    /// <summary>Records the version a running game has this save loaded with. Written only when it changes.</summary>
    public void Remember(string savePath, string version, DateTimeOffset seenUtc)
    {
        var key = Key(savePath);
        version = version.Trim();
        if (version.Length is 0 or > 80 || version.Any(char.IsControl)) return;
        lock (gate)
        {
            var map = Load();
            if (map.TryGetValue(key, out var known) && known.Version == version) return;
            map[key] = new(version, seenUtc);
            // Saves that have not been seen for longest go first.
            foreach (var stale in map.OrderBy(item => item.Value.SeenUtc).Take(Math.Max(0, map.Count - MaximumEntries))
                         .Select(item => item.Key).ToArray())
                map.Remove(stale);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var temporary = path + ".tmp";
                File.WriteAllText(temporary, JsonSerializer.Serialize(map));
                File.Move(temporary, path, overwrite: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // A display aid only: the next change tries again.
            }
        }
    }

    public SaveGameVersion? Recall(string savePath)
    {
        lock (gate)
            return Load().TryGetValue(Key(savePath), out var entry)
                ? new(entry.Version, SaveVersionBasis.LastSeen, entry.SeenUtc) : null;
    }

    private Dictionary<string, Entry> Load()
    {
        if (entries is not null) return entries;
        try
        {
            entries = File.Exists(path)
                ? JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(path)) ?? []
                : [];
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            entries = [];
        }
        entries = new(entries, StringComparer.OrdinalIgnoreCase);
        return entries;
    }

    private static string Key(string savePath) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(savePath));
}
