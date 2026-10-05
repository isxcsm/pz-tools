using System.Globalization;
using System.Text;

namespace PzTools.Profiling;

/// <summary>The recording a report's range is compared with, analysed whole on the same kind of thread.</summary>
public sealed record ProfileReportBaseline(ProfileRecording Recording, ProfileRange Range, string? Name);

/// <summary>
/// The owner the player chose, given in full whether heavy or not: a mod (<see cref="ProfileRange.LuaGroups"/>' key) or a
/// Java area (<see cref="ProfileRange.MethodGroups"/>' key). A report meant for that mod's author has all it needs.
/// </summary>
public sealed record ProfileReportFocus(bool Java, string Key);

/// <summary>
/// A range's analysis as one Markdown report, to be pasted into a chat with an AI model: the same sections and limits
/// whatever the page has open, every figure said with what it is of, and a few lines on how to read them first. In
/// English with invariant numbers, as a format rather than a page: models read it as well whatever language the
/// player then asks in, and two reports read alike. Compared with another recording, each comparable figure carries
/// the other's beside it and the change.
/// </summary>
public static class ProfileReport
{
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
    // Enough to see where the time went, short enough to paste: the heaviest of each, the rest summed.
    private const int Mods = 12, ModsOpened = 5, FunctionsPerMod = 8, JavaMethods = 15, CallerMethods = 5, CallersPerMethod = 3,
        Allocators = 8, Pauses = 5, Threads = 8, Changes = 8;
    // One owner in full: more of its functions, the lines of the heaviest, and its call tree down to a hundredth of it.
    private const int FocusRows = 25, LineFunctions = 10, LinesPerFunction = 4, TreeDepth = 12, TreeSiblings = 6, TreeNodes = 120;
    private const double TreeFloor = 0.01;
    // Below this a share is noise in a sampled profile; such rows are left out of the per-mod and caller sections.
    private const double Noticeable = 0.005;

