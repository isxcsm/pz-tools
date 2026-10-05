using Windows.UI.ViewManagement;

namespace PzTools.App;

/// <summary>
/// Whether Windows' "Animation effects" is on. When it is off, the motion the app adds itself (selection bars that
/// stretch to the new row, rows that rise into a list) is left out and everything takes its place at once, as the
/// system's own controls do.
/// </summary>
internal static class SystemMotion
{
    private static readonly UISettings settings = new();

    // Read each time: the setting can change while the app runs.
    public static bool Enabled => settings.AnimationsEnabled;
}
