using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PzTools.App.Core;

/// <summary>Files of the app folder that are not as published: missing, or with other contents.</summary>
public sealed record InstallProblem(IReadOnlyList<string> Missing, IReadOnlyList<string> Changed)
{
    /// <summary>The files by name, for the log: the first few of each kind, and how many more.</summary>
    public string Describe()
    {
        static string List(IReadOnlyList<string> files) =>
            string.Join(", ", files.Take(10)) + (files.Count > 10 ? $" (+{files.Count - 10})" : "");
        var parts = new List<string>();
        if (Missing.Count > 0) parts.Add($"missing {Missing.Count}: {List(Missing)}");
        if (Changed.Count > 0) parts.Add($"changed {Changed.Count}: {List(Changed)}");
        return string.Join("; ", parts);
    }
}

/// <summary>
/// Whether the app folder holds the files it was published with. The release is a ZIP, and the usual way to break it
/// is to extract a new one over the old one while the app runs: the files in use keep the old version, the rest take
/// the new, and the app starts with workers of two versions. A published app carries the list of its files with their
/// sizes and SHA-256 (<see cref="ManifestName"/>, written by <c>publish-app.ps1</c>); a development build has none and
/// is not checked.
/// <para>
/// Every file is read and hashed once per published folder: when the list is new to this folder (a first start, or a
/// release extracted over it, which always replaces the list). After that a start only looks for missing files and
/// sizes. Files the list does not name are left alone: nothing the app runs loads a file because it is in its folder,
/// so one left from an older release is not used.
/// </para>
/// </summary>
public static class InstallIntegrity
{
    public const string ManifestName = "pztools-files.txt";
    private const string Header = "PZTOOLS-FILES\t1";

    /// <summary>
    /// Checks <paramref name="appDirectory"/> against its list: what is wrong with it, or none when it is whole, has no
    /// list (a development build), or its list cannot be read. A folder found whole is remembered in
    /// <paramref name="statePath"/>.
    /// </summary>
    public static InstallProblem? Check(string appDirectory, string statePath, CancellationToken cancellationToken = default)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(appDirectory));
        string manifest;
        try { manifest = File.ReadAllText(Path.Combine(root, ManifestName)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
        var entries = Parse(manifest);
        if (entries is null) return null;
        var listHash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(manifest)));
        bool known = Read(statePath) is { } state && state.Hash == listHash
            && string.Equals(state.Directory, root, StringComparison.OrdinalIgnoreCase);
        var missing = new List<string>();
        var changed = new List<string>();
        var unread = false;
        foreach (var (path, size, hash) in entries)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = new FileInfo(Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar)));
            if (!file.Exists) { missing.Add(path); continue; }
            if (file.Length != size) { changed.Add(path); continue; }
            if (known) continue;
            try
            {
                using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
                    1 << 16, FileOptions.SequentialScan);
                if (!string.Equals(Convert.ToHexStringLower(SHA256.HashData(stream)), hash, StringComparison.OrdinalIgnoreCase))
                    changed.Add(path);
            }
            // A file another program holds open without sharing (a scanner, briefly) is not evidence of a broken
            // folder: it is read again at the next start, as the folder is not remembered as whole.
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { unread = true; }
        }
        if (missing.Count > 0 || changed.Count > 0) return new(missing, changed);
        if (!known && !unread) Remember(statePath, root, listHash);
        return null;
    }

    /// <summary>The list's entries: relative path with forward slashes, size, SHA-256; none when it is not one.</summary>
    public static IReadOnlyList<(string Path, long Size, string Hash)>? Parse(string manifest)
    {
        var lines = manifest.Replace("\r\n", "\n").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length == 0 || !lines[0].StartsWith(Header, StringComparison.Ordinal)) return null;
        var entries = new List<(string, long, string)>(lines.Length - 1);
        foreach (var line in lines.Skip(1))
        {
            var fields = line.Split('\t');
            if (fields.Length != 3 || fields[0].Length != 64
                || !long.TryParse(fields[1], NumberStyles.None, CultureInfo.InvariantCulture, out var size)
                || fields[2].Length == 0 || fields[2].Contains("..", StringComparison.Ordinal) || Path.IsPathRooted(fields[2]))
                return null;
            entries.Add((fields[2], size, fields[0]));
        }
        return entries;
    }

    private sealed record State(string Directory, string Hash);

    private static State? Read(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<State>(File.ReadAllText(path)) : null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    private static void Remember(string path, string directory, string hash)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            File.WriteAllText(path, JsonSerializer.Serialize(new State(directory, hash)));
        }
        // Not remembered, the folder is only read whole again at the next start.
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
