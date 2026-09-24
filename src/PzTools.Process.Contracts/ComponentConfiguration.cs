using Tomlyn;
using Tomlyn.Model;

namespace PzTools.Process.Contracts;

public static class ComponentRuntimePaths
{
    public static string GetIdentityRoot(string identity)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(identity);
        var absolute = Path.GetFullPath(identity);
        var isFileIdentity = File.Exists(absolute)
            || string.Equals(Path.GetExtension(absolute), ".db", StringComparison.OrdinalIgnoreCase);
        return !isFileIdentity
            ? absolute
            : Path.GetDirectoryName(absolute)
                ?? throw new ArgumentException("The identity path has no parent directory.", nameof(identity));
    }

    public static string GetComponentDirectory(string identity, string component)
    {
        ValidateComponent(component);
        var absolute = Path.GetFullPath(identity);
        var isFileIdentity = File.Exists(absolute)
            || string.Equals(Path.GetExtension(absolute), ".db", StringComparison.OrdinalIgnoreCase);
        return isFileIdentity
            ? Path.Combine(
                GetIdentityRoot(absolute), ".pztools", Path.GetFileName(absolute), component)
            : Path.Combine(absolute, ".pztools", component);
    }

    public static string GetIdentityDefaultPath(
        string identity, string component, string? configurationRoot = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(identity);
        ValidateComponent(component);
        return Path.Combine(
            configurationRoot ?? PzToolsPathLayout.CreateDefault().ConfigurationRoot,
            component, "default.toml");
    }

    public static string GetPackagedDefaultPath(string component)
    {
        ValidateComponent(component);
        return Path.Combine(
            PzToolsPathLayout.CreateDefault().DefaultsRoot,
            component,
            "default.toml");
    }

    private static void ValidateComponent(string component)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(component);
        if (component.Any(character =>
                !(char.IsAsciiLetterOrDigit(character) || character is '-' or '_')))
        {
            throw new ArgumentException(
                "A component name may contain only ASCII letters, digits, '-' and '_'.",
                nameof(component));
        }
    }
}

public sealed class ComponentConfiguration
{
    private readonly TomlTable root;

    private ComponentConfiguration(TomlTable root) => this.root = root;

    public static ComponentConfiguration Parse(string text) => new(
        TomlSerializer.Deserialize<TomlTable>(text)
        ?? throw new InvalidDataException("The TOML document is empty."));

    public int GetInt32(string section, string key, int defaultValue, int minimum, int maximum)
    {
        var value = GetInt32(section, key, defaultValue);
        return value >= minimum && value <= maximum ? value
            : throw new InvalidDataException($"{section}.{key} must be between {minimum} and {maximum}.");
    }

    public static ComponentConfiguration Load(
        string identity,
        string component,
        string? explicitPath = null,
        string? appSettingsPath = null,
        string? configurationRoot = null)
    {
        var merged = new TomlTable();
        MergeIfPresent(merged, ComponentRuntimePaths.GetPackagedDefaultPath(component), required: false);
        MergeIfPresent(
            merged,
            ComponentRuntimePaths.GetIdentityDefaultPath(identity, component, configurationRoot),
            required: false);
        if (appSettingsPath is not null)
            ApplyAppOverrides(merged, component, appSettingsPath);
        if (explicitPath is not null)
        {
            MergeIfPresent(merged, Path.GetFullPath(explicitPath), required: true);
        }

        var configuration = new ComponentConfiguration(merged);
        ComponentOptions.Validate(component, configuration);
        return configuration;
    }

    public void ValidateSections(params string[] sections)
    {
        foreach (var key in root.Keys)
            if (!sections.Contains(key, StringComparer.Ordinal))
                throw new InvalidDataException($"Unknown configuration section '{key}'.");
    }

    public void ValidateSection(string section, params string[] keys)
    {
        if (!root.TryGetValue(section, out var value)) return;
        if (value is not TomlTable table) throw new InvalidDataException($"{section} must be a TOML table.");
        foreach (var key in table.Keys)
            if (!keys.Contains(key, StringComparer.Ordinal))
                throw new InvalidDataException($"Unknown configuration option '{section}.{key}'.");
    }

    public bool GetBoolean(string section, string key, bool defaultValue) =>
        TryGet(section, key, out var value)
            ? value is bool result
                ? result
                : throw InvalidValue(section, key, "boolean")
            : defaultValue;

    public int GetInt32(string section, string key, int defaultValue)
    {
        if (!TryGet(section, key, out var value)) return defaultValue;
        return value is long number && number is >= int.MinValue and <= int.MaxValue
            ? (int)number
            : throw InvalidValue(section, key, "32-bit integer");
    }

    public long GetInt64(string section, string key, long defaultValue)
    {
        if (!TryGet(section, key, out var value)) return defaultValue;
        return value is long number
            ? number
            : throw InvalidValue(section, key, "integer");
    }

    private bool TryGet(string section, string key, out object? value)
    {
        if (root.TryGetValue(section, out var existing) && existing is not TomlTable)
            throw new InvalidDataException($"{section} must be a TOML table.");
        if (root.TryGetValue(section, out var sectionValue)
            && sectionValue is TomlTable table
            && table.TryGetValue(key, out value))
        {
            return true;
        }

        value = null;
        return false;
    }

    private static void MergeIfPresent(TomlTable destination, string path, bool required)
    {
        if (!File.Exists(path))
        {
            if (required) throw new FileNotFoundException("The component configuration does not exist.", path);
            return;
        }

        TomlTable source;
        try
        {
            source = TomlSerializer.Deserialize<TomlTable>(File.ReadAllText(path))
                ?? throw new InvalidDataException($"Configuration '{path}' is empty.");
        }
        catch (Exception exception) when (exception is TomlException or IOException or UnauthorizedAccessException)
        {
            throw new InvalidDataException($"Cannot read component configuration '{path}'.", exception);
        }

        MergeTables(destination, source);
    }

    private static void MergeTables(TomlTable destination, TomlTable source)
    {
        foreach (var pair in source)
        {
            if (pair.Value is TomlTable sourceTable)
            {
                if (!destination.TryGetValue(pair.Key, out var destinationValue)
                    || destinationValue is not TomlTable destinationTable)
                {
                    destinationTable = new TomlTable();
                    destination[pair.Key] = destinationTable;
                }

                MergeTables(destinationTable, sourceTable);
            }
            else
            {
                destination[pair.Key] = pair.Value;
            }
        }
    }

    private static void ApplyAppOverrides(
        TomlTable destination, string component, string appPath)
    {
        if (!File.Exists(appPath)) return;
        var app = TomlSerializer.Deserialize<TomlTable>(File.ReadAllText(appPath))
            ?? throw new InvalidDataException($"App settings '{appPath}' are empty.");
        if (!app.TryGetValue("backup", out var backupValue) || backupValue is not TomlTable backup)
            return;
        var (sourceKey, targetSection, targetKey) = component switch
        {
            "state-reactor" => ("backup_on_death", "state", "backup_on_death"),
            "maintenance-worker" => ("retained_revisions", "maintenance", "retain_latest_revisions"),
            _ => ("", "", ""),
        };
        if (sourceKey.Length == 0 || !backup.TryGetValue(sourceKey, out var setting)) return;
        if (!destination.TryGetValue(targetSection, out var sectionValue)
            || sectionValue is not TomlTable section)
        {
            section = new TomlTable();
            destination[targetSection] = section;
        }
        section[targetKey] = setting;
    }

    private static InvalidDataException InvalidValue(
        string section,
        string key,
        string expected) =>
        new($"{section}.{key} must be a {expected}.");
}
