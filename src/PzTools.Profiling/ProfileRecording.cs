using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace PzTools.Profiling;

/// <summary>One stack sample. <see cref="Native"/>: the thread was inside a native call, not running Java.</summary>
public readonly record struct ProfileSample(long Time, int Thread, int Stack, bool Native);
public readonly record struct ProfileFrame(long Start, long Duration);
public readonly record struct ProfileLuaSample(long Time, int Stack);
public readonly record struct ProfileLuaFrame(int Function, int Line);
public sealed record ProfileLuaFunction(string Name, string File);
public sealed record ProfileCollection(long Time, long Duration, string Name, string Cause);
public sealed record ProfilePause(long Time, long Duration, string Kind, int Thread, string Detail);

/// <summary>
/// A finished recording, read whole into memory. Times are microseconds from the first record;
/// every list is in time order. The file is the gzip text format written by the recording converter.
/// </summary>
public sealed class ProfileRecording
{
    public const string Extension = ".pzprof";
    private const string Signature = "PZPROF\t1";
    // A recording is bounded by the recorder; this only stops a damaged or foreign file from exhausting memory.
    private const int MaximumRecords = 40_000_000;

    public required IReadOnlyDictionary<string, string> Information { get; init; }
    public required IReadOnlyList<string> Threads { get; init; }
    /// <summary>Index into <see cref="Threads"/> of the thread that runs the game loop; -1 when unknown.</summary>
    public required int GameThread { get; init; }
    public required IReadOnlyList<string> Methods { get; init; }
    /// <summary>Method indexes, innermost first.</summary>
    public required IReadOnlyList<int[]> Stacks { get; init; }
    public required ProfileSample[] Samples { get; init; }
    public required ProfileFrame[] Frames { get; init; }
    public required IReadOnlyList<ProfileLuaFunction> LuaFunctions { get; init; }
    public required IReadOnlyList<ProfileLuaFrame[]> LuaStacks { get; init; }
    public required ProfileLuaSample[] LuaSamples { get; init; }
    public required IReadOnlyList<ProfileCollection> Collections { get; init; }
    public required IReadOnlyList<ProfilePause> Pauses { get; init; }
    public required long Duration { get; init; }
    public required long JavaPeriod { get; init; }
    public required long NativePeriod { get; init; }
    /// <summary>Microseconds between Lua samples; 0 when Lua was not sampled.</summary>
    public required long LuaPeriod { get; init; }

    public bool Detailed => Information.GetValueOrDefault("mode") == "detailed";
    public DateTimeOffset? StartedUtc =>
        long.TryParse(Information.GetValueOrDefault("startEpochMillis"), NumberStyles.None, CultureInfo.InvariantCulture, out var millis) && millis > 0
            ? DateTimeOffset.FromUnixTimeMilliseconds(millis) : null;

