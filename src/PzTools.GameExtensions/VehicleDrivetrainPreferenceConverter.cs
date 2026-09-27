using System.Text.Json;
using System.Text.Json.Serialization;

namespace PzTools.GameExtensions;

// Older experimental preferences exposed an observation-only mode. Never turn that
// preference into driving changes merely because the three user-facing options changed.
internal sealed class VehicleDrivetrainPreferenceConverter : JsonConverter<VehicleDrivetrainPreference>
{
    public override VehicleDrivetrainPreference Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new JsonException("Vehicle driving preferences must be an object.");
        bool? torque = null, reverse = null, steering = null;
        bool legacyProbe = false;
        foreach (var property in document.RootElement.EnumerateObject())
        {
            if (property.Name.Equals("torqueEnabled", StringComparison.OrdinalIgnoreCase)) torque = ReadBoolean(property);
            else if (property.Name.Equals("reverseEnabled", StringComparison.OrdinalIgnoreCase)) reverse = ReadBoolean(property);
            else if (property.Name.Equals("steeringEnabled", StringComparison.OrdinalIgnoreCase)) steering = ReadBoolean(property);
            else if (property.Name.Equals("probeOnly", StringComparison.OrdinalIgnoreCase)) legacyProbe = ReadBoolean(property);
        }
        return new(torque ?? !legacyProbe, reverse ?? !legacyProbe, steering ?? !legacyProbe);
    }

    private static bool ReadBoolean(JsonProperty property) => property.Value.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => throw new JsonException(property.Name + " must be a boolean."),
    };

    public override void Write(Utf8JsonWriter writer, VehicleDrivetrainPreference value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteBoolean("torqueEnabled", value.TorqueEnabled);
        writer.WriteBoolean("reverseEnabled", value.ReverseEnabled);
        writer.WriteBoolean("steeringEnabled", value.SteeringEnabled);
        writer.WriteEndObject();
    }
}
