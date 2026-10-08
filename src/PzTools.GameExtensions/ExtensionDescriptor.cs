using System.Collections.Frozen;
using System.Text.Json;

namespace PzTools.GameExtensions;

/// <summary>One on/off option of an extension: its key in the saved preference, the resources of its row, its default.</summary>
public sealed record ExtensionOption(string Key, string TitleKey, string DescriptionKey, bool Default = true);

/// <summary>
/// What the app knows of one extension beyond its catalogue row, as data the generic layers read: the glyph of its
/// section, its own options in the order the section shows them, how its configuration is built, and how earlier
/// versions saved its options. An extension without a descriptor has no options and the general glyph, and a request
/// to run it fails with <c>configuration-rejected</c>.
/// </summary>
public sealed class ExtensionDescriptor
{
    /// <summary>The section's glyph when the extension names none: a puzzle piece.</summary>
    public const string DefaultGlyph = "";

    public required string Id { get; init; }

    /// <summary>A Segoe Fluent Icons glyph for the header of the extension's section, in the text colour.</summary>
    public string Glyph { get; init; } = DefaultGlyph;

    /// <summary>The extension's own switches, in the order its section shows them.</summary>
    public IReadOnlyList<ExtensionOption> Options { get; init; } = [];

    /// <summary>
    /// The resource of the hint shown while a change waits in the game for the module's own safe point (the game says
    /// <c>safe-boundary</c>): what the player can do to let it apply. By default the general "applying" hint.
    /// </summary>
    public string SafeBoundaryHintKey { get; init; } = "GameExtensions.Applying";

    /// <summary>Builds what the module runs with; null when none is defined.</summary>
    public IContinuousConfiguration? Configuration { get; init; }

    /// <summary>
    /// Reads options an earlier version of <c>settings.json</c> kept elsewhere in this extension's preference, from the
    /// preference's other properties by name; null when they hold none.
    /// </summary>
    /// <exception cref="InvalidDataException">A value the earlier version could not have written.</exception>
    public Func<IReadOnlyDictionary<string, JsonElement>, IReadOnlyDictionary<string, bool>?>? LegacyOptions { get; init; }

    public ExtensionOption? Option(string key) => Options.FirstOrDefault(option => option.Key == key);
}

/// <summary>How one continuous module's configuration is built: the flat key/value settings the game's <c>APPLY</c> carries.</summary>
public interface IContinuousConfiguration
{
    /// <summary>The player's saved options for the module over its tuning files.</summary>
    /// <exception cref="InvalidDataException">A tuning file is invalid.</exception>
    /// <exception cref="IOException">A tuning file cannot be read.</exception>
    IReadOnlyDictionary<string, string> Load(string bridgeDirectory, string runtimeRoot, ExtensionPreference preference);

    /// <summary>The files <see cref="Load"/> reads besides the saved preference, so that a caller can skip a rebuild.</summary>
    IReadOnlyList<string> Inputs(string bridgeDirectory, string runtimeRoot);
}

/// <summary>
/// The extensions this app knows by id. Registering a descriptor here is the one place the generic layers meet a
/// particular extension; the descriptor and everything it points to live in that extension's own files.
/// </summary>
public static class ExtensionDescriptors
{
    private static readonly FrozenDictionary<string, ExtensionDescriptor> Known =
        new[] { VehicleDrivetrainExtension.Descriptor }.ToFrozenDictionary(descriptor => descriptor.Id, StringComparer.Ordinal);

    public static IEnumerable<ExtensionDescriptor> All => Known.Values;

    /// <summary>The extension's descriptor; for an id without one, a descriptor with no options and no configuration.</summary>
    public static ExtensionDescriptor For(string id) => Known.GetValueOrDefault(id) ?? new ExtensionDescriptor { Id = id };
}
