using PzTools.GameExtensions;

namespace PzTools.Backup.Tests;

/// <summary>The vehicle extension's four switches as a saved preference keeps them, for tests.</summary>
internal static class VehicleOptions
{
    public static IReadOnlyDictionary<string, bool> Of(bool torque = true, bool reverse = true, bool steering = true, bool areaLight = true) =>
        new Dictionary<string, bool>(StringComparer.Ordinal)
        {
            [VehicleDrivetrainExtension.Torque] = torque,
            [VehicleDrivetrainExtension.Reverse] = reverse,
            [VehicleDrivetrainExtension.Steering] = steering,
            [VehicleDrivetrainExtension.AreaLight] = areaLight,
        };

    /// <summary>Asserts both say the same, whichever dictionary holds them and in whatever order.</summary>
    public static void AssertSame(IReadOnlyDictionary<string, bool>? expected, IReadOnlyDictionary<string, bool>? actual) =>
        Assert.True(ExtensionPreference.SameOptions(expected, actual),
            $"Expected {Describe(expected)}, got {Describe(actual)}.");

    private static string Describe(IReadOnlyDictionary<string, bool>? options) => options is null ? "none"
        : string.Join(", ", options.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => $"{pair.Key}={pair.Value}"));
}
