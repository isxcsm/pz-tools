using System.Text.RegularExpressions;

namespace PzTools.GameExtensions;

public sealed record ExtensionDefinition(string Id, string Version, string TitleKey,
    string DescriptionKey, string ReadinessCode, IReadOnlyList<string> Capabilities);

public static partial class ExtensionIds
{
    public const string SeamlessSave = "pztools.seamless-save";
    public static void Validate(string id)
    {
        if (id is null || id.Length > 80 || !ValidId().IsMatch(id))
            throw new ArgumentException("Invalid extension identifier.", nameof(id));
    }
    [GeneratedRegex("^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$", RegexOptions.CultureInvariant)]
    private static partial Regex ValidId();
}

// Discovery is deliberately curated in v1. No arbitrary JAR, XAML, shell or network package execution.
public static class ExtensionCatalog
{
    public static IReadOnlyList<ExtensionDefinition> BuiltIn { get; } = Array.AsReadOnly(new[]
    {
        new ExtensionDefinition(ExtensionIds.SeamlessSave, "0.1.0", "Extension.SeamlessSave.Title",
            "Extension.SeamlessSave.Description", "adapter-validation-required",
            Array.AsReadOnly(new[] { "save.prepare.v1" })),
    });
}

public sealed record ExtensionPreference(bool Enabled = false);
public sealed record ExtensionConfiguration(int SchemaVersion, long Revision,
    Dictionary<string, ExtensionPreference> Extensions)
{
    public static ExtensionConfiguration Empty() => new(1, 0, new(StringComparer.Ordinal));
}

public sealed record ExtensionCardView(ExtensionDefinition Definition, bool Enabled,
    string StatusCode, long SettingsRevision);

public sealed class ExtensionSettingsConflictException()
    : IOException("Extension settings changed in another client. Reload before applying.");

/// <summary>Management plane only. A saved preference is never evidence of an applied game patch.</summary>
public sealed class GameExtensionService(ExtensionSettingsStore settings)
{
    public IReadOnlyList<ExtensionCardView> ReadCards()
    {
        var config = settings.Read();
        return ExtensionCatalog.BuiltIn.Select(definition =>
        {
            var enabled = config.Extensions.GetValueOrDefault(definition.Id)?.Enabled ?? false;
            return new ExtensionCardView(definition, enabled,
                enabled ? definition.ReadinessCode : "disabled", config.Revision);
        }).ToArray();
    }
    public IReadOnlyList<ExtensionCardView> SetEnabled(string id, bool enabled, long revision)
    {
        if (!ExtensionCatalog.BuiltIn.Any(item => item.Id == id))
            throw new ArgumentException("Unknown extension.", nameof(id));
        settings.SetEnabled(id, enabled, revision);
        return ReadCards();
    }
}
