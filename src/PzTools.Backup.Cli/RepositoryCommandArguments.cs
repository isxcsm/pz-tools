using System.Globalization;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Cli;

internal static class RepositoryCommandArguments
{
    public static IReadOnlyDictionary<string, string> Parse(
        string[] arguments,
        params string[] allowed)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < arguments.Length; index++)
        {
            var name = arguments[index];
            if (!allowed.Contains(name, StringComparer.Ordinal))
            {
                throw new BackupConfigurationException($"Unknown option '{name}'.");
            }

            if (!values.TryAdd(name, string.Empty))
            {
                throw new BackupConfigurationException($"Option '{name}' may be specified only once.");
            }

            if (++index >= arguments.Length)
            {
                throw new BackupConfigurationException($"Option '{name}' requires a value.");
            }

            values[name] = arguments[index];
        }

        return values;
    }

    public static string Required(
        IReadOnlyDictionary<string, string> values,
        string name) =>
        values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new BackupConfigurationException($"Option '{name}' is required.");

    // Run numbers, backup numbers and counts kept all start at 1.
    public static long RequiredInt64(
        IReadOnlyDictionary<string, string> values,
        string name)
    {
        var value = Required(values, name);
        return long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)
            && parsed >= 1
            ? parsed
            : throw new BackupConfigurationException($"Option '{name}' must be a whole number of at least 1.");
    }
}
