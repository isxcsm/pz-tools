using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using Tomlyn;
using Tomlyn.Model;
using Tomlyn.Parsing;

namespace PzTools.GameExtensions;

/// <summary>Strict, read-only TOML layering. Values are normalized for the flat JVM settings contract.</summary>
public static class VehicleDrivetrainConfiguration
{
    private const int MaximumBytes = 65536;
    private static readonly IReadOnlyDictionary<string, (double Default, double Min, double Max)> Numbers =
        new Dictionary<string, (double, double, double)>(StringComparer.Ordinal)
        {
            ["force_scale"] = (1, 0.25, 1.5), ["low_gear_boost"] = (1, 1, 1.6),
            ["forward_torque_boost_fraction"] = (0.10, 0, 0.10),
            ["reverse_force_ratio"] = (1, 0.4, 1), ["reverse_max_speed_kph"] = (0, 0, 35),
            ["reverse_ramp_seconds"] = (0.8, 0.3, 2), ["forward_ramp_seconds"] = (0.3, 0.1, 2),
            ["direction_hold_seconds"] = (0.15, 0.05, 0.75), ["max_dt_seconds"] = (0.1, 0.02, 0.25),
            ["shift_hold_seconds"] = (0.35, 0.1, 2), ["upshift_rpm_fraction"] = (0.82, 0.65, 0.95),
            ["downshift_rpm_fraction"] = (0.32, 0.15, 0.55),
            ["gear_ratio_span"] = (3.6, 2.5, 5), ["idle_rpm"] = (800, 500, 1200), ["launch_rpm"] = (1500, 1000, 2500),
            ["generic_redline_rpm"] = (5500, 3000, 6500), ["utility_redline_rpm"] = (4500, 3000, 6500),
            ["sport_redline_rpm"] = (6500, 3000, 6500),
            ["generic_torque_peak_fraction"] = (0.5, 0.25, 0.8), ["utility_torque_peak_fraction"] = (0.4, 0.25, 0.8),
            ["sport_torque_peak_fraction"] = (0.65, 0.25, 0.8), ["idle_torque_fraction"] = (0.6, 0.3, 0.8),
            ["rpm_response_seconds"] = (0.12, 0.04, 0.5), ["direction_speed_mps"] = (0.15, 0.05, 0.3),
            ["forward_governor_start_fraction"] = (1, 0.75, 1), ["reverse_governor_start_fraction"] = (1, 0.5, 1),
            ["shift_hysteresis_fraction"] = (0.08, 0.04, 0.15), ["demand_downshift_fraction"] = (0.48, 0.25, 0.6),
            ["area_light_radius"] = (8, 3, 20), ["area_light_brightness"] = (0.6, 0.1, 1),
        };
    private static readonly IReadOnlyDictionary<string, bool> Booleans = new Dictionary<string, bool>(StringComparer.Ordinal)
    {
        ["torque_enabled"] = true, ["reverse_enabled"] = true, ["steering_enabled"] = true,
        ["steering_precise_input"] = true, ["area_light_enabled"] = false,
        ["low_mode"] = false, ["probe_only"] = false, ["diagnostics_enabled"] = false,
    };
    // Steering now follows the game's own response, so its rates are no longer tunable. An override
    // file written for an earlier build may still name them: read them as numbers and drop them,
    // rather than refusing the whole file over settings that no longer do anything.
    private static readonly HashSet<string> Retired = new(StringComparer.Ordinal)
    {
        "steering_initial_rate", "steering_full_rate", "steering_ramp_seconds", "steering_return_rate",
        "steering_countersteer_rate", "steering_high_speed_rate_factor",
    };

