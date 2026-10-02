using System.Text.Json;
using PzTools.Profiling;

namespace PzTools.App.Core;

/// <summary>
/// What each recording is, read once: by file name, and only while its size and time are the ones read, so a file
/// replaced under the same name is read again. A lost or damaged index only means reading the recordings again.
/// </summary>
internal sealed class ProfileSummaryIndex
{
    private readonly object gate = new();
    private readonly Dictionary<string, Entry> entries;

    private sealed record Entry(long Bytes, long WriteTicks, bool Rolling, bool Detailed, long DurationMicros);

    private ProfileSummaryIndex(Dictionary<string, Entry> entries) => this.entries = entries;

    public static ProfileSummaryIndex Load(string path)
    {
        try
        {
            if (File.Exists(path) && JsonSerializer.Deserialize<Dictionary<string, Entry>>(File.ReadAllText(path)) is { } stored)
                return new(new Dictionary<string, Entry>(stored, StringComparer.OrdinalIgnoreCase));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { }
        return new(new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase));
    }

    public ProfileRecordingSummary? Find(FileInfo file)
    {
        lock (gate)
        {
            return entries.TryGetValue(file.Name, out var entry) && entry.Bytes == file.Length
                && entry.WriteTicks == file.LastWriteTimeUtc.Ticks
                ? new ProfileRecordingSummary(entry.Rolling, entry.Detailed, entry.DurationMicros) : null;
        }
    }

    public void Set(FileInfo file, ProfileRecordingSummary summary)
    {
        lock (gate)
            entries[file.Name] = new(file.Length, file.LastWriteTimeUtc.Ticks, summary.Rolling, summary.Detailed, summary.DurationMicros);
    }

    /// <summary>Forgets a recording, as one renamed is known by its new name now.</summary>
    public void Remove(string fileName)
    {
        lock (gate) entries.Remove(fileName);
    }

    // One writer at a time: the summaries read in the background and a rename on the page both save.
    private readonly object saveGate = new();

    /// <summary>Writes the index, without the recordings no longer in <paramref name="directory"/>.</summary>
    public void Save(string path, string? directory = null)
    {
        lock (saveGate)
        {
            string json;
            lock (gate)
            {
                if (directory is not null)
                    foreach (var name in entries.Keys.ToArray())
                        if (!File.Exists(Path.Combine(directory, name))) entries.Remove(name);
                json = JsonSerializer.Serialize(entries);
            }
            var staged = $"{path}.{Environment.ProcessId}.tmp";
            try
            {
                File.WriteAllText(staged, json);
                File.Move(staged, path, overwrite: true);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                try { File.Delete(staged); } catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
            }
        }
    }
}
