using System.Globalization;
using System.Text;

namespace PzTools.Profiling;

/// <summary>
/// A range's analysis as one Markdown report, to be pasted into a chat with an AI model: the same sections and limits
/// whatever the page has open, every figure said with what it is of, and a few lines on how to read them first. In
/// English with invariant numbers, as a format rather than a page: models read it as well whatever language the
/// player then asks in, and two reports read alike.
/// </summary>
public static class ProfileReport
{
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
    // Enough to see where the time went, short enough to paste: the heaviest of each, the rest summed.
    private const int Mods = 12, ModsOpened = 5, FunctionsPerMod = 8, JavaMethods = 15, CallerMethods = 5, CallersPerMethod = 3,
        Allocators = 8, Pauses = 5, Threads = 8;
    // Below this a share is noise in a sampled profile; such rows are left out of the per-mod and caller sections.
    private const double Noticeable = 0.005;

    /// <param name="thread">The thread the range was analysed for, as <see cref="ProfileAnalysis.Analyze"/>'s; -1 all.</param>
    /// <param name="name">The recording's name as the list shows it.</param>
    public static string Build(ProfileRecording recording, ProfileRange range, int thread, string? name = null)
    {
        var text = new StringBuilder();
        void Line(string line = "") => text.Append(line).Append('\n');
        var length = Math.Max(1, range.End - range.Start);

        Line("# Project Zomboid performance recording (PZ Tools)");
        Line();
        Line("How to read: a sampling profile of the game's Java process (the engine) and its Lua scripts (mods and the "
            + "base game's own). Percentages are shares of the analysed range's wall-clock time on the analysed thread. "
            + "Self = time in the function itself; Total = including what it called. Figures are statistical: shares "
            + "under about 0.5% or from fewer than about 20 samples are noise.");
        Line();

        Line("## Recording");
        if (!string.IsNullOrWhiteSpace(name)) Line($"- Name: {name}");
        var kind = recording.Information.GetValueOrDefault("endedBy") == "rolling" ? ", the game's last minutes saved after the fact" : "";
        Line(recording.Detailed
            ? $"- Mode: detailed (Lua lines and allocations measured; the measuring itself slows the game by about 20%){kind}"
            : $"- Mode: standard (low overhead){kind}");
        var started = recording.StartedUtc is { } utc ? $", started {utc.ToLocalTime():yyyy-MM-dd HH:mm}" : "";
        Line($"- Length: {Seconds(recording.Duration)}{started}");
        Line(range.Start <= 0 && range.End >= recording.Duration
            ? "- Range analysed: the whole recording"
            : $"- Range analysed: {Seconds(range.Start)} to {Seconds(range.End)} ({Seconds(range.End - range.Start)})");
        Line(thread < 0 ? "- Thread analysed: all threads together (their times overlap, so shares can exceed what one thread could)"
            : thread == recording.GameThread ? $"- Thread analysed: the game's main thread ({recording.Threads[thread]}), which runs the game loop and all Lua"
            : $"- Thread analysed: {recording.Threads[thread]}");
        Line($"- Samples in the range: {Count(range.Samples)} Java, {Count(range.LuaSamples)} Lua");
        if (recording.LuaPeriod <= 0) Line("- Lua was not sampled in this recording.");
        if (recording.Processors > 0) Line($"- Machine: {recording.Processors} logical processors");
        Line();

        if (range.Frames.Count > 0)
        {
            var frames = range.Frames;
            Line("## Frames");
            Line($"- {Count(frames.Count)} frames, average {Ms(frames.AverageMilliseconds)} ({Fps(frames.AverageMilliseconds)}), "
                + $"median {Ms(frames.MedianMilliseconds)}, worst 1% {Ms(frames.OnePercentWorstMilliseconds)}, slowest {Ms(frames.SlowestMilliseconds)}");
            Line();
        }

        if (ProfileAnalysis.TimeBreakdown(range) is { } breakdown && range.Samples >= 20)
        {
            Line("## Where the analysed thread's time went");
            Line($"- Lua scripts {Pct(breakdown.Scripts)} (mods and base-game scripts, with the game code they called)");
            Line($"- Game code {Pct(breakdown.GameCode)} (the Java engine itself)");
            Line($"- Stopped for memory {Pct(breakdown.Collections)} (garbage-collector pauses and waits for free memory)");
            Line($"- Not running {Pct(breakdown.Waiting)} (waiting: for the next frame, for the GPU, for other threads)");
            Line();
        }

        Memory(recording, range, Line);

        if (range.LuaGroups.Count > 0) Lua(recording, range, Line);
        else if (recording.LuaPeriod > 0) { Line("## Lua scripts"); Line("- No Lua ran in this range."); Line(); }

        if (range.MethodGroups.Count > 0) Java(recording, range, thread, Line);

        if (range.LuaAllocationGroups.Count > 0)
        {
            Line("## Memory allocated by Lua, by mod");
            Line("What each mod's scripts allocated while they ran: allocation drives the garbage collector.");
            if (range.GameThreadAllocated is { } all)
                Line($"Game thread allocated {Bytes(all)} in the range, {Bytes(range.LuaAllocated)} of it while running Lua.");
            Line();
            Line("| Mod | Allocated |");
            Line("|---|---:|");
            foreach (var group in range.LuaAllocationGroups.Take(Allocators)) Line($"| {Cell(OwnerName(group.Key))} | {Bytes(group.Self)} |");
            Line();
        }

        if (thread < 0 && range.Threads.Count > 1)
        {
            Line("## Threads");
            Line("| Thread | Share of all threads' samples |");
            Line("|---|---:|");
            foreach (var row in range.Threads.Take(Threads)) Line($"| {Cell(row.Name)} | {Pct(row.Self)} |");
            Line();
        }

        if (range.LongestPauses.Count > 0)
        {
            Line("## Longest waits and pauses");
            Line("| At | Length | Kind | Detail |");
            Line("|---:|---:|---|---|");
            foreach (var pause in range.LongestPauses.Take(Pauses))
            {
                var detail = string.Join(", ", new[]
                {
                    pause.Detail is "?" or "" ? null : pause.Detail,
                    pause.Thread >= 0 && pause.Thread < recording.Threads.Count ? recording.Threads[pause.Thread] : null,
                }.OfType<string>());
                Line($"| {Seconds(pause.Time)} | {Ms(pause.Duration / 1000.0)} | {Cell(pause.Kind)} | {Cell(detail)} |");
            }
            Line();
        }
        return text.ToString().TrimEnd() + "\n";
    }

