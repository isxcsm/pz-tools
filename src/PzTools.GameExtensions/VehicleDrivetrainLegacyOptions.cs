using System.Text.Json;
using static PzTools.GameExtensions.VehicleDrivetrainExtension;

namespace PzTools.GameExtensions;

/// <summary>
/// The vehicle's switches as settings.json kept them before options were kept by key: an object named
/// <c>vehicleDrivetrain</c> in the vehicle's preference. It is read into the options when no <c>options</c> object is
/// saved, and the next write leaves it behind.
/// </summary>
internal static class VehicleDrivetrainLegacyOptions
{
    private const string Property = "vehicleDrivetrain";

    /// <exception cref="InvalidDataException">The object, or one of its values, is not what any version wrote.</exception>
    public static IReadOnlyDictionary<string, bool>? Read(IReadOnlyDictionary<string, JsonElement> properties)
    {
        // Property names were matched without regard to case, as the settings file's other properties are.
        var found = properties.FirstOrDefault(property => property.Key.Equals(Property, StringComparison.OrdinalIgnoreCase));
        if (found.Key is null || found.Value.ValueKind == JsonValueKind.Null) return null;
        if (found.Value.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Vehicle driving preferences must be an object.");
        // Older experimental preferences exposed an observation-only mode. Never turn that preference into driving
        // changes merely because the three user-facing options changed. A switch missing from the file takes its
        // default, on like the others; the light's switch is missing from files written before it existed. Only an
        // old observation-only file turns them off.
        bool? torque = null, reverse = null, steering = null, areaLight = null;
        bool legacyProbe = false;
        foreach (var property in found.Value.EnumerateObject())
        {
            if (property.Name.Equals(Torque, StringComparison.OrdinalIgnoreCase)) torque = ReadBoolean(property);
            else if (property.Name.Equals(Reverse, StringComparison.OrdinalIgnoreCase)) reverse = ReadBoolean(property);
            else if (property.Name.Equals(Steering, StringComparison.OrdinalIgnoreCase)) steering = ReadBoolean(property);
            else if (property.Name.Equals(AreaLight, StringComparison.OrdinalIgnoreCase)) areaLight = ReadBoolean(property);
            else if (property.Name.Equals("probeOnly", StringComparison.OrdinalIgnoreCase)) legacyProbe = ReadBoolean(property);
        }
        return new Dictionary<string, bool>(StringComparer.Ordinal)
        {
            [Torque] = torque ?? !legacyProbe,
            [Reverse] = reverse ?? !legacyProbe,
            [Steering] = steering ?? !legacyProbe,
            [AreaLight] = !legacyProbe && (areaLight ?? true),
        };
    }

    private static bool ReadBoolean(JsonProperty property) => property.Value.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => throw new InvalidDataException(property.Name + " must be a boolean."),
    };
}
