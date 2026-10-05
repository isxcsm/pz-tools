using PzTools.App.Core;

namespace PzTools.Backup.Tests;

/// <summary>A script a recording names, found again on this PC from the path the recording keeps.</summary>
public sealed class ScriptFileLocatorTests
{
    [Fact]
    public void Scripts_AreFoundUnderTheirOwnFolders_OrNotAtAll()
    {
        using var temp = new TempDirectory();
        string Write(params string[] parts)
        {
            var path = temp.GetPath(parts);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "-- script");
            return path;
        }
        var workshop = Write("library", "steamapps", "workshop", "content", "108600", "3778868211", "mods", "Fridges", "42", "media", "lua", "client", "Core.lua");
        var own = Write("Zomboid", "mods", "Mine", "media", "lua", "shared", "Mine.lua");
        var game = Write("ProjectZomboid", "media", "lua", "client", "ISUI", "ISPanel.lua");
        Write("Zomboid", "secret.lua");
        Write("Zomboid", "mods", "Mine", "run.exe");
        var roots = new ScriptFileLocator.Roots(temp.GetPath("Zomboid"),
            [temp.GetPath("other-library"), temp.GetPath("library", "steamapps", "workshop", "content", "108600")], temp.GetPath("ProjectZomboid"));

        Assert.Equal(workshop, ScriptFileLocator.Locate("workshop/3778868211/mods/Fridges/42/media/lua/client/Core.lua", roots));
        Assert.Equal(own, ScriptFileLocator.Locate("mods/Mine/media/lua/shared/Mine.lua", roots));
        Assert.Equal(game, ScriptFileLocator.Locate("media/lua/client/ISUI/ISPanel.lua", roots));
        // Not on this PC: a mod removed, or a recording made elsewhere.
        Assert.Null(ScriptFileLocator.Locate("workshop/1/mods/Gone/media/lua/client/Gone.lua", roots));
        Assert.Null(ScriptFileLocator.Locate("Gone.lua", roots));
        // A recording handed on by someone else names nothing outside those folders, and nothing but a script.
        Assert.Null(ScriptFileLocator.Locate("mods/../secret.lua", roots));
        Assert.Null(ScriptFileLocator.Locate("mods/Mine/run.exe", roots));
        Assert.Null(ScriptFileLocator.Locate("workshop/../../Zomboid/mods/Mine/media/lua/shared/Mine.lua", roots));
    }
}