    private static void Memory(ProfileRecording recording, ProfileRange range, Action<string> line)
    {
        var lines = new List<string>();
        var pressure = ProfileAnalysis.MemoryPressure(recording);
        var (heapPeak, videoPeak) = ProfileAnalysis.MemoryPeaksIn(recording, range.Start, range.End);
        if (heapPeak is { } heap)
            lines.Add(pressure.MaximumBytes > 0
                ? $"- Java heap: peak {Bytes(heap)} of {Bytes(pressure.MaximumBytes)} maximum (the game's memory setting); "
                    + $"at 90% or more of the maximum in {Pct(pressure.FullShare)} of the whole recording's readings"
                : $"- Java heap: peak {Bytes(heap)}");
        if (videoPeak is { } video) lines.Add($"- Video memory: peak {Bytes(video)}");
        var collectors = recording.Collections.Select(collection => collection.Name).Distinct(StringComparer.Ordinal).ToArray();
        var (collections, paused) = ProfileAnalysis.CollectionsIn(recording, range.Start, range.End);
        if (collections > 0 || collectors.Length > 0)
            lines.Add($"- Garbage collections: {Count(collections)}, their pauses {Ms(paused)} in all"
                + (collectors.Length > 0 ? $" (collector: {string.Join(", ", collectors)})" : ""));
        if (ProfileAnalysis.CollectorBusyIn(recording, range.Start, range.End) is { } busy)
            lines.Add($"- Collector at work for {Pct(busy)} of the range. ZGC, the game's default, hardly pauses the game but "
                + "runs beside it on the CPU: near 100% means memory is short and the game slows down.");
        var (stalls, longest) = ProfileAnalysis.StallsIn(recording, range.Start, range.End);
        if (stalls > 0) lines.Add($"- Allocation stalls: {Count(stalls)} times a thread stopped until memory was freed, longest {Ms(longest / 1000.0)}");
        if (ProfileAnalysis.FramesWithCollector(recording)?.Slower is { } slower)
            lines.Add($"- Frames while the collector worked were {Pct(slower)} slower than frames without it (whole recording)");
        if (pressure.Short) lines.Add("- Verdict: the game ran short of memory in this recording; giving it more memory is likely to help.");
        if (ProfileAnalysis.OtherProgramsCpu(recording) is { } other)
            lines.Add($"- Other programs used {Pct(other)} of all processors on average while it recorded");
        if (lines.Count == 0) return;
        line("## Memory and CPU");
        foreach (var item in lines) line(item);
        line("");
    }