    public static ProfileRecording Load(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan);
        return Read(file);
    }

    public static ProfileRecording Read(Stream compressed)
    {
        using var gzip = new GZipStream(compressed, CompressionMode.Decompress, leaveOpen: true);
        using var reader = new StreamReader(gzip, Encoding.UTF8, false, 1 << 16);
        if (reader.ReadLine() != Signature) throw new InvalidDataException("Not a PZ Tools recording, or a newer format.");

        var information = new Dictionary<string, string>(StringComparer.Ordinal);
        var threadNames = new Dictionary<long, string>();
        var methods = new List<string>();
        var stacks = new List<int[]>();
        var samples = new List<(long Time, long Thread, int Stack, bool Native)>();
        var frames = new List<ProfileFrame>();
        var luaFunctions = new List<ProfileLuaFunction>();
        var luaStacks = new List<ProfileLuaFrame[]>();
        var luaSamples = new List<ProfileLuaSample>();
        var collections = new List<ProfileCollection>();
        var pauses = new List<(long Time, long Duration, string Kind, long Thread, string Detail)>();
        long luaPeriod = 0, records = 0;

        while (reader.ReadLine() is { } line)
        {
            if (line.Length == 0) continue;
            if (++records > MaximumRecords) throw new InvalidDataException("The recording is too large to open.");
            var fields = line.Split('\t');
            switch (fields[0])
            {
                case "I" when fields.Length == 3: information[fields[1]] = fields[2]; break;
                case "T" when fields.Length == 3: threadNames[Number(fields[1])] = fields[2]; break;
                case "M" when fields.Length == 3: Place(methods, fields[1], fields[2], "?"); break;
                case "K" when fields.Length == 3:
                    Place(stacks, fields[1], fields[2].Length == 0 ? [] : Array.ConvertAll(fields[2].Split(' '), Index), []);
                    break;
                case "S" when fields.Length == 5:
                    samples.Add((Number(fields[1]), Number(fields[2]), Index(fields[3]), fields[4] == "N"));
                    break;
                case "F" when fields.Length == 3: frames.Add(new(Number(fields[1]), Math.Max(0, Number(fields[2])))); break;
                case "LM" when fields.Length == 4: Place(luaFunctions, fields[1], new(fields[2], fields[3]), new("?", "?")); break;
                case "LK" when fields.Length == 3:
                    Place(luaStacks, fields[1], fields[2].Length == 0 ? [] : Array.ConvertAll(fields[2].Split(' '), text =>
                    {
                        var split = text.IndexOf(':');
                        return split < 0 ? new ProfileLuaFrame(Index(text), 0) : new ProfileLuaFrame(Index(text[..split]), Index(text[(split + 1)..]));
                    }), []);
                    break;
                case "L" when fields.Length == 3: luaSamples.Add(new(Number(fields[1]), Index(fields[2]))); break;
                case "LH" when fields.Length == 5: luaPeriod = Math.Max(luaPeriod, Number(fields[4])); break;
                case "G" when fields.Length == 5:
                    collections.Add(new(Number(fields[1]), Math.Max(0, Number(fields[2])), fields[3], fields[4]));
                    break;
                case "P" when fields.Length == 6:
                    pauses.Add((Number(fields[1]), Math.Max(0, Number(fields[2])), fields[3], Number(fields[4]), fields[5]));
                    break;
                // Unknown record kinds are skipped: a later writer may add some without breaking this reader.
            }
        }

        // The recorder does not store events in time order and its first event is not the earliest one.
        long origin = long.MaxValue;
        foreach (var item in samples) origin = Math.Min(origin, item.Time);
        foreach (var item in frames) origin = Math.Min(origin, item.Start);
        foreach (var item in luaSamples) origin = Math.Min(origin, item.Time);
        if (origin == long.MaxValue) origin = 0;

        // A pause that belongs to no Java thread (a collector pause) carries -1.
        var threadIds = threadNames.Keys.Concat(samples.Select(item => item.Thread))
            .Concat(pauses.Select(item => item.Thread).Where(id => id != -1)).Distinct().Order().ToArray();
        var threadIndex = new Dictionary<long, int>();
        foreach (var id in threadIds) threadIndex[id] = threadIndex.Count;
        var threads = threadIds.Select(id => threadNames.GetValueOrDefault(id) ?? "thread-" + id.ToString(CultureInfo.InvariantCulture)).ToArray();

        var orderedSamples = new ProfileSample[samples.Count];
        for (var index = 0; index < orderedSamples.Length; index++)
        {
            var item = samples[index];
            if ((uint)item.Stack >= (uint)stacks.Count) throw new InvalidDataException("The recording refers to a stack it does not contain.");
            orderedSamples[index] = new(item.Time - origin, threadIndex[item.Thread], item.Stack, item.Native);
        }
        Array.Sort(orderedSamples, (left, right) => left.Time.CompareTo(right.Time));
        foreach (var stack in stacks)
            foreach (var method in stack)
                if ((uint)method >= (uint)methods.Count) throw new InvalidDataException("The recording refers to a method it does not contain.");

        var orderedFrames = frames.Select(frame => frame with { Start = frame.Start - origin }).OrderBy(frame => frame.Start).ToArray();
        var orderedLua = new ProfileLuaSample[luaSamples.Count];
        for (var index = 0; index < orderedLua.Length; index++)
        {
            if ((uint)luaSamples[index].Stack >= (uint)luaStacks.Count) throw new InvalidDataException("The recording refers to a Lua stack it does not contain.");
            orderedLua[index] = luaSamples[index] with { Time = luaSamples[index].Time - origin };
        }
        Array.Sort(orderedLua, (left, right) => left.Time.CompareTo(right.Time));
        foreach (var stack in luaStacks)
            foreach (var frame in stack)
                if ((uint)frame.Function >= (uint)luaFunctions.Count) throw new InvalidDataException("The recording refers to a Lua function it does not contain.");

        long end = 0;
        if (orderedSamples.Length > 0) end = Math.Max(end, orderedSamples[^1].Time);
        if (orderedFrames.Length > 0) end = Math.Max(end, orderedFrames[^1].Start + orderedFrames[^1].Duration);
        if (orderedLua.Length > 0) end = Math.Max(end, orderedLua[^1].Time);

        long Setting(string key, long fallback) =>
            long.TryParse(information.GetValueOrDefault(key), NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value > 0 ? value : fallback;
        var detailed = information.GetValueOrDefault("mode") == "detailed";
        return new ProfileRecording
        {
            Information = information,
            Threads = threads,
            GameThread = long.TryParse(information.GetValueOrDefault("gameThread"), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var game)
                && threadIndex.TryGetValue(game, out var gameIndex) ? gameIndex : -1,
            Methods = methods,
            Stacks = stacks,
            Samples = orderedSamples,
            Frames = orderedFrames,
            LuaFunctions = luaFunctions,
            LuaStacks = luaStacks,
            LuaSamples = orderedLua,
            Collections = collections.Select(item => item with { Time = item.Time - origin }).OrderBy(item => item.Time).ToArray(),
            Pauses = pauses.Select(item => new ProfilePause(item.Time - origin, item.Duration, item.Kind,
                threadIndex.GetValueOrDefault(item.Thread, -1), item.Detail)).OrderBy(item => item.Time).ToArray(),
            Duration = end,
            JavaPeriod = EffectivePeriod(orderedSamples, threads.Length, false, Setting("javaPeriodMicros", detailed ? 1_000 : 10_000)),
            NativePeriod = EffectivePeriod(orderedSamples, threads.Length, true, Setting("nativePeriodMicros", detailed ? 10_000 : 20_000)),
            LuaPeriod = EffectiveLuaPeriod(orderedLua, luaPeriod),
        };
    }

    /// <summary>
    /// The recorder cannot always keep the period it was asked for (a 1 ms request typically yields
    /// one sample every 1.5-2 ms). The usual gap between a thread's consecutive samples is what one
    /// sample really stands for; with too few samples to tell, the requested period is used.
    /// </summary>
    private static long EffectivePeriod(ProfileSample[] samples, int threads, bool native, long requested)
    {
        var last = new long[threads];
        Array.Fill(last, -1);
        var gaps = new List<long>();
        foreach (var sample in samples)
        {
            if (sample.Native != native) continue;
            var previous = last[sample.Thread];
            last[sample.Thread] = sample.Time;
            // Longer gaps mean the thread was doing something else in between, not that sampling was slow.
            if (previous >= 0 && sample.Time - previous <= requested * 4) gaps.Add(sample.Time - previous);
        }
        if (gaps.Count < 50) return requested;
        gaps.Sort();
        return Math.Clamp(gaps[gaps.Count / 2], requested, requested * 4);
    }

    /// <summary>The same correction for the Lua sampler, whose wait is also longer than asked for.</summary>
    private static long EffectiveLuaPeriod(ProfileLuaSample[] samples, long requested)
    {
        if (requested <= 0) return 0;
        var gaps = new List<long>();
        for (var index = 1; index < samples.Length; index++)
        {
            var gap = samples[index].Time - samples[index - 1].Time;
            if (gap <= requested * 4) gaps.Add(gap);
        }
        if (gaps.Count < 50) return requested;
        gaps.Sort();
        return Math.Clamp(gaps[gaps.Count / 2], requested, requested * 4);
    }

    private static void Place<T>(List<T> list, string index, T value, T filler)
    {
        var position = Index(index);
        if (position > MaximumRecords) throw new InvalidDataException("The recording has an invalid table index.");
        while (list.Count <= position) list.Add(filler);
        list[position] = value;
    }

    private static long Number(string text) =>
        long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
            ? value : throw new InvalidDataException("The recording has an invalid number.");

    private static int Index(string text) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var value)
            ? value : throw new InvalidDataException("The recording has an invalid index.");
}
