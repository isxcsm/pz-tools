namespace PzTools.GameExtensions;

public enum ExtensionActivationKind { Unsupported, PerSave, Continuous }

/// <summary>The supported activation contract comes from capability metadata, not a module's identity.</summary>
public static class ExtensionCapabilities
{
    public const string SavePreparation = "save.prepare.v1";
    public const string VehicleDrivetrain = "vehicle.drivetrain.v1";

    public static ExtensionActivationKind Classify(IReadOnlyList<string>? capabilities) =>
        capabilities is not { Count: 1 } ? ExtensionActivationKind.Unsupported : capabilities[0] switch
        {
            SavePreparation => ExtensionActivationKind.PerSave,
            VehicleDrivetrain => ExtensionActivationKind.Continuous,
            _ => ExtensionActivationKind.Unsupported,
        };
}