    public static IReadOnlyDictionary<string, string> Load(string bridgeDirectory, string runtimeRoot,
        VehicleDrivetrainPreference? preference = null)
    {
        var values = Defaults();
        Apply(values, Read(Path.Combine(Path.GetFullPath(bridgeDirectory), "extensions", "vehicle-drivetrain.toml")));
        Validate(values);
        var overridePath = Path.Combine(Path.GetFullPath(runtimeRoot), "extensions", "vehicle-drivetrain.toml");
        try { Apply(values, Read(overridePath)); }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }
        // The visible switches have one source of truth, including before the first
        // settings write. A TOML override must not disagree with the defaults shown by the UI.
        preference ??= new VehicleDrivetrainPreference();
        values["torque_enabled"] = preference.TorqueEnabled ? "true" : "false";
        values["reverse_enabled"] = preference.ReverseEnabled ? "true" : "false";
        values["steering_enabled"] = preference.SteeringEnabled ? "true" : "false";
        values["area_light_enabled"] = preference.AreaLightEnabled ? "true" : "false";
        Validate(values);
        return new ReadOnlyDictionary<string, string>(values);
    }

    public static IReadOnlyDictionary<string, string> Parse(string text)
    {
        var values = Defaults();
        Apply(values, text);
        Validate(values);
        return new ReadOnlyDictionary<string, string>(values);
    }

    private static Dictionary<string, string> Defaults()
    {
        var result = Numbers.ToDictionary(pair => pair.Key, pair => pair.Value.Default.ToString("R", CultureInfo.InvariantCulture), StringComparer.Ordinal);
        result.Add("schema_version", "1");
        foreach (var (key, enabled) in Booleans) result.Add(key, enabled ? "true" : "false");
        return result;
    }

    private static string Read(string path)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (input.Length > MaximumBytes) throw new InvalidDataException("Oversized vehicle drivetrain configuration.");
        using var reader = new StreamReader(input, new UTF8Encoding(false, true), detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    private static void Apply(Dictionary<string, string> destination, string text)
    {
        if (text.Length > MaximumBytes) throw new InvalidDataException("Oversized vehicle drivetrain configuration.");
        TomlTable table;
        try
        {
            // Deserializing a model table alone can normalize duplicate keys. Validate the
            // source first so ambiguous TOML cannot silently become a last-writer-wins setting.
            SyntaxParser.ParseStrict(text, sourceName: "vehicle-drivetrain.toml", validate: true);
            table = TomlSerializer.Deserialize<TomlTable>(text) ?? throw new InvalidDataException("Empty vehicle drivetrain configuration.");
        }
        catch (TomlException failure) { throw new InvalidDataException("Invalid vehicle drivetrain TOML.", failure); }
        foreach (var (key, value) in table)
        {
            if (key == "schema_version")
            {
                if (value is not long version || version != 1) throw new InvalidDataException("schema_version must be the integer 1.");
                destination[key] = "1";
            }
            else if (Booleans.ContainsKey(key))
            {
                if (value is not bool enabled) throw new InvalidDataException(key + " must be a boolean.");
                destination[key] = enabled ? "true" : "false";
            }
            else if (Numbers.TryGetValue(key, out var range))
            {
                double number = value switch { long integer => integer, double real => real, _ => double.NaN };
                if (!double.IsFinite(number) || number < range.Min || number > range.Max)
                    throw new InvalidDataException(key + " is outside its finite allowed range.");
                destination[key] = number.ToString("R", CultureInfo.InvariantCulture);
            }
            else if (Retired.Contains(key))
            {
                if (value is not (long or double)) throw new InvalidDataException(key + " must be a number.");
            }
            else throw new InvalidDataException("Unknown vehicle drivetrain setting: " + key);
        }
    }

    private static void Validate(IReadOnlyDictionary<string, string> values)
    {
        var up = double.Parse(values["upshift_rpm_fraction"], CultureInfo.InvariantCulture);
        var down = double.Parse(values["downshift_rpm_fraction"], CultureInfo.InvariantCulture);
        if (up - down + 1e-12 < 0.15) throw new InvalidDataException("The shift thresholds must differ by at least 0.15.");
        double Number(string key) => double.Parse(values[key], CultureInfo.InvariantCulture);
        // Zero delegates to the vehicle's vanilla reverse reference; explicit limits remain 4..35.
        if (Number("reverse_max_speed_kph") is > 0 and < 4)
            throw new InvalidDataException("reverse_max_speed_kph must be 0 (vanilla vehicle limit) or between 4 and 35.");
        var idle = Number("idle_rpm");
        var launch = Number("launch_rpm");
        var minimumRedline = Math.Min(Number("generic_redline_rpm"), Math.Min(Number("utility_redline_rpm"), Number("sport_redline_rpm")));
        if (idle >= launch || launch >= minimumRedline)
            throw new InvalidDataException("RPM tuning requires idle_rpm < launch_rpm < every redline.");
        if (launch > minimumRedline * up / Math.Sqrt(Number("gear_ratio_span")) + 1e-9)
            throw new InvalidDataException("launch_rpm exceeds the lowest post-upshift RPM of the supported profiles.");
    }
}
