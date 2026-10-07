namespace PzTools.App.Core;

/// <summary>
/// What a single preference edit changes, merged with the latest committed extension settings: the main switch, the
/// version override, or otherwise one of the extension's own switches by its key (ExtensionDescriptor.Options). No
/// switch's key takes one of these names.
/// </summary>
public static class GameExtensionSetting
{
    public const string Enabled = "enabled";
    public const string ForceVersion = "forceVersion";
}
