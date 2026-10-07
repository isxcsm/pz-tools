using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace PzTools.GameExtensions;

/// <summary>Independent of backup configuration and WinUI. Failed reads never overwrite preferences.</summary>
public sealed partial class ExtensionSettingsStore
{
    private const int MaximumBytes = 64 * 1024;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    public string FilePath { get; }
    public ExtensionSettingsStore(string runtimeRoot) =>
        FilePath = Path.Combine(Path.GetFullPath(runtimeRoot), "extensions", "settings.json");

    // The file as read: each preference keeps the properties this version does not know, where an earlier version may
    // have saved an extension's switches (ExtensionDescriptor.LegacyOptions).
    private sealed record StoredConfiguration(int SchemaVersion, long Revision, Dictionary<string, StoredPreference?>? Extensions);
    private sealed class StoredPreference
    {
        public bool Enabled { get; set; }
        public bool ForceVersion { get; set; }
        public Dictionary<string, bool>? Options { get; set; }
        [JsonExtensionData] public Dictionary<string, JsonElement>? Other { get; set; }
    }

    public ExtensionConfiguration Read()
    {
        // File.Exists would hide access-denied as an empty default configuration.
        try
        {
            using var input = new FileStream(FilePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            if (input.Length > MaximumBytes) throw new InvalidDataException("Oversized extension settings.");
            var stored = JsonSerializer.Deserialize<StoredConfiguration>(input, Json)
                ?? throw new InvalidDataException("Empty extension settings.");
            if (stored.Extensions is null || stored.Extensions.Count > 64)
                throw new InvalidDataException("Unsupported extension settings schema or invalid configuration.");
            var extensions = new Dictionary<string, ExtensionPreference>(StringComparer.Ordinal);
            foreach (var (id, preference) in stored.Extensions)
            {
                if (preference is null) throw new InvalidDataException("Missing extension preference.");
                try { ExtensionIds.Validate(id); }
                catch (ArgumentException exception) { throw new InvalidDataException("Invalid extension identifier.", exception); }
                // Switches saved the way an earlier version saved them are read as options; the next write leaves the
                // old form behind. Properties no extension reads (those of a retired one) are dropped the same way.
                var options = preference.Options ?? (preference.Other is { Count: > 0 } other
                    ? ExtensionDescriptors.For(id).LegacyOptions?.Invoke(other) : null);
                extensions[id] = new(preference.Enabled, preference.ForceVersion, options);
            }
            var value = new ExtensionConfiguration(stored.SchemaVersion, stored.Revision, extensions);
            Validate(value);
            return value;
        }
        catch (FileNotFoundException) { return ExtensionConfiguration.Empty(); }
        catch (DirectoryNotFoundException) { return ExtensionConfiguration.Empty(); }
        catch (JsonException exception) { throw new InvalidDataException("Invalid extension settings.", exception); }
    }

    public ExtensionConfiguration SetEnabled(string id, bool enabled, long expectedRevision) =>
        Update(id, expectedRevision, existing => existing with { Enabled = enabled });

    public ExtensionConfiguration SetPreference(string id, ExtensionPreference preference, long expectedRevision) =>
        Update(id, expectedRevision, _ => preference);
    private ExtensionConfiguration Update(string id, long expectedRevision, Func<ExtensionPreference, ExtensionPreference> change)
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
        var existing = current.Extensions.GetValueOrDefault(id) ?? new();
        var preference = change(existing);
        if (existing == preference) return current;
        var entries = new Dictionary<string, ExtensionPreference>(current.Extensions, StringComparer.Ordinal)
        { [id] = preference };
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
            if (preference.Options is { } options && (options.Count > 64 || options.Keys.Any(key => key is null || !OptionKey().IsMatch(key))))
                throw new InvalidDataException("Invalid extension option.");
        }
    }

    [GeneratedRegex("^[A-Za-z][A-Za-z0-9._-]{0,79}$", RegexOptions.CultureInvariant)]
    private static partial Regex OptionKey();
}
