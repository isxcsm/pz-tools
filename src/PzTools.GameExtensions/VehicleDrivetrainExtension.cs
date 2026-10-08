namespace PzTools.GameExtensions;

/// <summary>
/// The vehicle driving improvements as the app knows them (docs/design/vehicle-drivetrain.md): their id, their four
/// switches, the configuration the game's module runs with, and how earlier versions saved the switches.
/// </summary>
public static class VehicleDrivetrainExtension
{
    public const string Id = "pztools.vehicle-drivetrain";

    // The switches' keys in settings.json: the names the vehicle's own preference object gave them before options were
    // kept by key (VehicleDrivetrainLegacyOptions).
    public const string Torque = "torqueEnabled", Reverse = "reverseEnabled", Steering = "steeringEnabled",
        AreaLight = "areaLightEnabled";

    public static ExtensionDescriptor Descriptor { get; } = new()
    {
        Id = Id,
        Glyph = "", // car
        // The light is an addition to the game rather than a correction of its driving, so it has its own
        // switch apart from the three driving options. Like them it starts on.
        Options =
        [
            new(Torque, "VehicleDrivetrain.Torque", "VehicleDrivetrain.TorqueDescription"),
            new(Reverse, "VehicleDrivetrain.Reverse", "VehicleDrivetrain.ReverseDescription"),
            new(Steering, "VehicleDrivetrain.Steering", "VehicleDrivetrain.SteeringDescription"),
            new(AreaLight, "VehicleDrivetrain.AreaLight", "VehicleDrivetrain.AreaLightDescription"),
        ],
        // Its safe point (docs/design/vehicle-drivetrain.md#safe-point-for-applying-changes), in the player's words.
        SafeBoundaryHintKey = "GameExtensions.ApplyWhenSafe",
        Configuration = new Tuning(),
        LegacyOptions = VehicleDrivetrainLegacyOptions.Read,
    };

    /// <summary>The tuning key each switch sets; the switches override both TOML files.</summary>
    internal static string TuningKey(string option) => option switch
    {
        Torque => "torque_enabled",
        Reverse => "reverse_enabled",
        Steering => "steering_enabled",
        AreaLight => "area_light_enabled",
        _ => throw new ArgumentOutOfRangeException(nameof(option)),
    };

    private sealed class Tuning : IContinuousConfiguration
    {
        public IReadOnlyDictionary<string, string> Load(string bridgeDirectory, string runtimeRoot, ExtensionPreference preference) =>
            VehicleDrivetrainConfiguration.Load(bridgeDirectory, runtimeRoot, preference);

        public IReadOnlyList<string> Inputs(string bridgeDirectory, string runtimeRoot) =>
            [VehicleDrivetrainConfiguration.PackagedPath(bridgeDirectory), VehicleDrivetrainConfiguration.OverridePath(runtimeRoot)];
    }
}
