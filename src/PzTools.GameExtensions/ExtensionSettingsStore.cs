using System.Text.Json;

namespace PzTools.GameExtensions;

/// <summary>Independent of backup configuration and WinUI. Failed reads never overwrite preferences.</summary>
public sealed class ExtensionSettingsStore
{
    private const int MaximumBytes = 64 * 1024;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    public string FilePath { get; }
    public ExtensionSettingsStore(string runtimeRoot) =>
        FilePath = Path.Combine(Path.GetFullPath(runtimeRoot), "extensions", "settings.json");

    public ExtensionConfiguration Read()
    {
        // File.Exists would hide access-denied as an empty default configuration.
        try
        {
            using var input = new FileStream(FilePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            if (input.Length > MaximumBytes) throw new InvalidDataException("Oversized extension settings.");
            var value = JsonSerializer.Deserialize<ExtensionConfiguration>(input, Json)
                ?? throw new InvalidDataException("Empty extension settings.");
            Validate(value);
            return value;
        }
        catch (FileNotFoundException) { return ExtensionConfiguration.Empty(); }
        catch (DirectoryNotFoundException) { return ExtensionConfiguration.Empty(); }
        catch (JsonException exception) { throw new InvalidDataException("Invalid extension settings.", exception); }
    }

    public ExtensionConfiguration SetEnabled(string id, bool enabled, long expectedRevision)
    {
        ExtensionIds.Validate(id);
        var directory = Path.GetDirectoryName(FilePath)!;
        Directory.CreateDirectory(directory);
        // A stable lock file coordinates our clients. Never unlink a shared lock inode.
        using var ownership = new FileStream(FilePath + ".lock", FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None);
        var current = Read();
        if (current.Revision != expectedRevision) throw new ExtensionSettingsConflictException();
        if (current.Revision == long.MaxValue) throw new InvalidDataException("Extension settings revision limit reached.");
        if (current.Extensions.TryGetValue(id, out var existing) && existing.Enabled == enabled) return current;
        var entries = new Dictionary<string, ExtensionPreference>(current.Extensions, StringComparer.Ordinal)
        { [id] = new(enabled) };
        var next = new ExtensionConfiguration(1, checked(current.Revision + 1), entries);
        Validate(next);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(next, Json);
        if (bytes.Length > MaximumBytes) throw new InvalidDataException("Oversized extension settings.");
        var temporary = FilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                output.Write(bytes);
                output.Flush(flushToDisk: true);
            }
            File.Move(temporary, FilePath, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
        return next;
    }

    private static void Validate(ExtensionConfiguration value)
    {
        if (value.SchemaVersion != 1 || value.Revision < 0 || value.Extensions is null || value.Extensions.Count > 64)
            throw new InvalidDataException("Unsupported extension settings schema or invalid configuration.");
        foreach (var (id, preference) in value.Extensions)
        {
            try { ExtensionIds.Validate(id); }
            catch (ArgumentException exception) { throw new InvalidDataException("Invalid extension identifier.", exception); }
            if (preference is null) throw new InvalidDataException("Missing extension preference.");
        }
    }
}
