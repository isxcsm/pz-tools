using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace PzTools.GameExtensions;

public sealed record ExtensionDefinition(string Id, string Version, string TitleKey,
    string DescriptionKey, string ReadinessCode, IReadOnlyList<string> Capabilities, GameVersionSupport? SupportedVersions = null)
{
    public ExtensionActivationKind ActivationKind => ExtensionCapabilities.Classify(Capabilities);
}

public static partial class ExtensionIds
{
    public static void Validate(string id)
    {
        if (id is null || id.Length > 80 || !ValidId().IsMatch(id))
            throw new ArgumentException("Invalid extension identifier.", nameof(id));
    }
    [GeneratedRegex("^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$", RegexOptions.CultureInvariant)]
    private static partial Regex ValidId();
}

/// <summary>
/// One extension's saved request: its main switch, the version override, and its own switches by key
/// (<see cref="ExtensionDescriptor.Options"/>). A switch not saved takes its default. Two preferences are equal when
/// their values are, whatever dictionary holds the switches.
/// </summary>
public sealed record ExtensionPreference(bool Enabled = false, bool ForceVersion = false,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyDictionary<string, bool>? Options = null)
{
    /// <summary>The switch's saved value, or its default when none is saved.</summary>
    public bool Option(ExtensionOption option) =>
        Options is not null && Options.TryGetValue(option.Key, out var value) ? value : option.Default;

    /// <summary>This preference with one switch set and the others as saved.</summary>
    public ExtensionPreference WithOption(string key, bool value)
    {
        var options = new SortedDictionary<string, bool>(StringComparer.Ordinal);
        foreach (var (name, saved) in Options ?? new Dictionary<string, bool>()) options[name] = saved;
        options[key] = value;
        return this with { Options = options };
    }

    public bool Equals(ExtensionPreference? other) => other is not null && Enabled == other.Enabled
        && ForceVersion == other.ForceVersion && SameOptions(Options, other.Options);

    public override int GetHashCode() => HashCode.Combine(Enabled, ForceVersion, Options?.Count ?? 0);

    /// <summary>Whether two sets of switches say the same; none saved and an empty set do.</summary>
    public static bool SameOptions(IReadOnlyDictionary<string, bool>? left, IReadOnlyDictionary<string, bool>? right)
    {
        if ((left?.Count ?? 0) != (right?.Count ?? 0)) return false;
        foreach (var (key, value) in left ?? new Dictionary<string, bool>())
            if (!right!.TryGetValue(key, out var other) || other != value) return false;
        return true;
    }
}

public sealed record ExtensionConfiguration(int SchemaVersion, long Revision,
    Dictionary<string, ExtensionPreference> Extensions)
{
    public static ExtensionConfiguration Empty() => new(1, 0, new(StringComparer.Ordinal));
}

public sealed record ExtensionCardView(ExtensionDefinition Definition, bool Enabled,
    string StatusCode, long SettingsRevision, bool ForceVersion = false, bool VersionMatches = true, string? GameVersion = null,
    IReadOnlyDictionary<string, bool>? Options = null)
{
    /// <summary>The card of one catalogue row, from its saved preference and the running game's version.</summary>
    public static ExtensionCardView For(ExtensionDefinition definition, ExtensionPreference preference, long settingsRevision,
        string? gameVersion)
    {
        bool matches = (definition.SupportedVersions ?? GameVersionSupport.All).Matches(gameVersion);
        string status = !matches && !preference.ForceVersion ? gameVersion is null ? "version-unknown" : "version-mismatch"
            : !preference.Enabled ? "disabled" : preference.ForceVersion && !matches ? "forced-version" : definition.ReadinessCode;
        return new(definition, preference.Enabled, status, settingsRevision, preference.ForceVersion, matches, gameVersion,
            preference.Options);
    }

    /// <summary>The saved preference the card shows.</summary>
    public ExtensionPreference Preference => new(Enabled, ForceVersion, Options);
    /// <summary>The switch's saved value, or its default.</summary>
    public bool Option(ExtensionOption option) => Preference.Option(option);
    public bool SupportsActivation => Definition.ActivationKind != ExtensionActivationKind.Unsupported;
    // Admission hint only. Saving a desired preference does not require a currently running compatible game.
    public bool CanEnable => SupportsActivation && (VersionMatches || ForceVersion);
    public bool EffectiveEnabled => Enabled && CanEnable;
    /// <summary>
    /// The running game reported a version outside the supported range and the range is not ignored. The game
    /// would reject an ON request and the module would be saved off again, so turning it on is refused up front.
    /// An unknown version is not this: an ON saved while no game runs is checked when one starts.
    /// </summary>
    public bool OutsideKnownSupportedRange => GameVersion is not null && !VersionMatches && !ForceVersion;

    public bool Equals(ExtensionCardView? other) => other is not null && Definition == other.Definition
        && Enabled == other.Enabled && StatusCode == other.StatusCode && SettingsRevision == other.SettingsRevision
        && ForceVersion == other.ForceVersion && VersionMatches == other.VersionMatches && GameVersion == other.GameVersion
        && ExtensionPreference.SameOptions(Options, other.Options);

    public override int GetHashCode() => HashCode.Combine(Definition.Id, Enabled, SettingsRevision);
}

public sealed class ExtensionSettingsConflictException()
    : IOException("Extension settings changed in another client. Reload before applying.");

/// <summary>Management plane only. A saved preference is never evidence of an applied game patch.</summary>
public sealed class GameExtensionService(ExtensionSettingsStore settings, Func<string?>? gameVersion = null, Func<IReadOnlyList<ExtensionDefinition>>? catalogue = null)
{
    public IReadOnlyList<ExtensionCardView> ReadCards() => Project(settings.Read());

    /// <summary>
    /// Saves one extension's preference over the card it was read with. The settings revision the card shows is checked
    /// under the file's lock: a file changed since is refused with <see cref="ExtensionSettingsConflictException"/>,
    /// never overwritten. The cards come from what was written, without reading the file again.
    /// </summary>
    public IReadOnlyList<ExtensionCardView> Save(ExtensionCardView card, ExtensionPreference preference) =>
        Project(settings.SetPreference(card.Definition.Id, preference, card.SettingsRevision));

    private IReadOnlyList<ExtensionCardView> Project(ExtensionConfiguration config)
    {
        var version = gameVersion?.Invoke();
        return (catalogue?.Invoke() ?? ExtensionCatalog.BuiltIn).Select(definition => ExtensionCardView.For(definition,
            config.Extensions.GetValueOrDefault(definition.Id) ?? new(), config.Revision, version)).ToArray();
    }
}
