using System.Text;
using System.Text.RegularExpressions;

namespace PzTools.App.Core;

/// <summary>What <see cref="GameMemoryOptimizer"/> found in the optimizer's settings file before the app changed it: a
/// value, or none when the key was not there. Kept so that giving the game's own memory back puts them back.</summary>
public sealed record OptimizerOriginal(string? Heap, string? Fixed);

/// <summary>
/// A mod that sets the game's heap itself (PZ Optimize does, at every start of the game: it takes the heap options out of
/// <c>ProjectZomboid64.json</c>, remembers them in a <c>-Dpzopt.heap=&lt;maximum&gt;,&lt;starting&gt;,&lt;pre-touch&gt;</c> entry of
/// <c>vmArgs</c>, and writes its own formula's heap) would undo the player's memory setting each time. The memory setting
/// therefore also tells such a mod what heap to use, in the mod's own settings file (<c>pzopt.properties</c> in the game's
/// folder; a Java properties file of <c>key=value</c> lines, read at the game's start): its <c>gcHeap</c> is the heap in
/// megabytes, and <c>gcHeapFixed</c> makes the starting heap equal to it. Both mean what their names say for that mod only;
/// a game without the mod never gets the file. Nothing here names a version of the mod, and the file's other keys, its
/// comments and its layout stay as they were, byte for byte (the format is ISO 8859-1).
/// </summary>
internal static partial class GameMemoryOptimizer
{
    public const string FileName = "pzopt.properties";
    public const string HeapKey = "gcHeap", FixedKey = "gcHeapFixed";
    private const string Folder = "pzopt";

    /// <summary>Whether the game's folder has the mod (its folder), or the settings file that mod reads.</summary>
    public static bool Present(string gameFolder) =>
        Directory.Exists(Path.Combine(gameFolder, Folder)) || File.Exists(Path.Combine(gameFolder, FileName));

    /// <summary>The two keys as the file has them now (none for a key, or a file, that is not there).</summary>
    public static OptimizerOriginal Read(string gameFolder)
    {
        var text = ReadText(Path.Combine(gameFolder, FileName)) ?? "";
        return new(Get(text, HeapKey), Get(text, FixedKey));
    }

    /// <summary>Tells the mod to use <paramref name="megabytes"/> as both heaps. Written beside the file and moved over it.</summary>
    /// <exception cref="IOException">The file cannot be written.</exception>
    public static void Hold(string gameFolder, int megabytes)
    {
        var path = Path.Combine(gameFolder, FileName);
        var text = Set(Set(ReadText(path) ?? "", HeapKey, megabytes.ToString(System.Globalization.CultureInfo.InvariantCulture)), FixedKey, "true");
        if (text != ReadText(path)) WriteText(path, text);
    }

    /// <summary>
    /// Gives the keys their earlier values back, each only if it still holds what <see cref="Hold"/> wrote (a value the
    /// player has set since is theirs). A file left with nothing in it, which the app made, is removed.
    /// </summary>
    public static void Release(string gameFolder, OptimizerOriginal original, int heldMegabytes)
    {
        var path = Path.Combine(gameFolder, FileName);
        if (ReadText(path) is not { } text) return;
        if (Get(text, HeapKey) == heldMegabytes.ToString(System.Globalization.CultureInfo.InvariantCulture)) text = Set(text, HeapKey, original.Heap);
        if (Get(text, FixedKey) == "true") text = Set(text, FixedKey, original.Fixed);
        if (text.Trim().Length == 0) File.Delete(path);
        else WriteText(path, text);
    }

    // ---- The properties text ----

    // A line of the file: its text, and the line ending after it (none for a last line without one).
    private static List<(string Text, string End)> Lines(string text)
    {
        var lines = new List<(string, string)>();
        int start = 0;
        for (int index = 0; index < text.Length; index++)
        {
            if (text[index] != '\r' && text[index] != '\n') continue;
            int end = index + (text[index] == '\r' && index + 1 < text.Length && text[index + 1] == '\n' ? 2 : 1);
            lines.Add((text[start..index], text[index..end]));
            start = end;
            index = end - 1;
        }
        if (start < text.Length) lines.Add((text[start..], ""));
        return lines;
    }

    // The line's key and the value as the loader reads it (after the separator, white space before it dropped), or none for
    // a comment, a blank line or a line without a key.
    [GeneratedRegex(@"^[ \t\f]*(?<key>[^ \t\f=:#!][^ \t\f=:]*)[ \t\f]*(?:[=:][ \t\f]*|[ \t\f]+)?(?<value>.*)$")]
    private static partial Regex Entry();

    private static (string Key, string Value)? Parse(string line)
    {
        var match = Entry().Match(line);
        return match.Success ? (match.Groups["key"].Value, match.Groups["value"].Value.TrimEnd(' ', '\t', '\f')) : null;
    }

    /// <summary>The value of <paramref name="key"/> as the file's last line for it gives it; none when it has none.</summary>
    public static string? Get(string text, string key)
    {
        string? found = null;
        foreach (var (line, _) in Lines(text))
            if (Parse(line) is { } entry && entry.Key == key) found = entry.Value;
        return found;
    }

    /// <summary>
    /// The text with <paramref name="key"/> set to <paramref name="value"/> (removed when none): the last line for it is
    /// replaced, else the key is added at the end; every other line is as it was.
    /// </summary>
    public static string Set(string text, string key, string? value)
    {
        var lines = Lines(text);
        int last = lines.FindLastIndex(line => Parse(line.Text) is { } entry && entry.Key == key);
        if (value is null)
        {
            lines.RemoveAll(line => Parse(line.Text) is { } entry && entry.Key == key);
        }
        else if (last >= 0)
        {
            var (old, end) = lines[last];
            var indent = old[..(old.Length - old.TrimStart(' ', '\t', '\f').Length)];
            lines[last] = (indent + key + "=" + value, end);
        }
        else
        {
            var ending = lines.Select(line => line.End).FirstOrDefault(end => end.Length > 0) ?? "\r\n";
            if (lines.Count > 0 && lines[^1].End.Length == 0) lines[^1] = (lines[^1].Text, ending);
            lines.Add((key + "=" + value, ending));
        }
        return string.Concat(lines.Select(line => line.Text + line.End));
    }

    private static string? ReadText(string path)
    {
        try { return File.Exists(path) ? Encoding.Latin1.GetString(File.ReadAllBytes(path)) : null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    private static void WriteText(string path, string text)
    {
        var temporary = path + ".pztools-" + Guid.NewGuid().ToString("N")[..8];
        try
        {
            File.WriteAllBytes(temporary, Encoding.Latin1.GetBytes(text));
            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(temporary); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
            throw;
        }
    }
}
