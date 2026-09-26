using System.Text.RegularExpressions;

namespace PzTools.GameExtensions;

public sealed record ExtensionDefinition(string Id, string Version, string TitleKey,
    string DescriptionKey, string ReadinessCode, IReadOnlyList<string> Capabilities, GameVersionSupport? SupportedVersions = null)
{
    public ExtensionActivationKind ActivationKind => ExtensionCapabilities.Classify(Capabilities);
}

public static partial class ExtensionIds
{
    public const string SeamlessSave = "pztools.seamless-save";
    public const string VehicleDrivetrain = "pztools.vehicle-drivetrain";
    public static void Validate(string id)
    {
        if (id is null || id.Length > 80 || !ValidId().IsMatch(id))
            throw new ArgumentException("Invalid extension identifier.", nameof(id));
    }
    [GeneratedRegex("^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$", RegexOptions.CultureInvariant)]
    private static partial Regex ValidId();
}

[System.Text.Json.Serialization.JsonConverter(typeof(VehicleDrivetrainPreferenceConverter))]
public sealed record VehicleDrivetrainPreference(bool TorqueEnabled = true, bool ReverseEnabled = true, bool SteeringEnabled = true);
public sealed record ExtensionPreference(bool Enabled = false, bool ForceVersion = false,
    VehicleDrivetrainPreference? VehicleDrivetrain = null);
public sealed record ExtensionConfiguration(int SchemaVersion, long Revision,
    Dictionary<string, ExtensionPreference> Extensions)
{
    public static ExtensionConfiguration Empty() => new(1, 0, new(StringComparer.Ordinal));
}

public sealed record ExtensionCardView(ExtensionDefinition Definition, bool Enabled,
    string StatusCode, long SettingsRevision, bool ForceVersion = false, bool VersionMatches = true, string? GameVersion = null,
    VehicleDrivetrainPreference? VehicleDrivetrain = null)
{
    public ExtensionCardView WithVersion(string? version)
    {
        bool matches = (Definition.SupportedVersions ?? GameVersionSupport.All).Matches(version);
        string status = !matches && !ForceVersion ? version is null ? "version-unknown" : "version-mismatch"
            : !Enabled ? "disabled" : ForceVersion && !matches ? "forced-version" : Definition.ReadinessCode;
        return this with { GameVersion = version, VersionMatches = matches, StatusCode = status };
    }
    public bool SupportsActivation => Definition.ActivationKind != ExtensionActivationKind.Unsupported;
    // Admission hint only. Saving a desired preference does not require a currently running compatible game.
    public bool CanEnable => SupportsActivation && (VersionMatches || ForceVersion);
    public bool EffectiveEnabled => Enabled && CanEnable;
}

public sealed class ExtensionSettingsConflictException()
    : IOException("Extension settings changed in another client. Reload before applying.");

/// <summary>Management plane only. A saved preference is never evidence of an applied game patch.</summary>
public sealed class GameExtensionService(ExtensionSettingsStore settings, Func<string?>? gameVersion = null, Func<IReadOnlyList<ExtensionDefinition>>? catalogue = null)
{
    public IReadOnlyList<ExtensionCardView> ReadCards()
    {
        var config = settings.Read();
        return (catalogue?.Invoke() ?? ExtensionCatalog.BuiltIn).Select(definition =>
        {
            var preference = config.Extensions.GetValueOrDefault(definition.Id) ?? new();
            var enabled = preference.Enabled;
            var version = gameVersion?.Invoke();
            bool matches = (definition.SupportedVersions ?? GameVersionSupport.All).Matches(version);
            return new ExtensionCardView(definition, enabled,
                !matches && !preference.ForceVersion ? version is null ? "version-unknown" : "version-mismatch"
                    : !enabled ? "disabled" : preference.ForceVersion && !matches ? "forced-version" : definition.ReadinessCode,
                config.Revision, preference.ForceVersion, matches, version, preference.VehicleDrivetrain);
        }).ToArray();
    }
    public IReadOnlyList<ExtensionCardView> SetPreference(string id, bool enabled, bool forceVersion, long revision)
    {
        var card = ReadCards().Single(item => item.Definition.Id == id);
        if (enabled && !card.SupportsActivation)
            throw new InvalidDataException("Extension capability is unsupported.");
        settings.SetPreference(id, new(enabled, forceVersion, card.VehicleDrivetrain), revision);
        return ReadCards();
    }
    public IReadOnlyList<ExtensionCardView> SetVehicleDrivetrainPreference(VehicleDrivetrainPreference preference, long revision)
    {
        ArgumentNullException.ThrowIfNull(preference);
        var card = ReadCards().Single(item => item.Definition.Id == ExtensionIds.VehicleDrivetrain);
        settings.SetPreference(ExtensionIds.VehicleDrivetrain, new(card.Enabled, card.ForceVersion, preference), revision);
        return ReadCards();
    }
    public IReadOnlyList<ExtensionCardView> SetEnabled(string id, bool enabled, long revision)
    {
        if (!(catalogue?.Invoke() ?? ExtensionCatalog.BuiltIn).Any(item => item.Id == id))
            throw new ArgumentException("Unknown extension.", nameof(id));
        var card = ReadCards().Single(item => item.Definition.Id == id);
        if (enabled && !card.SupportsActivation)
            throw new InvalidDataException("Extension capability is unsupported.");
        settings.SetEnabled(id, enabled, revision);
        return ReadCards();
    }
}
