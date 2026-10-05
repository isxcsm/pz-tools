namespace PzTools.App.Core;

/// <summary>
/// Where a script a recording names lies on this PC. A recording keeps a script's path without the folders above the
/// game or the mod (they hold the player's name): <c>workshop/&lt;item&gt;/mods/&lt;mod&gt;/…</c> for a Workshop mod,
/// <c>mods/&lt;mod&gt;/…</c> for a mod in the player's own folder, <c>media/…</c> for the game's own scripts. Found
/// again under this PC's folders, or not at all: a recording made elsewhere, or a mod since removed.
/// </summary>
public static class ScriptFileLocator
{
    /// <param name="UserFolder">The game's folder in the player's profile (holding Saves and mods).</param>
    /// <param name="WorkshopFolders">Each Steam library's Workshop folder for the game (…/workshop/content/108600).</param>
    /// <param name="GameFolder">The game's install folder.</param>
    public sealed record Roots(string? UserFolder, IReadOnlyList<string> WorkshopFolders, string? GameFolder);

    /// <summary>The script's full path on this PC, or null where it is not there or the path is not a script's.</summary>
    public static string? Locate(string relative, Roots roots)
    {
        if (string.IsNullOrWhiteSpace(relative)) return null;
        var path = relative.Replace('\\', '/');
        // Only scripts are opened: a recording handed on by someone else must not name anything else to run.
        // A colon past the start is a drive or a file's stream ("a.txt:b.lua"), never part of a script's own path.
        if (!path.EndsWith(".lua", StringComparison.OrdinalIgnoreCase) || path.Contains(':')) return null;
        IEnumerable<(string Root, string Under)> candidates = path switch
        {
            // Each kind only under its own folder (a mod's under mods, the game's under media): a path that climbs
            // out with ".." finds nothing, even another script beside it. Folder names in any case, as Windows reads them.
            _ when path.StartsWith("workshop/", StringComparison.OrdinalIgnoreCase) && path.Split('/') is [_, var item, var mods, .. var rest]
                && mods.Equals("mods", StringComparison.OrdinalIgnoreCase) && item.Length > 0 && item.All(char.IsAsciiDigit)
                => roots.WorkshopFolders.Select(folder => (Path.Combine(folder, item, "mods"), string.Join('/', rest))),
            _ when path.StartsWith("mods/", StringComparison.OrdinalIgnoreCase)
                => roots.UserFolder is { } user ? [(Path.Combine(user, "mods"), path["mods/".Length..])] : [],
            _ when path.StartsWith("media/", StringComparison.OrdinalIgnoreCase)
                => roots.GameFolder is { } game ? [(Path.Combine(game, "media"), path["media/".Length..])] : [],
            _ => [],
        };
        foreach (var (root, under) in candidates)
            if (Inside(root, under) is { } full && File.Exists(full)) return full;
        return null;
    }

    // The path under the root, or null when it would lead out of it ("..", a drive, a rooted path).
    private static string? Inside(string root, string rest)
    {
        try
        {
            var bounds = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
            var full = Path.GetFullPath(Path.Combine(bounds, rest.Replace('/', Path.DirectorySeparatorChar)));
            return full.StartsWith(bounds, StringComparison.OrdinalIgnoreCase) ? full : null;
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
    }

    /// <summary>This PC's folders: the player's game folder beside the saves, Steam's libraries, the game's install.</summary>
    public static Roots Current(string savesRoot)
    {
        var user = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(Path.GetFullPath(savesRoot)));
        var workshop = new List<string>();
        if (OperatingSystem.IsWindows()
            && Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) is string steam)
            foreach (var library in GameMemory.SteamLibraries(steam))
                workshop.Add(Path.Combine(library, "steamapps", "workshop", "content", "108600"));
        var launcher = GameMemory.Running() ?? GameMemory.Installed();
        return new(user, workshop, launcher is null ? null : Path.GetDirectoryName(launcher));
    }

    /// <summary>VS Code on this PC, which opens a file at a line; null where it is not installed.</summary>
    public static string? VisualStudioCode()
    {
        static string? Existing(string? path) => path is not null && File.Exists(path) ? path : null;
        if (Existing(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs", "Microsoft VS Code", "Code.exe")) is { } user) return user;
        if (Existing(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Microsoft VS Code", "Code.exe")) is { } machine)
            return machine;
        // Installed elsewhere, with its command on the PATH: bin\code.cmd beside Code.exe's folder.
        foreach (var folder in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                if (File.Exists(Path.Combine(folder, "code.cmd"))
                    && Existing(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(folder))!, "Code.exe")) is { } found) return found;
            }
            catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { }
        }
        return null;
    }
}
