using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace PzTools.Profiling;

/// <summary>
/// Writes a range of a recording as a recording of its own: to compare with, or to pass on, without the rest. The
/// records are the source's, at their own times; those outside the range are left out, by the same rules the analysis
/// counts a range by, and so are the stacks and functions only they referred to, the rest numbered again in order.
/// Information lines say which range it is and what a sample stood for in the whole, so that the new file, opened,
/// shows the very figures the range showed in its source.
/// </summary>
public static class ProfileTrim
{
    /// <summary>The range, on the file's own time scale; the reader takes it as the recording's span.</summary>
    internal const string FromKey = "rangeFromMicros", ToKey = "rangeToMicros";
    /// <summary>What one sample stood for in the recording the range was taken from.</summary>
    internal const string JavaPeriodKey = "javaPeriodEffectiveMicros", NativePeriodKey = "nativePeriodEffectiveMicros",
        LuaPeriodKey = "luaPeriodEffectiveMicros";

    // Said again at the end, for the range; the source's are left out.
    private static readonly HashSet<string> Replaced = new(StringComparer.Ordinal)
    {
        FromKey, ToKey, JavaPeriodKey, NativePeriodKey, LuaPeriodKey, "durationMicros", "samples", "frames", "luaSamples", "endedBy",
    };

