using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using PzTools.Process.Contracts;

namespace PzTools.App.Core;

/// <summary>A heap the player can give the game, in megabytes; one may be marked as the one suggested for this PC.</summary>
public sealed record GameMemoryChoice(int Megabytes, bool Recommended);

public enum GameMemoryStatus
{
    /// <summary>Not looked for yet.</summary>
    Unknown,
    /// <summary>The game's launcher file was not found: no game installed through Steam, and none running.</summary>
    NotFound,
    /// <summary>The file is not as expected (no single heap option): it is left alone.</summary>
    Unsupported,
    /// <summary>The game's own setting stands.</summary>
    Default,
    /// <summary>The heap the player chose is in the file.</summary>
    Applied,
    /// <summary>The player chose a heap, and the file no longer has it: a game update or a file check put it back.</summary>
    Reverted,
}

/// <param name="MaximumMegabytes">The heap the game gets at its next start, as its file says.</param>
/// <param name="DefaultMegabytes">The game's own heap: the file's before the first change, or now while unchanged.</param>
/// <param name="ChosenMegabytes">The heap the player chose; none while the game's own stands.</param>
/// <param name="InitialMegabytes">The heap the game starts with (<c>-Xms</c>), as its file says; none when the file has none.</param>
public sealed record GameMemoryState(GameMemoryStatus Status, string? ConfigPath = null, int? MaximumMegabytes = null,
    int? DefaultMegabytes = null, int? ChosenMegabytes = null, int? InitialMegabytes = null)
{
    /// <summary>
    /// The file asks for a starting heap above the maximum: the Java runtime refuses to start, and the game never opens.
    /// A tool that rewrites only one of the two options does this (PZ Optimize lowered <c>-Xmx</c> and left <c>-Xms</c>).
    /// </summary>
    public bool StartsTooLarge => InitialMegabytes > MaximumMegabytes;
}

/// <summary>Why the heap could not be changed: <c>not-found</c>, <c>unsupported</c> or <c>unwritable</c>.</summary>
public sealed class GameMemoryException(string code, string message, Exception? inner = null) : Exception(message, inner)
{
    public string Code { get; } = code;
}

/// <summary>
/// The game's memory: the most its Java heap may grow to (<c>-Xmx</c>), from the launcher's own file
/// (<c>ProjectZomboid64.json</c> in the game folder). By default the game gets 3 GB, which a game with many mods fills,
/// and then stalls while memory is freed. Changing it there takes a careful text edit most players get wrong, so the
/// app does it: only the heap options change, everything else in the file stays as written.
/// <para>
/// The chosen heap is also the starting one (<c>-Xms</c>): the game holds its memory from the start, rather than asking
/// Windows for more, and giving it back, as it goes. The choices are at most half of this PC's memory, so holding all of
/// it from the start always leaves Windows and other programs theirs.
/// </para>
/// <para>
/// A game update, Steam's file check or another tool (PZ Optimize rewrites the heap options itself) changes the file:
/// the choice is kept here, and a file without it, in either option, is <see cref="GameMemoryStatus.Reverted"/>, for the
/// player to apply again with one press. Some tools change only one of the two options and leave a starting heap above
/// the maximum, which the Java runtime refuses (<see cref="GameMemoryState.StartsTooLarge"/>): that is reported whether
/// or not the player chose a heap, and is repaired by applying the choice again, or by the game default, which makes the
/// starting heap the maximum. A separate file the launcher
/// would read instead (<c>ProjectZomboid64.site.json</c>) would survive updates, but it replaces the whole file: after an
/// update that changes other options, the game would start with the old ones.
/// </para>
/// </summary>
public sealed partial class GameMemory
{
    public const string ConfigFileName = "ProjectZomboid64.json";

