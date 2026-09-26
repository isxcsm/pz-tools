using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Zomboid.State;

public sealed record RuntimeSaveIdentity(string SaveId, string SourcePath);

/// <summary>The game-specific Saves/mode/world layout does not belong to scheduling or transport.</summary>
public static class RuntimeSaveResolver
{
    public static RuntimeSaveIdentity? Resolve(RuntimeSnapshot snapshot, string savesRoot)
    {
        if (!snapshot.IsWorldReady) return null;
        var path = Path.GetFullPath(snapshot.SavePath!);
        var relative = Path.GetRelativePath(Path.GetFullPath(savesRoot), path).Replace('\\', '/');
        var parts = relative.Split('/');
        if (parts.Length != 2 || parts.Any(p => p is "" or "." or "..") || Path.IsPathRooted(relative)) return null;
        return new(relative, path);
    }
}