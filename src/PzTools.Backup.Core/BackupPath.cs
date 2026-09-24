namespace PzTools.Backup.Core;

public static class BackupPath
{
    public static string NormalizeRelative(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);

        var slashNormalized = path.Replace('\\', '/');
        if (Path.IsPathRooted(path)
            || Path.IsPathRooted(slashNormalized)
            || slashNormalized.StartsWith("/", StringComparison.Ordinal))
        {
            throw new ArgumentException("A non-empty relative path is required.", nameof(path));
        }

        var normalized = slashNormalized.Trim('/');
        if (normalized.Length == 0)
        {
            throw new ArgumentException("A non-empty relative path is required.", nameof(path));
        }

        foreach (var segment in normalized.Split('/'))
        {
            if (segment is "" or "." or "..")
            {
                throw new ArgumentException("The path must not contain empty, current, or parent segments.", nameof(path));
            }
        }

        return normalized;
    }

    public static string GetRelative(string rootPath, string fullPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(fullPath);

        var relative = Path.GetRelativePath(rootPath, fullPath);
        return NormalizeRelative(relative);
    }
}
