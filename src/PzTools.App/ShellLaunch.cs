namespace PzTools.App;

/// <summary>
/// Opens files, folders and links for the player, never with this app's administrator rights. Everything goes through
/// the Explorer already running for the player: a new explorer.exe hands its request to that one, so what opens (an
/// editor, a browser, VS Code) runs as the player does. Explorer is named by its full path, so no explorer.exe in this
/// app's folder or the current one could stand in for it.
/// </summary>
internal static class ShellLaunch
{
    private static string Explorer => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");

    /// <summary>A file in the program it opens with, a folder in Explorer, a link in the browser or its app.</summary>
    public static void Open(string target) => Start($"\"{target}\"");

    /// <summary>The folder a file is in, with the file selected.</summary>
    public static void Select(string path) => Start($"/select,\"{path}\"");

    /// <summary>
    /// A Lua file in VS Code at a line, through its own link (<c>vscode://file/…:line</c>) so that Explorer starts it:
    /// started from here directly it would run as administrator, from a folder the player's own programs can write.
    /// </summary>
    public static void OpenInCode(string path, int line)
    {
        // Each folder's name escaped (a space, a #), the drive's colon kept: VS Code reads C:/… as the path.
        var parts = path.Replace('\\', '/').Split('/');
        var escaped = string.Join("/", parts.Select((part, index) => index == 0 && part.EndsWith(':') ? part : Uri.EscapeDataString(part)));
        Open("vscode://file/" + escaped + (line > 0 ? ":" + line.ToString(System.Globalization.CultureInfo.InvariantCulture) : ""));
    }

    private static void Start(string arguments) =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Explorer) { Arguments = arguments, UseShellExecute = false })?.Dispose();
}