    private static void Lua(ProfileRecording recording, ProfileRange range, Action<string> line)
    {
        line("## Lua scripts by mod");
        line($"All Lua together: {Pct(range.LuaShare)} of the range. Each mod's share is its functions' own time.");
        line("");
        line("| # | Mod | Share | Samples |");
        line("|---:|---|---:|---:|");
        var shown = range.LuaGroups.Take(Mods).ToArray();
        for (var index = 0; index < shown.Length; index++)
            line($"| {index + 1} | {Cell(OwnerName(shown[index].Key))} | {Pct(shown[index].Self)} | {Count(shown[index].Samples)} |");
        if (range.LuaGroups.Count > Mods)
        {
            var rest = range.LuaGroups.Skip(Mods).ToArray();
            line($"| | {rest.Length} more | {Pct(rest.Sum(group => group.Self))} | {Count(rest.Sum(group => group.Samples))} |");
        }
        line("");

        // The function's heaviest line of its own: where to look in the file.
        var functions = new Dictionary<(string, string), int>();
        for (var index = 0; index < recording.LuaFunctions.Count; index++)
            functions.TryAdd((recording.LuaFunctions[index].Name, recording.LuaFunctions[index].File), index);
        foreach (var group in range.LuaGroups.Take(ModsOpened).Where(group => group.Self >= Noticeable))
        {
            line($"### {OwnerName(group.Key)}: {Pct(group.Self)} of the range");
            line("| Function | File:line | Self | Total |");
            line("|---|---|---:|---:|");
            var lines = range.LuaLines.GetValueOrDefault(group.Key);
            foreach (var row in group.Rows.Take(FunctionsPerMod))
            {
                var at = functions.TryGetValue((row.Name, row.Detail), out var function)
                    && lines?.GetValueOrDefault(function) is { Count: > 0 } own
                    && own.MaxBy(item => item.SelfSamples) is { Line: > 0, SelfSamples: > 0 } heaviest
                        ? ":" + heaviest.Line.ToString(Invariant) : "";
                line($"| {Cell(row.Name is "" or "?" ? "(anonymous)" : row.Name)} | {Cell(row.Detail + at)} | {Pct(row.Self)} | {Pct(row.Total)} |");
            }
            if (group.Rows.Count > FunctionsPerMod)
                line($"| {group.Rows.Count - FunctionsPerMod} more | | {Pct(group.Rows.Skip(FunctionsPerMod).Sum(row => row.Self))} | |");
            line("");
        }
    }

    private static void Java(ProfileRecording recording, ProfileRange range, int thread, Action<string> line)
    {
        line("## Java (engine) by area");
        line("| Area | Self |");
        line("|---|---:|");
        foreach (var group in range.MethodGroups) line($"| {Cell(AreaName(group.Key))} | {Pct(group.Self)} |");
        line("");
        line("## Heaviest Java methods");
        line("| Method | Self | Total |");
        line("|---|---:|---:|");
        foreach (var method in range.Methods.Take(JavaMethods)) line($"| {Cell(method.Name)} | {Pct(method.Self)} | {Pct(method.Total)} |");
        line("");

        // A JDK or library method's time read in the game's terms: who called it, up to the game's own code.
        var callers = range.Methods.Take(CallerMethods).Where(method => method.Self >= Noticeable).ToArray();
        if (callers.Length == 0) return;
        line("## Who called the heaviest methods");
        line("Each line: the method, then its callers nearest first (A <- B: B called A), with the share of the range through that path. "
            + "(Lua code running) means a script called it; which scripts ran is in the Lua sections above.");
        line("");
        foreach (var method in callers)
        {
            var root = ProfileAnalysis.CallersOf(recording, range.Start, range.End, thread, method.Name);
            line($"- `{method.Name}` ({Pct(method.Self)})");
            foreach (var caller in root.Callers.Take(CallersPerMethod).Where(caller => caller.Share >= Noticeable / 2))
            {
                var chain = new List<string>(caller.Methods);
                // Up the heaviest path a few rows more until the game's code: a library chain alone says little.
                for (var (node, depth) = (caller, 0); !node.ReachesGame && node.Callers.Count > 0 && depth < 3; depth++)
                {
                    node = node.Callers[0];
                    chain.AddRange(node.Methods);
                }
                line($"  - {Pct(caller.Share)}: <- {string.Join(" <- ", chain.Select(Readable))}");
            }
        }
        line("");
    }

    private static string Readable(string method) => method == ProfileAnalysis.LuaRun ? "(Lua code running)" : method;

    private static string OwnerName(string key) => key switch
    {
        ProfileAnalysis.GameOwner => "Base game scripts (vanilla)",
        ProfileAnalysis.UnknownOwner => "(owner unknown)",
        _ => key,
    };

    private static string AreaName(string key) => key switch
    {
        ProfileAnalysis.GameCode => "Base game engine (zombie.*)",
        ProfileAnalysis.LuaRuntime => "Lua interpreter (Kahlua; runs the scripts above)",
        ProfileAnalysis.JavaRuntime => "Java built-ins (java.*, jdk.*)",
        ProfileAnalysis.Tools => "PZ Tools itself",
        ProfileAnalysis.Libraries => "Bundled libraries (graphics, sound, others)",
        _ => key,
    };

    private static string Cell(string text) => text.Replace("|", "\\|").Replace('\n', ' ');
    private static string Pct(double share) => (share * 100).ToString("0.00", Invariant) + "%";
    private static string Ms(double milliseconds) => milliseconds.ToString("0.0", Invariant) + " ms";
    private static string Fps(double milliseconds) => milliseconds > 0 ? (1000 / milliseconds).ToString("0", Invariant) + " FPS" : "-";
    private static string Seconds(long microseconds) => (microseconds / 1_000_000.0).ToString("0.00", Invariant) + " s";
    private static string Count(long count) => count.ToString("N0", Invariant);

    private static string Bytes(long bytes) => bytes switch
    {
        >= 1L << 30 => (bytes / (double)(1L << 30)).ToString("0.00", Invariant) + " GB",
        >= 1L << 20 => (bytes / (double)(1L << 20)).ToString("0.00", Invariant) + " MB",
        _ => (bytes / 1024.0).ToString("0.00", Invariant) + " KB",
    };
}