    /// <summary>
    /// Whether a path names the game's launch file: on a local drive (C:\…, no share or device path), ending in its
    /// name (a stream of it would not).
    /// </summary>
    internal static bool IsLaunchFile(string path) =>
        path.Length > 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] is '\\' or '/'
        && string.Equals(Path.GetFileName(path), ConfigFileName, StringComparison.OrdinalIgnoreCase);
    private const string SteamAppId = "108600";
    private static readonly int[] Steps = [4096, 6144, 8192, 12288, 16384, 24576, 32768];

    private readonly string statePath;
    private readonly Func<string?> locate, running;
    private readonly SemaphoreSlim gate = new(1, 1);
    private Saved saved;
    private GameMemoryState state = new(GameMemoryStatus.Unknown);

    /// <param name="statePath">Where the choice is kept, with the game's own heap from before it.</param>
    /// <param name="locate">Finds the launcher file of a game not running; by default in Steam's libraries.</param>
    /// <param name="installedBytes">This PC's memory; by default as Windows reports it.</param>
    /// <param name="running">The running game's launcher file; by default from its process, unless
    /// <paramref name="locate"/> is given.</param>
    public GameMemory(string statePath, Func<string?>? locate = null, long? installedBytes = null, Func<string?>? running = null)
    {
        this.statePath = Path.GetFullPath(statePath);
        this.locate = locate ?? Installed;
        this.running = running ?? (locate is null ? Running : () => null);
        saved = Read(this.statePath);
        Choices = ChoicesFor(installedBytes ?? InstalledMemory());
    }

    /// <summary>Raised after the state changed, on whichever thread changed it.</summary>
    public event Action? Changed;

    public GameMemoryState State => state;

    /// <summary>The heaps this PC can give the game, smallest first.</summary>
    public IReadOnlyList<GameMemoryChoice> Choices { get; }

    /// <summary>
    /// The heaps up to half of <paramref name="installedBytes"/>; 6 GB is suggested from 16 GB of memory and 8 GB from
    /// 32 GB, which most games with mods do not outgrow. Below 16 GB none is: the game's own may be the better one.
    /// </summary>
    public static IReadOnlyList<GameMemoryChoice> ChoicesFor(long installedBytes)
    {
        // Windows reports a little under what is fitted (64 GB shows as 63.9): round to the whole gigabyte.
        var gigabytes = (int)Math.Round(installedBytes / (1024.0 * 1024 * 1024));
        var recommended = gigabytes >= 32 ? 8192 : gigabytes >= 16 ? 6144 : 0;
        return Steps.Where(megabytes => megabytes <= gigabytes * 1024 / 2)
            .Select(megabytes => new GameMemoryChoice(megabytes, megabytes == recommended)).ToArray();
    }

    /// <summary>Reads the game's file again; <see cref="Changed"/> follows when what it says has changed.</summary>
    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        GameMemoryState next;
        await gate.WaitAsync(cancellationToken);
        try { next = await Task.Run(Look, cancellationToken); }
        finally { gate.Release(); }
        Publish(next);
    }

    /// <summary>
    /// Gives the game <paramref name="megabytes"/> from its next start, or its own heap back when none. A game running
    /// now keeps what it started with.
    /// </summary>
    /// <exception cref="GameMemoryException">The file was not found, is not as expected, or cannot be written.</exception>
    public async Task ApplyAsync(int? megabytes, CancellationToken cancellationToken = default)
    {
        GameMemoryState next;
        await gate.WaitAsync(cancellationToken);
        try { next = await Task.Run(() => Change(megabytes), cancellationToken); }
        finally { gate.Release(); }
        Publish(next);
    }

    private void Publish(GameMemoryState next)
    {
        if (next == state) return;
        state = next;
        Changed?.Invoke();
    }

    private GameMemoryState Look()
    {
        var path = Find();
        if (path is null) return new(GameMemoryStatus.NotFound, ChosenMegabytes: saved.Chosen);
        (int? Maximum, int? Initial) heap;
        try { heap = ReadHeap(File.ReadAllText(path)); }
        catch (Exception error) when (error is FormatException or JsonException)
        { return new(GameMemoryStatus.Unsupported, path, ChosenMegabytes: saved.Chosen); }
        // Held for a moment (Steam writing it, a scanner): what was known stands until the next look.
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { return state.Status == GameMemoryStatus.Unknown ? new(GameMemoryStatus.Unknown, path, ChosenMegabytes: saved.Chosen) : state; }
        if (saved.Chosen is not { } chosen) return new(GameMemoryStatus.Default, path, heap.Maximum, heap.Maximum, InitialMegabytes: heap.Initial);
        // Either option differing from the choice is a rewrite by something else: a game update, Steam's file check or
        // another tool (PZ Optimize sets the heap itself). Which of them does not matter here.
        bool ours = heap.Maximum == chosen && heap.Initial == chosen;
        return new(ours ? GameMemoryStatus.Applied : GameMemoryStatus.Reverted, path, heap.Maximum,
            ours ? saved.DefaultMaximum ?? heap.Maximum : heap.Maximum, chosen, heap.Initial);
    }

    private GameMemoryState Change(int? megabytes)
    {
        // The choice already made may be applied again even if it is no longer offered (memory taken out of this PC).
        if (megabytes is { } value && value != saved.Chosen && Choices.All(choice => choice.Megabytes != value))
            throw new ArgumentOutOfRangeException(nameof(megabytes), "Not a heap this PC can give the game.");
        var path = Find() ?? throw new GameMemoryException("not-found", "The game's launcher file was not found.");
        string text;
        (int? Maximum, int? Initial) heap;
        try
        {
            text = File.ReadAllText(path);
            heap = ReadHeap(text);
        }
        catch (Exception error) when (error is FormatException or JsonException)
        { throw new GameMemoryException("unsupported", "The game's launcher file is not as expected.", error); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { throw new GameMemoryException("unwritable", "The game's launcher file cannot be read.", error); }
        bool ours = saved.Chosen is { } chosen && heap.Maximum == chosen && heap.Initial == chosen;
        Saved next;
        string? written;
        if (megabytes is { } wanted)
        {
            // The game's own heap is what the file holds before it holds the player's: kept to give back.
            // A starting heap above the maximum is a half-done rewrite by another tool, never the game's own: kept as none.
            // A mod that sets the heap itself (its entry, see SyncOptimizerMarker) put its own in the options: the game's
            // own is what its entry holds. An entry holding the choice (this app made it so) is the mod's heap over the
            // player's, and the game's own is the one kept before.
            var own = OptimizerHeap(text) is { } entry ? (Maximum: (int?)entry.Maximum, entry.Initial) : heap;
            bool overridden = saved.Chosen is { } prior && saved.DefaultMaximum is not null && own.Maximum == prior;
            next = ours || overridden ? saved with { Chosen = wanted }
                : saved with { Chosen = wanted, DefaultMaximum = own.Maximum, DefaultInitial = own.Initial > own.Maximum ? null : own.Initial };
            written = Rewrite(text, wanted, wanted);
            if (!ours) KeepOriginal(text);
        }
        else
        {
            next = saved with { Chosen = null };
            // A file the game put back already holds its own heap. One that asks for a starting heap above the maximum
            // (another tool rewrote one option) is not startable: the starting heap is made the maximum.
            written = ours && saved.DefaultMaximum is { } maximum ? Rewrite(text, maximum, saved.DefaultInitial)
                : heap.Initial > heap.Maximum ? Rewrite(text, heap.Maximum!.Value, heap.Maximum) : null;
        }
        // A mod that sets the heap itself is told the player's (its own settings file), and told no more once the game's own is
        // back. What it had there is kept first, as the game's own heap is.
        var folder = Path.GetDirectoryName(path)!;
        var original = saved.Optimizer;
        bool optimizer = megabytes is not null ? GameMemoryOptimizer.Present(folder) : original is not null;
        if (megabytes is not null && optimizer && original is null) next = next with { Optimizer = GameMemoryOptimizer.Read(folder) };
        else if (megabytes is null) next = next with { Optimizer = null };
        // What is kept first, and the file only once it is: the game's own heap kept nowhere could not be given back,
        // and a file holding the player's heap would then pass for the game's own.
        var before = saved;
        if (!Save(next with { ConfigPath = path }))
        {
            saved = before;
            throw new GameMemoryException("unwritable", "The app's own record of the change cannot be written.");
        }
        if (written is not null && written != text)
        {
            try { Write(path, written, text); }
            catch (GameMemoryException)
            {
                Save(before);
                throw;
            }
        }
        // Best effort: a file that cannot be written leaves the mod to set its own heap, which the next look reports as the
        // setting being undone, and the player applies it again.
        try
        {
            if (megabytes is { } held && optimizer) GameMemoryOptimizer.Hold(folder, held);
            else if (megabytes is null && original is not null && before.Chosen is { } released) GameMemoryOptimizer.Release(folder, original, released);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return Look();
    }

    // Only a file the game reads, in a game folder: the running game's, which its next start reads; else the one
    // remembered while it is there; else the one in Steam's libraries.
    private string? Find()
    {
        var found = Try(running);
        // The remembered path is in a file any program of the player's can write, and this app edits what it names
        // with administrator rights: only ever the game's own launch file, by its name.
        if (found is null && saved.ConfigPath is { } known && IsLaunchFile(known) && File.Exists(known)) return known;
        found ??= Try(locate);
        if (found is not null && found != saved.ConfigPath) Save(saved with { ConfigPath = found });
        return found;

        // Steam's registry key or library list that cannot be read is a game not found, not a failure.
        static string? Try(Func<string?> look)
        {
            try { return look(); }
            catch (Exception error) when (error is System.Security.SecurityException or IOException or UnauthorizedAccessException)
            { return null; }
        }
    }

    // ---- The file's text ----

    [GeneratedRegex("\"-Xm([xs])([0-9]{1,9})([kKmMgG]?)\"")]
    private static partial Regex HeapOption();

    /// <summary>The heap options in the launcher's own list (<c>vmArgs</c>), in megabytes; none when absent.</summary>
    /// <exception cref="FormatException">The file has no list, no maximum heap, or an option twice.</exception>
    public static (int? Maximum, int? Initial) ReadHeap(string json)
    {
        using var document = JsonDocument.Parse(json);
        if (!document.RootElement.TryGetProperty("vmArgs", out var list) || list.ValueKind != JsonValueKind.Array)
            throw new FormatException("No vmArgs list.");
        int? maximum = null, initial = null;
        int maxCount = 0, initialCount = 0;
        foreach (var item in list.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String) continue;
            var match = HeapOption().Match("\"" + item.GetString() + "\"");
            if (!match.Success || match.Length != item.GetString()!.Length + 2) continue;
            var value = Megabytes(match);
            if (match.Groups[1].Value == "x") { maximum = value; maxCount++; }
            else { initial = value; initialCount++; }
        }
        // Every option written in the file must be one of those: a heap option elsewhere (a per-version list) is not
        // edited here, and might win over it.
        if (maxCount != 1 || initialCount > 1 || HeapOption().Count(json) != maxCount + initialCount)
            throw new FormatException("The heap options are not one of each in vmArgs.");
        return (maximum, initial);
    }

    /// <summary>
    /// The file with its maximum heap set to <paramref name="maximum"/> and its starting heap to <paramref name="initial"/>
    /// (removed when none), every other character as it was. A starting heap that was not there goes right after the
    /// maximum, on a line of its own.
    /// </summary>
    public static string Rewrite(string json, int maximum, int? initial)
    {
        ReadHeap(json);
        var newline = json.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";
        var options = HeapOption().Matches(json);
        var max = options.First(option => option.Groups[1].Value == "x");
        var start = options.FirstOrDefault(option => option.Groups[1].Value == "s");
        var text = new StringBuilder(json);
        // From the end, so earlier positions stay valid.
        var edits = new List<(int Index, int Length, string Text)> { (max.Index, max.Length, $"\"-Xmx{maximum}m\"") };
        if (start is not null)
            edits.Add(initial is { } value ? (start.Index, start.Length, $"\"-Xms{value}m\"") : Removal(json, start));
        else if (initial is { } value)
        {
            var lineStart = json.LastIndexOf('\n', max.Index) + 1;
            var indent = json[lineStart..max.Index];
            if (indent.Trim().Length > 0) indent = " ";
            edits.Add((max.Index + max.Length, 0, $",{(indent == " " ? "" : newline)}{indent}\"-Xms{value}m\""));
        }
        foreach (var (index, length, replacement) in edits.OrderByDescending(edit => edit.Index))
            text.Remove(index, length).Insert(index, replacement);
        var result = SyncOptimizerMarker(text.ToString(), maximum, initial);
        // What was written must read back as asked, or nothing is written.
        if (ReadHeap(result) != (maximum, initial)) throw new FormatException("The rewritten file does not read back.");
        return result;
    }

    [GeneratedRegex(@"""-Dpzopt\.heap=([^"",\\]*),([^"",\\]*),([^""\\]*)""")]
    private static partial Regex OptimizerMarker();

    // A mod that sets the heap itself (PZ Optimize) keeps the heap options the file had in an entry of the list, and puts them
    // back before it sets its own at each start. An entry holding the options from before this edit would put them back over
    // it: it is made to hold these. A file without the entry is as it was.
    private static string SyncOptimizerMarker(string json, int maximum, int? initial) =>
        OptimizerMarker().Replace(json, match =>
            $"\"-Dpzopt.heap={maximum}m,{(initial is { } start ? start + "m" : "none")},{match.Groups[3].Value}\"");

    /// <summary>
    /// The heap options the mod's entry holds (what it puts back before it sets its own at each start), in megabytes, the
    /// starting heap none for <c>none</c>; null without the entry, or with a value that is not a heap.
    /// </summary>
    public static (int Maximum, int? Initial)? OptimizerHeap(string json)
    {
        var match = OptimizerMarker().Match(json);
        if (!match.Success || Size(match.Groups[1].Value) is not { } maximum) return null;
        var start = match.Groups[2].Value;
        if (start == "none") return (maximum, null);
        return Size(start) is { } initial ? (maximum, initial) : null;

        static int? Size(string value)
        {
            var option = HeapOption().Match($"\"-Xmx{value}\"");
            return option.Success && option.Length == value.Length + 6 ? Megabytes(option) : null;
        }
    }

    // An option taken out of the list with its separator: the comma after it, or before it when it is last.
    private static (int Index, int Length, string Text) Removal(string json, Match option)
    {
        int end = option.Index + option.Length;
        int after = end;
        while (after < json.Length && char.IsWhiteSpace(json[after])) after++;
        int before = option.Index;
        while (before > 0 && char.IsWhiteSpace(json[before - 1])) before--;
        if (after < json.Length && json[after] == ',') return (before, after + 1 - before, "");
        // Last in the list: the comma before it goes, unless it is the only item.
        return before > 0 && json[before - 1] == ',' ? (before - 1, end - before + 1, "") : (before, end - before, "");
    }

    private static int Megabytes(Match option)
    {
        var number = long.Parse(option.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture);
        var megabytes = option.Groups[3].Value.ToLowerInvariant() switch
        {
            "g" => number * 1024,
            "m" => number,
            "k" => number / 1024,
            _ => number / (1024 * 1024),
        };
        return (int)Math.Clamp(megabytes, 0, int.MaxValue);
    }

    // Written beside it and moved over it, so a game starting meanwhile never reads half a file. A running game holds
    // the file open, letting others read and write it but not replace it: then it is written in place, which that game
    // no longer reads (it read the file when it started) and the next start reads whole. Written in place, the new
    // text goes over the old one and the end is cut only after, so the file is never left empty; a failure partway is
    // put back to the old text.
    private static void Write(string path, string text, string original)
    {
        var temporary = path + ".pztools-" + Guid.NewGuid().ToString("N")[..8];
        try
        {
            // The file's own encoding: with a byte order mark only if it had one.
            bool mark = File.ReadAllBytes(path) is [0xEF, 0xBB, 0xBF, ..];
            var content = new UTF8Encoding(mark);
            File.WriteAllText(temporary, text, content);
            try { File.Move(temporary, path, overwrite: true); }
            // Replacing a file held open is refused as access denied, or as a sharing violation.
            catch (Exception held) when (held is UnauthorizedAccessException
                || held is IOException and not FileNotFoundException and not DirectoryNotFoundException)
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite))
                {
                    try { Overwrite(stream, content, text); }
                    catch (IOException)
                    {
                        try { Overwrite(stream, content, original); }
                        catch (IOException) { }
                        throw;
                    }
                }
                File.Delete(temporary);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { }
            throw new GameMemoryException("unwritable", "The game's launcher file cannot be written.", error);
        }
    }

    private static void Overwrite(FileStream stream, UTF8Encoding content, string text)
    {
        var bytes = content.GetPreamble().Concat(content.GetBytes(text)).ToArray();
        stream.Position = 0;
        stream.Write(bytes);
        stream.SetLength(bytes.Length);
        stream.Flush(flushToDisk: true);
    }

    // A copy of the file as the game shipped it, beside the app's state, once: the way back by hand if ever needed.
    private void KeepOriginal(string text)
    {
        var copy = Path.Combine(Path.GetDirectoryName(statePath)!, "game-memory-original.json");
        try { if (!File.Exists(copy)) File.WriteAllText(copy, text); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    // ---- Finding the game ----

    /// <summary>The launcher file of the running game; none when no game runs, or it does not say where it is.</summary>
    public static string? Running()
    {
        foreach (var game in GameProcessFinder.Find())
        {
            using (game)
            {
                try
                {
                    // The launcher sits in the game folder; a game started by its Java runtime directly (the game's
                    // own ProjectZomboid64.bat) runs jre64\bin\java.exe, two folders down.
                    var folder = game.MainModule?.FileName is { } executable ? Path.GetDirectoryName(executable) : null;
                    // A java process anyone can start by that name: its file counts only where the game's own
                    // executable stands beside it, as the file this app then edits with administrator rights.
                    for (int up = 0; folder is not null && up <= 2; up++, folder = Path.GetDirectoryName(folder))
                        if (Path.Combine(folder, ConfigFileName) is var file && IsLaunchFile(file) && File.Exists(file)
                            && File.Exists(Path.Combine(folder, "ProjectZomboid64.exe"))) return file;
                }
                // A game run with other rights does not say where it is.
                catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException
                    or NotSupportedException) { }
            }
        }
        return null;
    }

    /// <summary>The launcher file of the game installed through Steam; none when it is not.</summary>
    public static string? Installed()
    {
        if (!OperatingSystem.IsWindows()) return null;
        if (Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) is not string steam)
            return null;
        foreach (var library in SteamLibraries(steam))
        {
            var manifest = Path.Combine(library, "steamapps", $"appmanifest_{SteamAppId}.acf");
            if (!File.Exists(manifest)) continue;
            string folder;
            try { folder = VdfValue(File.ReadAllText(manifest), "installdir") ?? "ProjectZomboid"; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
            var file = Path.Combine(library, "steamapps", "common", folder, ConfigFileName);
            if (File.Exists(file)) return file;
        }
        return null;
    }

    /// <summary>Steam's own folder, then every library its list names.</summary>
    public static IEnumerable<string> SteamLibraries(string steam)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var own = Path.GetFullPath(steam.Replace('/', '\\'));
        if (seen.Add(own)) yield return own;
        string list;
        try { list = File.ReadAllText(Path.Combine(own, "steamapps", "libraryfolders.vdf")); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { yield break; }
        foreach (Match path in VdfPath().Matches(list))
        {
            var library = path.Groups[1].Value.Replace(@"\\", @"\");
            if (library.Length > 0 && seen.Add(Path.GetFullPath(library))) yield return Path.GetFullPath(library);
        }
    }

    [GeneratedRegex("\"path\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\"")]
    private static partial Regex VdfPath();

    private static string? VdfValue(string text, string key)
    {
        var match = Regex.Match(text, $"\"{Regex.Escape(key)}\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\"");
        return match.Success ? match.Groups[1].Value.Replace(@"\\", @"\") : null;
    }

    // ---- This PC ----

    private static long InstalledMemory()
    {
        if (OperatingSystem.IsWindows() && GetPhysicallyInstalledSystemMemory(out var kilobytes) && kilobytes > 0)
            return kilobytes * 1024;
        return GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetPhysicallyInstalledSystemMemory(out long totalMemoryInKilobytes);

    // ---- What is kept ----

    private sealed record Saved(
        [property: JsonPropertyName("chosen_mb")] int? Chosen = null,
        [property: JsonPropertyName("default_max_mb")] int? DefaultMaximum = null,
        [property: JsonPropertyName("default_initial_mb")] int? DefaultInitial = null,
        [property: JsonPropertyName("config_path")] string? ConfigPath = null,
        [property: JsonPropertyName("optimizer_original")] OptimizerOriginal? Optimizer = null);

    private static Saved Read(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<Saved>(File.ReadAllText(path)) ?? new() : new(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }

    // False when it could not be written: it still holds for this run, and the next start only looks again.
    private bool Save(Saved next)
    {
        saved = next;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(statePath)!);
            var temporary = statePath + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(next));
            File.Move(temporary, statePath, overwrite: true);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }
}
