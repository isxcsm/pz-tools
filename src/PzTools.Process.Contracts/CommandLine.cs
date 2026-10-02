using System.Globalization;

namespace PzTools.Process.Contracts;

/// <summary>
/// The one reading of worker command lines: "--name value" pairs and bare flags, each at most once,
/// numbers in invariant culture. Every problem is an <see cref="ArgumentException"/>; each program
/// keeps its own exit code for it.
/// </summary>
public static class CommandLine
{
    /// <summary>Every argument from <paramref name="start"/> must be a known option.</summary>
    public static Dictionary<string, string?> Parse(IReadOnlyList<string> arguments,
        IReadOnlyCollection<string> valued, IReadOnlyCollection<string>? flags = null, int start = 0)
    {
        var values = new Dictionary<string, string?>(StringComparer.Ordinal);
        for (var index = start; index < arguments.Count; index++)
        {
            var name = arguments[index];
            string? value = null;
            if (flags?.Contains(name) != true)
            {
                if (!valued.Contains(name)) throw new ArgumentException($"Unknown option '{name}'.");
                if (++index >= arguments.Count) throw new ArgumentException($"{name} requires a value.");
                value = arguments[index];
            }
            if (!values.TryAdd(name, value)) throw new ArgumentException($"{name} may be given only once.");
        }
        return values;
    }

    public static string Required(IReadOnlyDictionary<string, string?> values, string name) =>
        values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value : throw new ArgumentException($"{name} is required.");

    /// <summary>For a command line that also carries options for another program: finds one option by name.</summary>
    public static string? Optional(IReadOnlyList<string> arguments, string name)
    {
        var found = -1;
        for (var index = 0; index < arguments.Count; index++)
        {
            if (arguments[index] != name) continue;
            if (found >= 0) throw new ArgumentException($"{name} may be given only once.");
            found = index;
        }
        if (found < 0) return null;
        return found + 1 < arguments.Count ? arguments[found + 1] : throw new ArgumentException($"{name} requires a value.");
    }

    public static string Required(IReadOnlyList<string> arguments, string name) =>
        Optional(arguments, name) is { } value && !string.IsNullOrWhiteSpace(value)
            ? value : throw new ArgumentException($"{name} is required.");

    /// <summary>The arguments without the named options and their values, to pass the rest on.</summary>
    public static List<string> Without(IReadOnlyList<string> arguments, params string[] names)
    {
        var removed = new HashSet<string>(names, StringComparer.Ordinal);
        var kept = new List<string>(arguments.Count);
        for (var index = 0; index < arguments.Count; index++)
        {
            if (!removed.Contains(arguments[index])) { kept.Add(arguments[index]); continue; }
            if (++index >= arguments.Count) throw new ArgumentException($"{arguments[index - 1]} requires a value.");
        }
        return kept;
    }

    public static long Int64(string? text, string name, long minimum = 1, long maximum = long.MaxValue)
    {
        if (!long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value))
            throw new ArgumentException($"{name} must be a whole number.");
        return value >= minimum && value <= maximum ? value
            : throw new ArgumentOutOfRangeException(name, value, $"{name} must be from {minimum} to {maximum}.");
    }

    public static long? OptionalInt64(string? text, string name, long minimum = 1, long maximum = long.MaxValue) =>
        text is null ? null : Int64(text, name, minimum, maximum);

    public static int Int32(string? text, string name, int minimum = 1, int maximum = int.MaxValue) =>
        (int)Int64(text, name, minimum, maximum);
}
