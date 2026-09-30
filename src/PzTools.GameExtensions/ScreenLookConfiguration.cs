using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using Tomlyn;
using Tomlyn.Model;
using Tomlyn.Parsing;

namespace PzTools.GameExtensions;

/// <summary>
/// The screen look module's flat settings: the three choices made in the app, and two tuning
/// values from TOML. The choices have no TOML form, so a file cannot disagree with what the app shows.
/// </summary>
public static class ScreenLookConfiguration
{
    private const int MaximumBytes = 65536;
    private const string FileName = "screen-look.toml";
    private static readonly IReadOnlyDictionary<string, (double Default, double Min, double Max)> Numbers =
        new Dictionary<string, (double, double, double)>(StringComparer.Ordinal)
        {
            ["clarity_scale"] = (1, 0, 2), ["seasonal_amount"] = (0.8, 0, 1),
        };

    public static IReadOnlyDictionary<string, string> Load(string bridgeDirectory, string runtimeRoot, ScreenLookPreference? preference = null)
    {
        var values = Defaults();
        Apply(values, Read(Path.Combine(Path.GetFullPath(bridgeDirectory), "extensions", FileName)));
        try { Apply(values, Read(Path.Combine(Path.GetFullPath(runtimeRoot), "extensions", FileName))); }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }
        preference ??= new ScreenLookPreference();
        preference.Validate();
        values["preset"] = preference.Preset;
        values["strength"] = preference.Strength.ToString(CultureInfo.InvariantCulture);
        values["seasonal"] = preference.Seasonal ? "true" : "false";
        return new ReadOnlyDictionary<string, string>(values);
    }

    public static IReadOnlyDictionary<string, string> Parse(string text)
    {
        var values = Defaults();
        Apply(values, text);
        return new ReadOnlyDictionary<string, string>(values);
    }

    private static Dictionary<string, string> Defaults()
    {
        var result = Numbers.ToDictionary(pair => pair.Key, pair => pair.Value.Default.ToString("R", CultureInfo.InvariantCulture), StringComparer.Ordinal);
        result.Add("schema_version", "1");
        return result;
    }

    private static string Read(string path)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (input.Length > MaximumBytes) throw new InvalidDataException("Oversized screen look configuration.");
        using var reader = new StreamReader(input, new UTF8Encoding(false, true), detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    private static void Apply(Dictionary<string, string> destination, string text)
    {
        if (text.Length > MaximumBytes) throw new InvalidDataException("Oversized screen look configuration.");
        TomlTable table;
        try
        {
            // Validate the source first so duplicate keys cannot silently become a last-writer-wins setting.
            SyntaxParser.ParseStrict(text, sourceName: FileName, validate: true);
            table = TomlSerializer.Deserialize<TomlTable>(text) ?? throw new InvalidDataException("Empty screen look configuration.");
        }
        catch (TomlException failure) { throw new InvalidDataException("Invalid screen look TOML.", failure); }
        foreach (var (key, value) in table)
        {
            if (key == "schema_version")
            {
                if (value is not long version || version != 1) throw new InvalidDataException("schema_version must be the integer 1.");
            }
            else if (Numbers.TryGetValue(key, out var range))
            {
                double number = value switch { long integer => integer, double real => real, _ => double.NaN };
                if (!double.IsFinite(number) || number < range.Min || number > range.Max)
                    throw new InvalidDataException(key + " is outside its finite allowed range.");
                destination[key] = number.ToString("R", CultureInfo.InvariantCulture);
            }
            else throw new InvalidDataException("Unknown screen look setting: " + key);
        }
    }
}