    /// <summary>
    /// Writes <paramref name="start"/> to <paramref name="end"/> (microseconds, as <paramref name="recording"/> counts
    /// them) of the recording at <paramref name="source"/>, which <paramref name="recording"/> was read from, to
    /// <paramref name="target"/>. The file appears only when whole; an existing one is not replaced.
    /// </summary>
    public static void Save(ProfileRecording recording, string source, string target, long start, long end,
        CancellationToken cancellationToken = default)
    {
        if (end < start) (start, end) = (end, start);
        start = Math.Max(0, start);
        end = Math.Min(recording.Duration, end);
        if (end <= start) throw new ArgumentException("The range is empty.", nameof(end));
        var from = recording.Origin + start;
        var to = recording.Origin + end;
        // Read twice: first for the stacks the range's samples use, as tables and samples come in any order; then to
        // write. A second decompression costs less than holding a long recording's range in memory.
        var numbers = NumberTables(source, from, to, cancellationToken);
        var staged = target + ".tmp";
        try
        {
            long samples = 0, frames = 0, luaSamples = 0;
            using (var reader = Open(source, out var signature))
            using (var output = new FileStream(staged, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            using (var compressed = new GZipStream(output, CompressionLevel.Optimal))
            using (var writer = new StreamWriter(compressed, new UTF8Encoding(false), 1 << 16))
            {
                writer.Write(signature);
                writer.Write('\n');
                var count = 0;
                // The game thread's allocation readings each cover the time since the one before: the range needs the
                // one after it, which covers its end, and the one before it, where the first inside began. A second
                // apart, so few; they are kept aside and chosen once all are known, as records are not in time order.
                var allocations = new List<(long Time, string Line)>();
                while (reader.ReadLine() is { } line)
                {
                    if ((++count & 0xFFFF) == 0) cancellationToken.ThrowIfCancellationRequested();
                    if (line.Length == 0) continue;
                    var kind = Kind(line);
                    if (kind == "GA")
                    {
                        if (Number(Field(line, 1)) is { } reading) allocations.Add((reading, line));
                        continue;
                    }
                    if (!Keeps(kind, line, from, to)) continue;
                    var written = kind switch
                    {
                        "S" => Renumber(line, 3, numbers.Stacks),
                        "L" => Renumber(line, 2, numbers.LuaStacks),
                        "M" => Renumber(line, 1, numbers.Methods),
                        "LM" => Renumber(line, 1, numbers.LuaFunctions),
                        "K" => Renumber(line, 1, numbers.Stacks) is { } stack ? Frames(stack, numbers.Methods, lua: false) : null,
                        "LK" => Renumber(line, 1, numbers.LuaStacks) is { } stack ? Frames(stack, numbers.LuaFunctions, lua: true) : null,
                        _ => line,
                    };
                    if (written is null) continue;
                    switch (kind)
                    {
                        case "S": samples++; break;
                        case "F": frames++; break;
                        case "L": luaSamples++; break;
                    }
                    writer.Write(written);
                    writer.Write('\n');
                }
                allocations.Sort((left, right) => left.Time.CompareTo(right.Time));
                var before = allocations.FindLastIndex(item => item.Time < from);
                var after = allocations.FindIndex(item => item.Time >= to);
                for (var index = Math.Max(0, before); index <= (after < 0 ? allocations.Count - 1 : after); index++)
                {
                    writer.Write(allocations[index].Line);
                    writer.Write('\n');
                }
                void Information(string key, long value) =>
                    writer.Write(string.Create(CultureInfo.InvariantCulture, $"I\t{key}\t{value}\n"));
                Information(FromKey, from);
                Information(ToKey, to);
                Information(JavaPeriodKey, recording.JavaPeriod);
                Information(NativePeriodKey, recording.NativePeriod);
                if (recording.LuaPeriod > 0) Information(LuaPeriodKey, recording.LuaPeriod);
                Information("durationMicros", end - start);
                Information("samples", samples);
                Information("frames", frames);
                Information("luaSamples", luaSamples);
                // Neither the game's last minutes nor a recording that ran until stopped: a part of one.
                writer.Write("I\tendedBy\trange\n");
            }
            File.Move(staged, target, overwrite: false);
        }
        finally
        {
            try { File.Delete(staged); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    // For each table, the source's numbers the range uses and their new ones, in the source's order.
    private sealed record Numbering(Dictionary<int, int> Stacks, Dictionary<int, int> Methods, Dictionary<int, int> LuaStacks,
        Dictionary<int, int> LuaFunctions);

    private static Numbering NumberTables(string source, long from, long to, CancellationToken cancellationToken)
    {
        var stacks = new HashSet<int>();
        var luaStacks = new HashSet<int>();
        // Each stack's frames as written: which methods or Lua functions it needs, once known whether it is used.
        var stackFrames = new Dictionary<int, string>();
        var luaStackFrames = new Dictionary<int, string>();
        using (var reader = Open(source, out _))
        {
            var count = 0;
            while (reader.ReadLine() is { } line)
            {
                if ((++count & 0xFFFF) == 0) cancellationToken.ThrowIfCancellationRequested();
                switch (Kind(line))
                {
                    case "K" when Index(Field(line, 1)) is { } id && Field(line, 2) is { } frames: stackFrames[id] = frames; break;
                    case "LK" when Index(Field(line, 1)) is { } id && Field(line, 2) is { } frames: luaStackFrames[id] = frames; break;
                    case "S" when Keeps("S", line, from, to) && Index(Field(line, 3)) is { } stack: stacks.Add(stack); break;
                    case "L" when Keeps("L", line, from, to) && Index(Field(line, 2)) is { } stack: luaStacks.Add(stack); break;
                }
            }
        }
        var methods = new HashSet<int>();
        foreach (var stack in stacks)
            foreach (var frame in Split(stackFrames.GetValueOrDefault(stack)))
                if (Index(frame) is { } method) methods.Add(method);
        var luaFunctions = new HashSet<int>();
        foreach (var stack in luaStacks)
            foreach (var frame in Split(luaStackFrames.GetValueOrDefault(stack)))
                if (Index(frame.Split(':')[0]) is { } function) luaFunctions.Add(function);
        return new(Dense(stacks), Dense(methods), Dense(luaStacks), Dense(luaFunctions));
    }

    private static Dictionary<int, int> Dense(HashSet<int> used)
    {
        var numbers = new Dictionary<int, int>(used.Count);
        foreach (var id in used.Order()) numbers[id] = numbers.Count;
        return numbers;
    }

    private static string[] Split(string? frames) => string.IsNullOrEmpty(frames) ? [] : frames.Split(' ');

    // Whether the range keeps a record. A record the reader would skip as malformed is left out.
    private static bool Keeps(string kind, string line, long from, long to) => kind switch
    {
        "I" => Field(line, 1) is { } key && !Replaced.Contains(key),
        // Points in time: those in the range, as the analysis counts them.
        "S" or "F" or "L" or "LA" or "LH" or "H" or "V" => Number(Field(line, 1)) is { } time && time >= from && time < to,
        // Spans: those that reach into it, as the analysis counts collections and pauses.
        "G" or "P" => Number(Field(line, 1)) is { } time && Number(Field(line, 2)) is { } duration
            && time < to && time + Math.Max(0, duration) >= from,
        // Tables, renumbered as they are written; threads are kept whole, being few. A kind this version does not
        // know is kept as it is; the reader skips it.
        _ => true,
    };

    // The line with the number in one field changed to its new one; null when the range does not use it.
    private static string? Renumber(string line, int field, Dictionary<int, int> numbers)
    {
        var fields = line.Split('\t');
        if (fields.Length <= field || Index(fields[field]) is not { } id || !numbers.TryGetValue(id, out var renumbered)) return null;
        fields[field] = renumbered.ToString(CultureInfo.InvariantCulture);
        return string.Join('\t', fields);
    }

    // A stack line's frames, each method or Lua function (before ":line") under its new number.
    private static string? Frames(string line, Dictionary<int, int> numbers, bool lua)
    {
        var fields = line.Split('\t');
        if (fields.Length != 3) return null;
        var frames = Split(fields[2]);
        for (var index = 0; index < frames.Length; index++)
        {
            var colon = lua ? frames[index].IndexOf(':') : -1;
            var id = colon < 0 ? frames[index] : frames[index][..colon];
            if (Index(id) is not { } number || !numbers.TryGetValue(number, out var renumbered)) return null;
            frames[index] = renumbered.ToString(CultureInfo.InvariantCulture) + (colon < 0 ? "" : frames[index][colon..]);
        }
        fields[2] = string.Join(' ', frames);
        return string.Join('\t', fields);
    }

    // The recording's lines after its first, which says what it is.
    private static StreamReader Open(string source, out string signature)
    {
        var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan);
        var reader = new StreamReader(new GZipStream(input, CompressionMode.Decompress), Encoding.UTF8, false, 1 << 16);
        if (reader.ReadLine() is { } first && first.StartsWith("PZPROF\t", StringComparison.Ordinal))
        {
            signature = first;
            return reader;
        }
        reader.Dispose();
        throw new InvalidDataException("Not a PZ Tools recording, or a newer format.");
    }

    private static string Kind(string line)
    {
        var tab = line.IndexOf('\t');
        return tab < 0 ? line : line[..tab];
    }

    private static string? Field(string line, int index)
    {
        var start = 0;
        for (var skipped = 0; skipped < index; skipped++)
        {
            start = line.IndexOf('\t', start) + 1;
            if (start == 0) return null;
        }
        var end = line.IndexOf('\t', start);
        return end < 0 ? line[start..] : line[start..end];
    }

    private static long? Number(string? text) =>
        long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value) ? value : null;

    private static int? Index(string? text) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var value) ? value : null;
}
