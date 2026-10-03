using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace PzTools.Profiling;

/// <summary>
/// Writes a range of a recording as a recording of its own: to compare with, or to pass on, without the rest. The
/// records are the source's, untouched, so the range keeps its times and every table; only those outside it are left
/// out, by the same rules the analysis counts a range by. Information lines say which range it is and what a sample
/// stood for in the whole, so that the new file, opened, shows the very figures the range showed in its source.
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
        var staged = target + ".tmp";
        try
        {
            long samples = 0, frames = 0, luaSamples = 0;
            using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan))
            using (var gzip = new GZipStream(input, CompressionMode.Decompress))
            using (var reader = new StreamReader(gzip, Encoding.UTF8, false, 1 << 16))
            using (var output = new FileStream(staged, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
            using (var compressed = new GZipStream(output, CompressionLevel.Optimal))
            using (var writer = new StreamWriter(compressed, new UTF8Encoding(false), 1 << 16))
            {
                var signature = reader.ReadLine();
                if (signature is null || !signature.StartsWith("PZPROF\t", StringComparison.Ordinal))
                    throw new InvalidDataException("Not a PZ Tools recording, or a newer format.");
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
                    var tab = line.IndexOf('\t');
                    var kind = tab < 0 ? line : line[..tab];
                    if (kind == "GA")
                    {
                        if (Number(Field(line, 1)) is { } reading) allocations.Add((reading, line));
                        continue;
                    }
                    // A record the reader would skip as malformed is left out.
                    var keep = kind switch
                    {
                        "I" => Field(line, 1) is { } key && !Replaced.Contains(key),
                        // Points in time: those in the range, as the analysis counts them.
                        "S" or "F" or "L" or "LA" or "LH" or "H" or "V" => Number(Field(line, 1)) is { } time && time >= from && time < to,
                        // Spans: those that reach into it, as the analysis counts collections and pauses.
                        "G" or "P" => Number(Field(line, 1)) is { } time && Number(Field(line, 2)) is { } duration
                            && time < to && time + Math.Max(0, duration) >= from,
                        // Tables (threads, methods, stacks, Lua functions) are kept whole: the numbers refer to them.
                        // A kind this version does not know is kept as it is; the reader skips it.
                        _ => true,
                    };
                    if (!keep) continue;
                    switch (kind)
                    {
                        case "S": samples++; break;
                        case "F": frames++; break;
                        case "L": luaSamples++; break;
                    }
                    writer.Write(line);
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
}
