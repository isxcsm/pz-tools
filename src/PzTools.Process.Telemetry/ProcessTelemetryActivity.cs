using PzTools.Process.Contracts;

namespace PzTools.Process.Telemetry;

public static class ProcessTelemetryActivity
{
    public const string FileName = "telemetry.active";

    public static FileStream Acquire(string identity, string component)
    {
        var directory = ComponentRuntimePaths.GetComponentDirectory(identity, component);
        Directory.CreateDirectory(directory);
        return new FileStream(Path.Combine(directory, FileName), FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.Read);
    }

    public static bool IsActive(string identity, string component)
    {
        var path = Path.Combine(ComponentRuntimePaths.GetComponentDirectory(identity, component), FileName);
        try
        {
            if (!File.Exists(path)) return false;
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None);
            return false;
        }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
        catch (IOException) { return true; }
        catch (UnauthorizedAccessException) { return true; }
    }
}