    /// <param name="thread">The thread the range was analysed for, as <see cref="ProfileAnalysis.Analyze"/>'s; -1 all.</param>
    /// <param name="name">The recording's name as the list shows it.</param>
    /// <param name="baseline">The recording compared with, if any.</param>
    /// <param name="focus">The owner chosen on the page, if any.</param>
    public static string Build(ProfileRecording recording, ProfileRange range, int thread, string? name = null,
        ProfileReportBaseline? baseline = null, ProfileReportFocus? focus = null)
    {
        var text = new StringBuilder();
        void Line(string line = "") => text.Append(line).Append('\n');
        var other = baseline?.Range;

        Line("# Project Zomboid performance recording (PZ Tools)");
        Line();
        Line("How to read: a sampling profile of the game's Java process (the engine) and its Lua scripts (mods and the "
            + "base game's own). Percentages are shares of the analysed range's wall-clock time on the analysed thread. "
            + "Self = time in the function itself; Total = including what it called. Figures are statistical: shares "
            + "under about 0.5% or from fewer than about 20 samples are noise.");
        if (focus is not null)
            Line($"This report is about one {(focus.Java ? "area of the game's Java code" : "mod")}, chosen in PZ Tools: "
                + "the recording, frames and memory below are the whole game's, for context; then that one in full.");
        if (baseline is not null)
            Line("This recording is compared with a baseline recording (below). Shares are parts of each recording's own range, "
                + "so recordings of different lengths compare; Change is this minus the baseline, in percentage points (pp) "
                + "for shares. A positive change is more time spent: worse.");
        Line();

        Line("## Recording");
        if (!string.IsNullOrWhiteSpace(name)) Line($"- Name: {name}");
        Describe(recording, Line);
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

        if (baseline is not null)
        {
            Line("## Baseline (compared with)");
            if (!string.IsNullOrWhiteSpace(baseline.Name)) Line($"- Name: {baseline.Name}");
            Describe(baseline.Recording, Line);
            Line("- Range analysed: the whole recording, on the same kind of thread");
            Line($"- Samples: {Count(baseline.Range.Samples)} Java, {Count(baseline.Range.LuaSamples)} Lua");
            if (baseline.Recording.Detailed != recording.Detailed)
                Line("- Caution: the two were recorded in different modes; detailed mode itself slows the game by about 20%, "
                    + "so frame times and shares differ by that much for no other reason.");
            Line();
        }

        Frames(range.Frames, other?.Frames, Line);
        Breakdown(range, other, Line);
        Memory(recording, range, baseline, Line);

        // One owner chosen: it alone in full, the rest of the game only as the lines above.
        if (focus is not null)
        {
            if (focus.Java) JavaFocus(recording, range, other, thread, focus.Key, Line);
            else LuaFocus(recording, range, other, focus.Key, Line);
            return text.ToString().TrimEnd() + "\n";
        }

        if (range.LuaGroups.Count > 0) Lua(recording, range, other, Line);
        else if (recording.LuaPeriod > 0) { Line("## Lua scripts"); Line("- No Lua ran in this range."); Line(); }

        if (range.MethodGroups.Count > 0) Java(recording, range, other, thread, Line);

        if (range.LuaAllocationGroups.Count > 0)
        {
            Line("## Memory allocated by Lua, by mod");
            Line("What each mod's scripts allocated while they ran: allocation drives the garbage collector.");
            if (range.GameThreadAllocated is { } all)
                Line($"Game thread allocated {Bytes(all)} in the range, {Bytes(range.LuaAllocated)} of it while running Lua.");
            // Bytes grow with a recording's length; per minute they compare.
            var minutes = Math.Max(1, range.End - range.Start) / 60_000_000.0;
            var otherMinutes = other is null ? 0 : Math.Max(1, other.End - other.Start) / 60_000_000.0;
            Line();
            Line(other is null ? "| Mod | Allocated |" : "| Mod | Allocated | Per minute | Baseline per minute |");
            Line(other is null ? "|---|---:|" : "|---|---:|---:|---:|");
            foreach (var group in range.LuaAllocationGroups.Take(Allocators))
            {
                if (other is null) { Line($"| {Cell(OwnerName(group.Key))} | {Bytes(group.Self)} |"); continue; }
                var before = other.LuaAllocationGroups.FirstOrDefault(item => item.Key.Equals(group.Key, StringComparison.OrdinalIgnoreCase));
                Line($"| {Cell(OwnerName(group.Key))} | {Bytes(group.Self)} | {Bytes((long)(group.Self / minutes))} | "
                    + (before is null ? (other.LuaAllocationGroups.Count == 0 ? "not measured" : "none") : Bytes((long)(before.Self / otherMinutes))) + " |");
            }
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

    private static void Describe(ProfileRecording recording, Action<string> line)
    {
        var kind = recording.Information.GetValueOrDefault("endedBy") == "rolling" ? ", the game's last minutes saved after the fact" : "";
        line(recording.Detailed
            ? $"- Mode: detailed (Lua lines and allocations measured; the measuring itself slows the game by about 20%){kind}"
            : $"- Mode: standard (low overhead){kind}");
        var started = recording.StartedUtc is { } utc ? $", started {utc.ToLocalTime():yyyy-MM-dd HH:mm}" : "";
        line($"- Length: {Seconds(recording.Duration)}{started}");
    }

    private static void Frames(ProfileFrameStatistics frames, ProfileFrameStatistics? before, Action<string> line)
    {
        if (frames.Count == 0) return;
        line("## Frames");
        if (before is not { Count: > 0 })
        {
            line($"- {Count(frames.Count)} frames, average {Ms(frames.AverageMilliseconds)} ({Fps(frames.AverageMilliseconds)}), "
                + $"median {Ms(frames.MedianMilliseconds)}, worst 1% {Ms(frames.OnePercentWorstMilliseconds)}, slowest {Ms(frames.SlowestMilliseconds)}");
            line("");
            return;
        }
        line("| Frame time | This | Baseline | Change |");
        line("|---|---:|---:|---:|");
        line($"| Average | {Ms(frames.AverageMilliseconds)} ({Fps(frames.AverageMilliseconds)}) | "
            + $"{Ms(before.AverageMilliseconds)} ({Fps(before.AverageMilliseconds)}) | {MsChange(frames.AverageMilliseconds - before.AverageMilliseconds)} |");
        line($"| Median | {Ms(frames.MedianMilliseconds)} | {Ms(before.MedianMilliseconds)} | {MsChange(frames.MedianMilliseconds - before.MedianMilliseconds)} |");
        line($"| Worst 1% | {Ms(frames.OnePercentWorstMilliseconds)} | {Ms(before.OnePercentWorstMilliseconds)} | "
            + $"{MsChange(frames.OnePercentWorstMilliseconds - before.OnePercentWorstMilliseconds)} |");
        line($"| Slowest | {Ms(frames.SlowestMilliseconds)} | {Ms(before.SlowestMilliseconds)} | {MsChange(frames.SlowestMilliseconds - before.SlowestMilliseconds)} |");
        line($"| Frames | {Count(frames.Count)} | {Count(before.Count)} | |");
        line("");
    }

    private static void Breakdown(ProfileRange range, ProfileRange? other, Action<string> line)
    {
        if (ProfileAnalysis.TimeBreakdown(range) is not { } breakdown || range.Samples < 20) return;
        line("## Where the analysed thread's time went");
        (string Name, string Meaning, Func<ProfileTimeBreakdown, double> Of)[] parts =
        [
            ("Lua scripts", "mods and base-game scripts, with the game code they called", part => part.Scripts),
            ("Game code", "the Java engine itself", part => part.GameCode),
            ("Stopped for memory", "garbage-collector pauses and waits for free memory", part => part.Collections),
            ("Not running", "waiting: for the next frame, for the GPU, for other threads", part => part.Waiting),
        ];
        if (other is not null && ProfileAnalysis.TimeBreakdown(other) is { } before && other.Samples >= 20)
        {
            line("| Part | This | Baseline | Change |");
            line("|---|---:|---:|---:|");
            foreach (var (part, meaning, of) in parts)
                line($"| {part} ({meaning}) | {Pct(of(breakdown))} | {Pct(of(before))} | {Pp(of(breakdown) - of(before))} |");
        }
        else
            foreach (var (part, meaning, of) in parts) line($"- {part} {Pct(of(breakdown))} ({meaning})");
        line("");
    }

    private static void Memory(ProfileRecording recording, ProfileRange range, ProfileReportBaseline? baseline, Action<string> line)
    {
        var lines = MemoryLines(recording, range);
        if (lines.Count == 0) return;
        line("## Memory and CPU");
        foreach (var item in lines) line(item);
        // The baseline's in a few words: the same measures, each for its whole recording.
        if (baseline is not null && MemoryFacts(baseline.Recording, baseline.Range) is { Count: > 0 } facts)
            line($"- Baseline: {string.Join("; ", facts)}");
        line("");
    }

    private static List<string> MemoryLines(ProfileRecording recording, ProfileRange range)
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
        return lines;
    }

    private static List<string> MemoryFacts(ProfileRecording recording, ProfileRange range)
    {
        var facts = new List<string>();
        var pressure = ProfileAnalysis.MemoryPressure(recording);
        if (ProfileAnalysis.MemoryPeaksIn(recording, range.Start, range.End).Heap is { } heap)
            facts.Add(pressure.MaximumBytes > 0 ? $"heap peak {Bytes(heap)} of {Bytes(pressure.MaximumBytes)} maximum" : $"heap peak {Bytes(heap)}");
        if (ProfileAnalysis.CollectorBusyIn(recording, range.Start, range.End) is { } busy) facts.Add($"collector at work {Pct(busy)}");
        var (stalls, _) = ProfileAnalysis.StallsIn(recording, range.Start, range.End);
        if (stalls > 0) facts.Add($"{Count(stalls)} allocation stalls");
        if (ProfileAnalysis.FramesWithCollector(recording)?.Slower is { } slower) facts.Add($"frames {Pct(slower)} slower while it worked");
        if (recording.Heap.Count > 0) facts.Add(pressure.Short ? "short of memory" : "not short of memory");
        if (ProfileAnalysis.OtherProgramsCpu(recording) is { } other) facts.Add($"other programs {Pct(other)} of the processors");
        return facts;
    }

    private static void Lua(ProfileRecording recording, ProfileRange range, ProfileRange? other, Action<string> line)
    {
        ProfileGroup? Before(string key) => other?.LuaGroups.FirstOrDefault(group => group.Key.Equals(key, StringComparison.OrdinalIgnoreCase));
        line("## Lua scripts by mod");
        line($"All Lua together: {Pct(range.LuaShare)} of the range"
            + (other is null ? "" : $" (baseline {Pct(other.LuaShare)}, {Pp(range.LuaShare - other.LuaShare)})")
            + ". Each mod's share is its functions' own time.");
        line("");
        line(other is null ? "| # | Mod | Share | Samples |" : "| # | Mod | Share | Samples | Baseline | Change |");
        line(other is null ? "|---:|---|---:|---:|" : "|---:|---|---:|---:|---:|---:|");
        var shown = range.LuaGroups.Take(Mods).ToArray();
        for (var index = 0; index < shown.Length; index++)
        {
            var group = shown[index];
            var compared = other is null ? "" : Before(group.Key) is { } before ? $" {Pct(before.Self)} | {Pp(group.Self - before.Self)} |" : " none | new |";
            line($"| {index + 1} | {Cell(OwnerName(group.Key))} | {Pct(group.Self)} | {Count(group.Samples)} |{compared}");
        }
        if (range.LuaGroups.Count > Mods)
        {
            var rest = range.LuaGroups.Skip(Mods).ToArray();
            line($"| | {rest.Length} more | {Pct(rest.Sum(group => group.Self))} | {Count(rest.Sum(group => group.Samples))} |{(other is null ? "" : " | |")}");
        }
        line("");

        // What moved the most either way, mods the baseline ran and this one did not among them.
        if (other is not null)
        {
            var changes = range.LuaGroups.Select(group => (group.Key, Delta: group.Self - (Before(group.Key)?.Self ?? 0)))
                .Concat(other.LuaGroups.Where(group => !range.LuaGroups.Any(item => item.Key.Equals(group.Key, StringComparison.OrdinalIgnoreCase)))
                    .Select(group => (group.Key, Delta: -group.Self)))
                .Where(change => Math.Abs(change.Delta) >= Noticeable / 2)
                .OrderByDescending(change => Math.Abs(change.Delta)).Take(Changes).ToArray();
            if (changes.Length > 0)
            {
                line("Biggest changes against the baseline:");
                foreach (var (key, delta) in changes)
                    line($"- {OwnerName(key)}: {Pp(delta)}"
                        + (range.LuaGroups.Any(group => group.Key.Equals(key, StringComparison.OrdinalIgnoreCase)) ? "" : " (did not run in this recording)")
                        + (Before(key) is null ? " (did not run in the baseline)" : ""));
                line("");
            }
        }

        foreach (var group in range.LuaGroups.Take(ModsOpened).Where(group => group.Self >= Noticeable))
        {
            line($"### {OwnerName(group.Key)}: {Pct(group.Self)} of the range");
            FunctionTable(recording, range, group, Before(group.Key), other is not null, FunctionsPerMod, line);
        }
    }

    /// <summary>
    /// One mod in full, for its author or a model asked about it: its functions, their heaviest lines, the call tree
    /// that reached them, and what they allocated. The rest of the game is the report's few lines above.
    /// </summary>
    private static void LuaFocus(ProfileRecording recording, ProfileRange range, ProfileRange? other, string key, Action<string> line)
    {
        var group = range.LuaGroups.FirstOrDefault(item => item.Key.Equals(key, StringComparison.OrdinalIgnoreCase));
        var before = other?.LuaGroups.FirstOrDefault(item => item.Key.Equals(key, StringComparison.OrdinalIgnoreCase));
        line($"## The mod: {OwnerName(key)}");
        if (group is null)
        {
            line("- None of its scripts ran in this range." + (before is null ? "" : $" In the baseline: {Pct(before.Self)} of the range."));
            line("");
            return;
        }
        var rank = range.LuaGroups.ToList().IndexOf(group) + 1;
        line($"- {Pct(group.Self)} of the range in its own functions ({Count(group.Samples)} samples), #{rank} of "
            + $"{range.LuaGroups.Count} script owners; all Lua together {Pct(range.LuaShare)}");
        if (other is not null)
            line(before is null ? "- Baseline: it did not run there." : $"- Baseline: {Pct(before.Self)} of the range, a change of {Pp(group.Self - before.Self)}");
        line("");

        line("### Functions");
        FunctionTable(recording, range, group, before, other is not null, FocusRows, line);

        // Where inside the heaviest functions: the lines they ran themselves, each sample of the owner an equal slice.
        var functions = FunctionIndexes(recording);
        var owned = range.LuaLines.GetValueOrDefault(group.Key);
        var perSample = group.Samples > 0 ? group.Self / group.Samples : 0;
        var lineRows = new List<string>();
        foreach (var row in group.Rows.Take(LineFunctions))
        {
            if (!functions.TryGetValue((row.Name, row.Detail), out var function) || owned?.GetValueOrDefault(function) is not { } lines) continue;
            // A line under a hundredth of a percent would read 0.00%: nothing to look at.
            var heaviest = lines.Where(item => item.Line > 0 && item.SelfSamples * perSample >= 0.00005)
                .OrderByDescending(item => item.SelfSamples).Take(LinesPerFunction).ToArray();
            if (heaviest.Length == 0) continue;
            lineRows.Add($"- {FunctionName(row.Name)} ({FileName(row.Detail)}): "
                + string.Join(", ", heaviest.Select(item => $"line {item.Line.ToString(Invariant)} {Pct(item.SelfSamples * perSample)}")));
        }
        if (lineRows.Count > 0)
        {
            line("### Heaviest lines of the heaviest functions");
            line("A line's own time: the function running that line itself, not what it called from there.");
            foreach (var item in lineRows) line(item);
            line("");
        }

        if (range.LuaCallTrees.GetValueOrDefault(group.Key) is { Samples: > 0 } tree)
        {
            line("### Call tree");
            line("How the mod's functions were reached: outermost first, each function under the one that called it, with its total "
                + "(including what it called) and its own time, and the caller's line it was called from. Only samples that "
                + "ended in this mod's functions are counted; small branches are summed up.");
            line("");
            var floor = Math.Max(tree.Total * TreeFloor, 0.0001);
            var written = 0;
            void Walk(ProfileCallNode node, int depth)
            {
                var indent = new string(' ', depth * 2);
                var shown = node.Children.Where(child => child.Total >= floor).Take(TreeSiblings).ToArray();
                foreach (var child in shown)
                {
                    if (written >= TreeNodes) return;
                    written++;
                    var at = child.Lines.Where(item => item.Line > 0 && item.SelfSamples > 0).MaxBy(item => item.SelfSamples) is { } main
                        ? ":" + main.Line.ToString(Invariant) : "";
                    var from = child.CalledFromLine > 0 ? $", called at line {child.CalledFromLine.ToString(Invariant)}" : "";
                    line($"{indent}- {FunctionName(child.Name)} ({FileName(child.File)}{at}) total {Pct(child.Total)}, self {Pct(child.Self)}{from}");
                    if (depth + 1 < TreeDepth) Walk(child, depth + 1);
                }
                var rest = node.Children.Except(shown).ToArray();
                if (rest.Length > 0 && rest.Sum(child => child.Total) >= floor && written < TreeNodes)
                    line($"{indent}- {rest.Length} more, total {Pct(rest.Sum(child => child.Total))}");
            }
            Walk(tree, 0);
            line("");

            if (tree.AllocatedTotal > 0)
            {
                var minutes = Math.Max(1, range.End - range.Start) / 60_000_000.0;
                line("### Memory it allocated");
                line($"- {Bytes(tree.AllocatedTotal)} in the range ({Bytes((long)(tree.AllocatedTotal / minutes))} a minute)"
                    + (range.LuaAllocated > 0 ? $", {Pct((double)tree.AllocatedTotal / range.LuaAllocated)} of all Lua's" : ""));
                var allocators = ProfileAnalysis.FunctionsIn(tree).Where(row => row.AllocatedSelf > 0)
                    .OrderByDescending(row => row.AllocatedSelf).Take(Allocators).ToArray();
                if (allocators.Length > 0)
                {
                    line("");
                    line("| Function | File | Allocated itself |");
                    line("|---|---|---:|");
                    foreach (var row in allocators) line($"| {Cell(FunctionName(row.Name))} | {Cell(row.File)} | {Bytes(row.AllocatedSelf)} |");
                }
                line("");
            }
        }
    }

    // A mod's functions as a table: the file with the line each ran itself the most, and compared, the change.
    private static void FunctionTable(ProfileRecording recording, ProfileRange range, ProfileGroup group, ProfileGroup? baseline,
        bool comparing, int rows, Action<string> line)
    {
        var functions = FunctionIndexes(recording);
        // The same function in the baseline by its name and its file from media/lua on, as a mod moved stays itself.
        var before = baseline?.Rows.GroupBy(row => ProfileAnalysis.ScriptKey(row.Name, row.Detail))
            .ToDictionary(same => same.Key, same => same.Sum(row => row.Self));
        line(comparing ? "| Function | File:line | Self | Total | Self change |" : "| Function | File:line | Self | Total |");
        line(comparing ? "|---|---|---:|---:|---:|" : "|---|---|---:|---:|");
        var lines = range.LuaLines.GetValueOrDefault(group.Key);
        foreach (var row in group.Rows.Take(rows))
        {
            var at = functions.TryGetValue((row.Name, row.Detail), out var function)
                && lines?.GetValueOrDefault(function) is { Count: > 0 } own
                && own.MaxBy(item => item.SelfSamples) is { Line: > 0, SelfSamples: > 0 } heaviest
                    ? ":" + heaviest.Line.ToString(Invariant) : "";
            var change = !comparing ? ""
                : before?.TryGetValue(ProfileAnalysis.ScriptKey(row.Name, row.Detail), out var was) == true ? $" {Pp(row.Self - was)} |" : " new |";
            line($"| {Cell(FunctionName(row.Name))} | {Cell(row.Detail + at)} | {Pct(row.Self)} | {Pct(row.Total)} |{change}");
        }
        if (group.Rows.Count > rows)
            line($"| {group.Rows.Count - rows} more | | {Pct(group.Rows.Skip(rows).Sum(row => row.Self))} | |{(comparing ? " |" : "")}");
        line("");
    }

    private static Dictionary<(string, string), int> FunctionIndexes(ProfileRecording recording)
    {
        var functions = new Dictionary<(string, string), int>();
        for (var index = 0; index < recording.LuaFunctions.Count; index++)
            functions.TryAdd((recording.LuaFunctions[index].Name, recording.LuaFunctions[index].File), index);
        return functions;
    }

    private static void Java(ProfileRecording recording, ProfileRange range, ProfileRange? other, int thread, Action<string> line)
    {
        line("## Java (engine) by area");
        line(other is null ? "| Area | Self |" : "| Area | Self | Baseline | Change |");
        line(other is null ? "|---|---:|" : "|---|---:|---:|---:|");
        foreach (var group in range.MethodGroups)
        {
            var before = other?.MethodGroups.FirstOrDefault(item => item.Key == group.Key)?.Self ?? 0;
            line($"| {Cell(AreaName(group.Key))} | {Pct(group.Self)} |{(other is null ? "" : $" {Pct(before)} | {Pp(group.Self - before)} |")}");
        }
        line("");
        line("## Heaviest Java methods");
        MethodTable(range.Methods, other, JavaMethods, "Total", line);
        Callers(recording, range, thread, range.Methods.Take(CallerMethods), line);
    }

    /// <summary>One Java area in full: its methods, Total counting only what ran inside it, and who called the heaviest.</summary>
    private static void JavaFocus(ProfileRecording recording, ProfileRange range, ProfileRange? other, int thread, string key, Action<string> line)
    {
        var area = range.MethodGroups.FirstOrDefault(group => group.Key == key);
        var before = other?.MethodGroups.FirstOrDefault(group => group.Key == key);
        line($"## The Java area: {AreaName(key)}");
        if (area is not { Rows.Count: > 0 }) { line("- It did not run in this range."); line(""); return; }
        line($"- {Pct(area.Self)} of the range in its own methods"
            + (other is null ? "" : before is null ? "; it did not run in the baseline" : $"; baseline {Pct(before.Self)}, a change of {Pp(area.Self - before.Self)}"));
        line("");
        line("### Methods");
        MethodTable(area.Rows, other, FocusRows, "Total in the area", line);
        Callers(recording, range, thread, area.Rows.Take(CallerMethods), line);
    }

    private static void MethodTable(IReadOnlyList<ProfileShare> methods, ProfileRange? other, int rows, string total, Action<string> line)
    {
        var before = other?.Methods.GroupBy(method => method.Name, StringComparer.Ordinal).ToDictionary(same => same.Key, same => same.First().Self, StringComparer.Ordinal);
        line(before is null ? $"| Method | Self | {total} |" : $"| Method | Self | {total} | Self change |");
        line(before is null ? "|---|---:|---:|" : "|---|---:|---:|---:|");
        foreach (var method in methods.Take(rows))
        {
            var change = before is null ? "" : before.TryGetValue(method.Name, out var was) ? $" {Pp(method.Self - was)} |" : " new |";
            line($"| {Cell(method.Name)} | {Pct(method.Self)} | {Pct(method.Total)} |{change}");
        }
        if (methods.Count > rows) line($"| {methods.Count - rows} more | {Pct(methods.Skip(rows).Sum(method => method.Self))} | |{(before is null ? "" : " |")}");
        line("");
    }

    // A JDK or library method's time read in the game's terms: who called it, up to the game's own code.
    private static void Callers(ProfileRecording recording, ProfileRange range, int thread, IEnumerable<ProfileShare> methods, Action<string> line)
    {
        var heavy = methods.Where(method => method.Self >= Noticeable).ToArray();
        if (heavy.Length == 0) return;
        line("## Who called the heaviest methods");
        line("Each line: the method, then its callers nearest first (A <- B: B called A), with the share of the range through that path. "
            + "(Lua code running) means a script called it; which scripts ran is in the Lua sections.");
        line("");
        foreach (var method in heavy)
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

    private static string FunctionName(string name) => name is "" or "?" ? "(anonymous)" : name;

    private static string FileName(string file)
    {
        var slash = file.Replace('\\', '/').LastIndexOf('/');
        return slash < 0 ? file : file[(slash + 1)..];
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
    private static string Pp(double change) => (change * 100).ToString("+0.00;-0.00;0.00", Invariant) + " pp";
    private static string Ms(double milliseconds) => milliseconds.ToString("0.0", Invariant) + " ms";
    private static string MsChange(double milliseconds) => milliseconds.ToString("+0.0;-0.0;0.0", Invariant) + " ms";
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
