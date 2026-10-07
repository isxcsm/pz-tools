using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace PzTools.GameExtensions;

/// <summary>What a continuous module is asked to run with, and the form the game reads it in.</summary>
public static class ContinuousConfiguration
{
    /// <summary>
    /// A module's settings: the player's saved options for it over its tuning files, as its descriptor builds them
    /// (<see cref="ExtensionDescriptor.Configuration"/>).
    /// </summary>
    /// <exception cref="InvalidDataException">No configuration is defined for the module, or a tuning file is invalid.</exception>
    public static IReadOnlyDictionary<string, string> For(string id, string bridgeDirectory, string runtimeRoot,
        ExtensionPreference preference) =>
        (ExtensionDescriptors.For(id).Configuration
            ?? throw new InvalidDataException("No configuration is defined for this continuous module."))
        .Load(bridgeDirectory, runtimeRoot, preference);

    /// <summary>The settings as the game reads them: <c>key\tvalue\n</c> lines in key order, UTF-8, base64.</summary>
    /// <exception cref="ArgumentException">A key or value the game would refuse, or more than the game reads.</exception>
    public static string Encode(IReadOnlyDictionary<string, string> configuration) => Convert.ToBase64String(Bytes(configuration));

    /// <summary>
    /// The configuration's SHA-256 (lowercase hex) in the form the game reads: equal for equal configurations, whatever the
    /// module. The scheduler keeps it per requested revision as the evidence of what the game applied.
    /// </summary>
    /// <exception cref="ArgumentException">A key or value the game would refuse, or more than the game reads.</exception>
    public static string Digest(IReadOnlyDictionary<string, string> configuration) =>
        Convert.ToHexStringLower(SHA256.HashData(Bytes(configuration)));

    private static byte[] Bytes(IReadOnlyDictionary<string, string> configuration)
    {
        var text = new StringBuilder();
        foreach (var (key, value) in configuration.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (string.IsNullOrEmpty(key) || key.Length > 80 || key.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not '.' and not '_' and not '-')
                || value.Any(char.IsControl)) throw new ArgumentException("Invalid extension configuration field.");
            text.Append(key).Append('\t').Append(value).Append('\n');
        }
        var bytes = Encoding.UTF8.GetBytes(text.ToString());
        if (bytes.Length > 65536) throw new ArgumentException("Oversized extension configuration.");
        return bytes;
    }
}

/// <summary>
/// What a game the startup loader started runs without the app (docs/design/startup-loader.md, "Resident extensions"):
/// the settings revision and each continuous module of the deployed catalogue, on or off, with its configuration. The
/// app writes it to the install folder; the game's resident controller reads it in each world.
/// </summary>
public static class ResidentExtensionRequest
{
    public const string FileName = "resident.tsv";

    /// <exception cref="IOException">The settings file could not be read.</exception>
    /// <exception cref="InvalidDataException">The settings file is invalid.</exception>
    public static string Build(string bridgeDirectory, string runtimeRoot)
    {
        var settings = new ExtensionSettingsStore(runtimeRoot).Read();
        IReadOnlyList<ExtensionDefinition> catalogue;
        try { catalogue = ExtensionCatalog.ReadFile(Path.Combine(bridgeDirectory, "extensions", "catalog.tsv")); }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException) { catalogue = ExtensionCatalog.BuiltIn; }
        var text = new StringBuilder("PZTOOLS-RESIDENT\t1\n");
        text.Append("revision\t").Append(settings.Revision.ToString(CultureInfo.InvariantCulture)).Append('\n');
        foreach (var definition in catalogue.Where(definition => definition.ActivationKind == ExtensionActivationKind.Continuous))
        {
            var preference = settings.Extensions.GetValueOrDefault(definition.Id) ?? new();
            bool on = preference.Enabled;
            string configuration = "";
            if (on)
            {
                // A module whose configuration cannot be built (a tuning file unreadable or invalid) is off, as the app
                // turns it off while connected, where the request fails as configuration-rejected
                // (docs/design/game-extensions.md, "Failure handling"): the game runs its own code.
                try { configuration = ContinuousConfiguration.Encode(ContinuousConfiguration.For(definition.Id, bridgeDirectory, runtimeRoot, preference)); }
                catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException
                    or FormatException or OverflowException) { on = false; }
            }
            text.Append("module\t").Append(definition.Id).Append('\t').Append(on ? "on" : "off").Append('\t')
                .Append(preference.ForceVersion ? "force" : "normal").Append('\t').Append(configuration).Append('\n');
        }
        return text.ToString();
    }

    /// <summary>Writes the request to the install folder unless it already says this; true when it was written.</summary>
    public static bool Write(string installFolder, string text)
    {
        var target = Path.Combine(installFolder, FileName);
        var bytes = new UTF8Encoding(false).GetBytes(text);
        try { if (File.ReadAllBytes(target).AsSpan().SequenceEqual(bytes)) return false; }
        catch (FileNotFoundException) { }
        // Written beside it and moved over it, so that the game never reads half of one.
        var staged = Path.Combine(installFolder, $"{FileName}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(staged, bytes);
            File.Move(staged, target, overwrite: true);
        }
        finally { File.Delete(staged); }
        return true;
    }
}
