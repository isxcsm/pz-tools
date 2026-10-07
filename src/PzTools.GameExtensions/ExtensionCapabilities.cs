namespace PzTools.GameExtensions;

public enum ExtensionActivationKind { Unsupported, PerSave, Continuous }

/// <summary>The supported activation contract comes from capability metadata, not a module's identity.</summary>
public static class ExtensionCapabilities
{
    public const string SavePreparation = "save.prepare.v1";
    /// <summary>Runs every frame for as long as it is on, with a flat key/value configuration.</summary>
    public const string Continuous = "continuous.v1";
    /// <summary>The name the first catalogue gave the continuous capability; read as <see cref="Continuous"/>.</summary>
    public const string LegacyContinuous = "vehicle.drivetrain.v1";

    public static ExtensionActivationKind Classify(IReadOnlyList<string>? capabilities) =>
        capabilities is not { Count: 1 } ? ExtensionActivationKind.Unsupported : capabilities[0] switch
        {
            SavePreparation => ExtensionActivationKind.PerSave,
            Continuous or LegacyContinuous => ExtensionActivationKind.Continuous,
            _ => ExtensionActivationKind.Unsupported,
        };
}
