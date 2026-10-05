namespace PzTools.Profiling;

/// <summary>
/// One row of a breakdown. <see cref="Self"/> is time spent in the item itself, <see cref="Total"/>
/// includes what it called; both are shares (0..1) of the range. <see cref="Samples"/> is how many
/// samples the row rests on, so the reader can tell a measurement from a guess.
/// </summary>
public sealed record ProfileShare(string Name, string Detail, double Self, double Total, int Samples);

/// <summary>Rows that belong together: the game's own code, one mod, the Java runtime. Largest rows first.</summary>
public sealed record ProfileGroup(string Key, double Self, int Samples, IReadOnlyList<ProfileShare> Rows);

/// <summary>
/// One row of the allocation breakdown, in bytes the game thread allocated: <see cref="Self"/> while the function itself
/// was running, <see cref="Total"/> while it was anywhere on the stack. Each sample's bytes go to what it found running,
/// so like the shares of time these are estimates; <see cref="Samples"/> is how many samples carry <see cref="Self"/>.
/// </summary>
public sealed record ProfileAllocation(string Name, string Detail, long Self, long Total, int Samples);

/// <summary>A mod's (or the game's scripts') allocations, largest first.</summary>
public sealed record ProfileAllocationGroup(string Key, long Self, int Samples, IReadOnlyList<ProfileAllocation> Rows);

/// <summary>
/// One function on one call path, top down: the root's children are the outermost functions (such as an event
/// handler), each node's children what it called. <see cref="Samples"/> counts the samples that passed through this
/// node, <see cref="SelfSamples"/> those that ended in it; the shares and bytes follow the same split.
/// </summary>
public sealed class ProfileCallNode
{
    private readonly Dictionary<int, ProfileCallNode> byFunction = [];
    private ProfileCallNode[] children = [];

    internal ProfileCallNode(int function, string name, string file) { Function = function; Name = name; File = file; }

    /// <summary>Index into <see cref="ProfileRecording.LuaFunctions"/>; -1 for the root, which stands for no function.</summary>
    public int Function { get; }
    public string Name { get; }
    public string File { get; }
    public int Samples { get; private set; }
    public int SelfSamples { get; private set; }
    public double Total { get; private set; }
    public double Self { get; private set; }
    public long AllocatedTotal { get; private set; }
    public long AllocatedSelf { get; private set; }
    /// <summary>Most samples first.</summary>
    public IReadOnlyList<ProfileCallNode> Children => children;

    internal ProfileCallNode Child(int function, ProfileRecording recording)
    {
        if (byFunction.TryGetValue(function, out var child)) return child;
        var source = recording.LuaFunctions[function];
        return byFunction[function] = new ProfileCallNode(function, source.Name, source.File);
    }

    /// <summary>
    /// The lines the function was at on this path, most samples first: each sample through the node was at one of
    /// them, so their samples add up to the node's. Empty for the root.
    /// </summary>
    public IReadOnlyList<ProfileLineTotal> Lines { get; private set; } = [];
    private Dictionary<int, LineCount>? lineCounts;

    /// <summary>The line of the function above it that called it most often on this path; 0 for an outermost one.</summary>
    public int CalledFromLine { get; private set; }
    private Dictionary<int, int>? callerLines;

    internal void CountCaller(int line, int samples)
    {
        if (line <= 0) return;
        callerLines ??= [];
        callerLines[line] = callerLines.GetValueOrDefault(line) + samples;
    }

    /// <summary><paramref name="samples"/> more samples through this node, with the bytes they allocated together.</summary>
    internal void Count(int samples, bool self, long allocated, int line = -1)
    {
        Samples += samples;
        if (self) SelfSamples += samples;
        if (line >= 0) (lineCounts ??= []).Add(line, samples, self, allocated);
        AllocatedTotal += allocated;
        if (self) AllocatedSelf += allocated;
    }

    internal void Finish(double perSample)
    {
        Total = Math.Min(1, Samples * perSample);
        Self = Math.Min(1, SelfSamples * perSample);
        children = byFunction.Values.OrderByDescending(node => node.Samples).ThenBy(node => node.Name, StringComparer.Ordinal).ToArray();
        if (lineCounts is not null) Lines = ProfileLineTotals.Ordered(lineCounts);
        lineCounts = null;
        if (callerLines is not null)
            CalledFromLine = callerLines.OrderByDescending(item => item.Value).ThenBy(item => item.Key).First().Key;
        callerLines = null;
        foreach (var child in children) child.Finish(perSample);
    }
}

/// <summary>A line's counts while they are added up; <see cref="ProfileLineTotal"/> is made once, at the end.</summary>
internal sealed class LineCount
{
    public int SelfSamples, Samples;
    public long AllocatedSelf, AllocatedTotal;
}

internal static class ProfileLineTotals
{
    /// <summary>
    /// <paramref name="samples"/> more samples at <paramref name="line"/>, with the bytes they allocated together;
    /// <paramref name="self"/> when they were running the line itself.
    /// </summary>
    public static void Add(this Dictionary<int, LineCount> lines, int line, int samples, bool self, long allocated)
    {
        if (!lines.TryGetValue(line, out var count)) lines[line] = count = new LineCount();
        count.Samples += samples;
        count.AllocatedTotal += allocated;
        if (!self) return;
        count.SelfSamples += samples;
        count.AllocatedSelf += allocated;
    }

    public static ProfileLineTotal[] Ordered(Dictionary<int, LineCount> lines) =>
        lines.Select(item => new ProfileLineTotal(item.Key, item.Value.SelfSamples, item.Value.Samples, item.Value.AllocatedSelf, item.Value.AllocatedTotal))
            .OrderByDescending(line => line.Samples).ThenByDescending(line => line.SelfSamples).ThenBy(line => line.Line).ToArray();
}

/// <summary>
/// One function of a call tree, its paths added up: <see cref="SelfSamples"/> ended in it, <see cref="Samples"/> passed
/// through it (a recursive call counted once per sample). The same samples as the tree, so the same whole.
/// </summary>
public sealed record ProfileFunctionTotal(int Function, string Name, string File, int SelfSamples, int Samples,
    long AllocatedSelf, long AllocatedTotal);

/// <summary>
/// One line of a Lua function: <see cref="Samples"/> found it at that line, whatever it had called from there (once
/// per sample, however often a recursion passed the line); <see cref="SelfSamples"/> found it running that line
/// itself, the innermost frame, so a function's lines' self samples add up to its own. Line 0 is a frame the
/// interpreter gave no line for.
/// </summary>
public sealed record ProfileLineTotal(int Line, int SelfSamples, int Samples, long AllocatedSelf, long AllocatedTotal);

public sealed record ProfileFrameStatistics(int Count, double AverageMilliseconds, double MedianMilliseconds,
    double SlowestMilliseconds, double OnePercentWorstMilliseconds);

/// <summary>A thread's time in a range by what it was doing, as shares of the range adding up to one.</summary>
public sealed record ProfileTimeBreakdown(double Scripts, double GameCode, double Collections, double Waiting);
/// <summary>
/// Who called a method, bottom up: one row per caller, the heaviest first, each opening onto its own callers. A chain of
/// callers that never branches is one row (<see cref="Methods"/>, nearest first), up to the first of the game's own code:
/// a JDK or library method's time read in the game's terms. <see cref="Share"/> is of the range, as the method's.
/// </summary>
public sealed class ProfileCallerNode
{
    internal readonly Dictionary<int, ProfileCallerNode> ByMethod = [];
    internal ProfileCallerNode(int method) { MethodIndexes = [method]; }
    internal List<int> MethodIndexes { get; }
    /// <summary>The methods of this row, nearest caller first; the method itself for the root.</summary>
    public IReadOnlyList<string> Methods { get; internal set; } = [];
    public double Share { get; internal set; }
    public int Samples { get; internal set; }
    /// <summary>Heaviest first.</summary>
    public IReadOnlyList<ProfileCallerNode> Callers { get; internal set; } = [];
    /// <summary>Whether the row ends at the game's own code: where reading up from a library method stops by itself.</summary>
    public bool ReachesGame { get; internal set; }
}

/// <summary>Frames' average length, in milliseconds, while the collector was at work and while it was not, with how many of each.</summary>
public sealed record ProfileCollectorFrames(double During, int DuringCount, double Outside, int OutsideCount)
{
    /// <summary>How much longer frames were with the collector at work, 0.17 for 17%; null with too few of either to say.</summary>
    public double? Slower => DuringCount >= 20 && OutsideCount >= 20 && Outside > 0 ? During / Outside - 1 : null;
}

/// <summary>How short of memory the game ran: its allocation stalls, and the share of heap readings near the maximum.</summary>
/// <param name="StalledMicroseconds">The stalls' time, added up.</param>
/// <param name="FullShare">The share of heap readings at or above <see cref="ProfileAnalysis.NearlyFull"/> of the maximum.</param>
/// <param name="MaximumBytes">The largest heap the game could grow to.</param>
public sealed record ProfileMemoryPressure(int Stalls, long StalledMicroseconds, double FullShare, long MaximumBytes)
{
    /// <summary>Short enough of memory to suggest more.</summary>
    public bool Short => Stalls > 0 || FullShare >= 0.25;
}

public sealed record ProfileRange(
    long Start, long End,
    ProfileFrameStatistics Frames,
    // Samples of the chosen thread(s) inside the range.
    int Samples,
    IReadOnlyList<ProfileShare> Methods,
    IReadOnlyList<ProfileGroup> MethodGroups,
    IReadOnlyList<ProfileShare> Threads,
    // Share of the range the game spent running Lua (mods and the game's own scripts).
    double LuaShare,
    int LuaSamples,
    IReadOnlyList<ProfileShare> LuaFunctions,
    IReadOnlyList<ProfileShare> LuaOwners,
    IReadOnlyList<ProfileGroup> LuaGroups,
    int Collections,
    double CollectionPauseMilliseconds,
    IReadOnlyList<ProfilePause> LongestPauses)
{
    /// <summary>Allocations by mod; empty when the recording has none.</summary>
    public IReadOnlyList<ProfileAllocationGroup> LuaAllocationGroups { get; init; } = [];
    /// <summary>Bytes the game thread allocated while running Lua, all owners together.</summary>
    public long LuaAllocated { get; init; }
    /// <summary>Bytes the game thread allocated in the range, in Lua or not; null without readings.</summary>
    public long? GameThreadAllocated { get; init; }
    /// <summary>Samples of the chosen thread(s) left out because the thread was only waiting inside a native call.</summary>
    public int WaitingSamples { get; init; }
    /// <summary>
    /// The share of the range the one chosen thread was running, by its samples' periods; null for all threads together,
    /// whose times overlap.
    /// </summary>
    public double? RunningShare { get; init; }
    /// <summary>
    /// How long, inside the range, the chosen thread was stopped for memory: the collector's pauses, which stop every
    /// thread, and the thread's own allocation stalls, overlaps counted once. Null in recordings without the pauses.
    /// </summary>
    public double? MemoryStopMilliseconds { get; init; }
    /// <summary>
    /// Per owner (the keys of <see cref="LuaGroups"/>), the call paths of the samples that ended in its functions, as a
    /// tree under a root: its outermost functions sum to the owner's own samples, as its row in the list does.
    /// </summary>
    public IReadOnlyDictionary<string, ProfileCallNode> LuaCallTrees { get; init; } = new Dictionary<string, ProfileCallNode>();
    /// <summary>
    /// Per owner, the same samples by each function's lines: each line a function was at counts a sample once (a
    /// recursion passing it again included), and the innermost frame is the line being run. The list's functions open
    /// into these, and each shows its heaviest.
    /// </summary>
    public IReadOnlyDictionary<string, IReadOnlyDictionary<int, IReadOnlyList<ProfileLineTotal>>> LuaLines { get; init; } =
        new Dictionary<string, IReadOnlyDictionary<int, IReadOnlyList<ProfileLineTotal>>>();
}

/// <summary>Answers "what was the game doing between these two moments" from a loaded recording.</summary>
public static class ProfileAnalysis
{
    public const string GameOwner = "(game)";
    public const string UnknownOwner = "(unknown)";
    /// <summary>Keys of <see cref="ProfileRange.MethodGroups"/>.</summary>
    public const string GameCode = "game", LuaRuntime = "lua", JavaRuntime = "java", Tools = "tools", Libraries = "libraries";

    /// <param name="thread">Index into <see cref="ProfileRecording.Threads"/>; -1 for every thread together.</param>
    /// <param name="cancellation">Stops an analysis nobody waits for any more (a newer range was chosen); checked
    /// every few thousand samples, so a long recording's analysis ends within milliseconds.</param>
    public static ProfileRange Analyze(ProfileRecording recording, long start, long end, int thread, int maximumRows = 40,
        CancellationToken cancellation = default)
    {
        if (end < start) (start, end) = (end, start);
        start = Math.Max(0, start);
        end = Math.Max(start + 1, Math.Min(Math.Max(recording.Duration, 1), end));

        // A sample stands for the time until the next one of its kind, so its weight is that period. The same few
        // hundred stacks make up almost every sample: they are counted first, each stack and kind once, and each stack
        // is then walked once for all its samples.
        var samples = recording.Samples;
        var first = LowerBound(samples, start, sample => sample.Time);
        var stackCount = recording.Stacks.Count;
        var javaOn = new int[stackCount];
        var nativeOn = new int[stackCount];
        var threadWeight = new double[recording.Threads.Count];
        var threadCount = new int[recording.Threads.Count];
        // A thread inside a native call is sampled whether it works there (drawing, reading a file) or only waits (for
        // a connection, a timer, an event). The waits are left out, so a thread's share is time it ran.
        var waits = new bool?[stackCount];
        var waiting = 0;
        for (var index = first; index < samples.Length && samples[index].Time < end; index++)
        {
            if ((index & 4095) == 0) cancellation.ThrowIfCancellationRequested();
            var sample = samples[index];
            if (sample.Native && (waits[sample.Stack] ??= Waits(recording, recording.Stacks[sample.Stack])))
            {
                if (thread < 0 || sample.Thread == thread) waiting++;
                continue;
            }
            threadWeight[sample.Thread] += sample.Native ? recording.NativePeriod : recording.JavaPeriod;
            threadCount[sample.Thread]++;
            if (thread >= 0 && sample.Thread != thread) continue;
            if (sample.Native) nativeOn[sample.Stack]++; else javaOn[sample.Stack]++;
        }
        var methodCount = recording.Methods.Count;
        var selfWeight = new double[methodCount];
        var selfCount = new int[methodCount];
        var totalWeight = new double[methodCount];
        // Per method, its total over the samples that ended in its own group's code: a group's table counts its own
        // samples only, as a script owner's does, so a total never exceeds the group.
        var totalInGroup = new double[methodCount];
        var groupOf = new string?[methodCount];
        var counted = new List<int>();
        // Recursion must not count one sample twice for the same method: a method is marked with the stack it was
        // last counted for.
        var seenFor = new int[methodCount];
        double weightSum = 0;
        var count = 0;
        for (var stackIndex = 0; stackIndex < stackCount; stackIndex++)
        {
            var on = javaOn[stackIndex] + nativeOn[stackIndex];
            if (on == 0) continue;
            double weight = javaOn[stackIndex] * (double)recording.JavaPeriod + nativeOn[stackIndex] * (double)recording.NativePeriod;
            count += on;
            weightSum += weight;
            var stack = recording.Stacks[stackIndex];
            if (stack.Length == 0) continue;
            selfWeight[stack[0]] += weight;
            selfCount[stack[0]] += on;
            var group = groupOf[stack[0]] ??= GroupOf(recording.Methods[stack[0]]);
            foreach (var method in stack)
            {
                if (seenFor[method] == stackIndex + 1) continue;
                seenFor[method] = stackIndex + 1;
                if (totalWeight[method] == 0) counted.Add(method);
                totalWeight[method] += weight;
                if ((groupOf[method] ??= GroupOf(recording.Methods[method])) == group) totalInGroup[method] += weight;
            }
        }
        var indexed = counted
            .Select(method => (Method: method, Row: new ProfileShare(recording.Methods[method], "", selfWeight[method] / Math.Max(1, weightSum),
                totalWeight[method] / Math.Max(1, weightSum), selfCount[method])))
            .OrderByDescending(item => item.Row.Self).ThenByDescending(item => item.Row.Total).ThenBy(item => item.Row.Name, StringComparer.Ordinal)
            .ToArray();
        var allMethods = indexed.Select(item => item.Row).ToArray();
        var methods = allMethods.Take(maximumRows).ToArray();
        // A sample belongs to the group of the code that was actually running, so group shares add up to the whole. A
        // group's rows are its own methods, their totals over its own samples (still shares of the whole), so the
        // group's figure bounds them; a method that only called into other groups has none and is left out.
        var methodGroups = indexed.GroupBy(item => groupOf[item.Method] ??= GroupOf(item.Row.Name))
            .Select(group =>
            {
                var rows = group
                    .Select(item => item.Row with { Total = totalInGroup[item.Method] / Math.Max(1, weightSum) })
                    .Where(row => row.Total > 0)
                    .OrderByDescending(row => row.Self).ThenByDescending(row => row.Total).ThenBy(row => row.Name, StringComparer.Ordinal);
                return new ProfileGroup(group.Key, group.Sum(item => item.Row.Self), group.Sum(item => item.Row.Samples), rows.Take(maximumRows).ToArray());
            })
            .Where(group => group.Samples > 0)
            .OrderByDescending(group => group.Self).ThenBy(group => group.Key, StringComparer.Ordinal).ToArray();
        var allThreads = threadWeight.Sum();
        var threads = Enumerable.Range(0, threadWeight.Length).Where(index => threadCount[index] > 0)
            .Select(index => new ProfileShare(recording.Threads[index], "", threadWeight[index] / Math.Max(1, allThreads),
                threadWeight[index] / Math.Max(1, allThreads), threadCount[index]))
            .OrderByDescending(row => row.Self).ThenBy(row => row.Name, StringComparer.Ordinal).Take(maximumRows).ToArray();

        // Lua the same way: each stack's samples counted, with the bytes they allocated, then each stack walked once.
        var lua = recording.LuaSamples;
        var luaStackCount = recording.LuaStacks.Count;
        var luaOn = new int[luaStackCount];
        var allocatedOn = new long[luaStackCount];
        var allocationsOn = new int[luaStackCount];
        for (var index = LowerBound(lua, start, sample => sample.Time); index < lua.Length && lua[index].Time < end; index++)
        {
            if ((index & 4095) == 0) cancellation.ThrowIfCancellationRequested();
            var sample = lua[index];
            luaOn[sample.Stack]++;
            if (sample.Allocated < 0) continue;
            allocatedOn[sample.Stack] += sample.Allocated;
            allocationsOn[sample.Stack]++;
        }
        var functionCount = recording.LuaFunctions.Count;
        var functionSelf = new int[functionCount];
        var functionTotal = new int[functionCount];
        var functionsCounted = new List<int>();
        var ownerSelf = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var ownerTotal = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var luaCount = 0;
        var owners = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var ownerOf = FunctionOwners(recording);
        // Bytes the game thread allocated, given to the functions each sample found, the way its time is; only
        // functions some sample with a known figure found are in the allocation tab.
        var allocatedSelf = new long[functionCount];
        var allocationsSelf = new int[functionCount];
        var allocatedTotal = new long[functionCount];
        var allocationCounted = new bool[functionCount];
        long luaAllocated = 0;
        var callTrees = new Dictionary<string, ProfileCallNode>(StringComparer.OrdinalIgnoreCase);
        var lineCounts = new Dictionary<string, Dictionary<int, Dictionary<int, LineCount>>>(StringComparer.OrdinalIgnoreCase);
        var functionSeenFor = new int[functionCount];
        var seenLines = new HashSet<(int Function, int Line)>();
        for (var stackIndex = 0; stackIndex < luaStackCount; stackIndex++)
        {
            var on = luaOn[stackIndex];
            if (on == 0) continue;
            if ((stackIndex & 1023) == 0) cancellation.ThrowIfCancellationRequested();
            var stack = recording.LuaStacks[stackIndex];
            if (stack.Length == 0) continue;
            luaCount += on;
            var innermost = stack[0].Function;
            functionSelf[innermost] += on;
            var allocated = allocatedOn[stackIndex];
            var known = allocationsOn[stackIndex] > 0;
            if (known)
            {
                luaAllocated += allocated;
                allocatedSelf[innermost] += allocated;
                allocationsSelf[innermost] += allocationsOn[stackIndex];
            }
            owners.Clear();
            for (var depth = 0; depth < stack.Length; depth++)
            {
                var function = stack[depth].Function;
                if (functionSeenFor[function] != stackIndex + 1)
                {
                    functionSeenFor[function] = stackIndex + 1;
                    if (functionTotal[function] == 0) functionsCounted.Add(function);
                    functionTotal[function] += on;
                    if (known)
                    {
                        allocatedTotal[function] += allocated;
                        allocationCounted[function] = true;
                    }
                }
                var owner = ownerOf[function];
                if (depth == 0) ownerSelf[owner] = ownerSelf.GetValueOrDefault(owner) + on;
                if (owners.Add(owner)) ownerTotal[owner] = ownerTotal.GetValueOrDefault(owner) + on;
            }
            // The samples' path, outermost first, in the tree of the owner whose function they ended in.
            var innermostOwner = ownerOf[innermost];
            if (!lineCounts.TryGetValue(innermostOwner, out var ownerLines)) lineCounts[innermostOwner] = ownerLines = [];
            seenLines.Clear();
            for (var depth = 0; depth < stack.Length; depth++)
            {
                var frame = stack[depth];
                if (!seenLines.Add((frame.Function, frame.Line))) continue;
                if (!ownerLines.TryGetValue(frame.Function, out var lines)) ownerLines[frame.Function] = lines = [];
                lines.Add(frame.Line, on, depth == 0, allocated);
            }
            if (!callTrees.TryGetValue(innermostOwner, out var node))
                callTrees[innermostOwner] = node = new ProfileCallNode(-1, innermostOwner, "");
            node.Count(on, false, allocated);
            for (var depth = stack.Length - 1; depth >= 0; depth--)
            {
                node = node.Child(stack[depth].Function, recording);
                node.Count(on, depth == 0, allocated, stack[depth].Line);
                // Where the function above called it: the caller's line in these samples.
                if (depth < stack.Length - 1) node.CountCaller(stack[depth + 1].Line, on);
            }
        }
        // Lua rows are shares of the whole range, so a mod's row reads directly as "this much of the time".
        var perLuaSample = recording.LuaPeriod <= 0 ? 0 : Math.Min(1.0, (double)recording.LuaPeriod / (end - start));
        foreach (var tree in callTrees.Values) tree.Finish(perLuaSample);
        var allLuaFunctions = functionsCounted
            .Select(function => new ProfileShare(recording.LuaFunctions[function].Name, recording.LuaFunctions[function].File,
                Math.Min(1, functionSelf[function] * perLuaSample), Math.Min(1, functionTotal[function] * perLuaSample), functionSelf[function]))
            .OrderByDescending(row => row.Self).ThenByDescending(row => row.Total).ThenBy(row => row.Name, StringComparer.Ordinal)
            .ToArray();
        var luaFunctions = allLuaFunctions.Take(maximumRows).ToArray();
        // One group per mod, plus the game's own scripts; a file whose owner cannot be told stays under "unknown".
        var luaGroups = allLuaFunctions.GroupBy(row => OwnerOf(row.Detail), StringComparer.OrdinalIgnoreCase)
            .Select(group => new ProfileGroup(group.Key, Math.Min(1, group.Sum(row => row.Samples) * perLuaSample), group.Sum(row => row.Samples),
                group.Take(maximumRows).ToArray()))
            .OrderByDescending(group => group.Self).ThenByDescending(group => group.Rows.Count > 0 ? group.Rows[0].Total : 0)
            .ThenBy(group => group.Key, StringComparer.Ordinal).ToArray();
        var luaOwners = ownerTotal
            .Select(item => new ProfileShare(item.Key, "", Math.Min(1, ownerSelf.GetValueOrDefault(item.Key) * perLuaSample),
                Math.Min(1, item.Value * perLuaSample), ownerSelf.GetValueOrDefault(item.Key)))
            .OrderByDescending(row => row.Self).ThenBy(row => row.Name, StringComparer.Ordinal).Take(maximumRows).ToArray();

        var (collectionCount, collectionPause) = CollectionsIn(recording, start, end);
        var pauses = recording.Pauses.Where(item => item.Time < end && item.Time + item.Duration >= start
                && (thread < 0 || item.Thread < 0 || item.Thread == thread))
            .OrderByDescending(item => item.Duration).Take(10).ToArray();

        // The same owners as the time, ranked by what their functions allocated themselves.
        var allocationGroups = functionsCounted.Where(function => allocationCounted[function])
            .Select(function =>
            {
                var source = recording.LuaFunctions[function];
                return new ProfileAllocation(source.Name, source.File, allocatedSelf[function], allocatedTotal[function], allocationsSelf[function]);
            })
            .OrderByDescending(row => row.Self).ThenByDescending(row => row.Total).ThenBy(row => row.Name, StringComparer.Ordinal)
            .GroupBy(row => OwnerOf(row.Detail), StringComparer.OrdinalIgnoreCase)
            .Select(group => new ProfileAllocationGroup(group.Key, group.Sum(row => row.Self), group.Sum(row => row.Samples),
                group.Take(maximumRows).ToArray()))
            .OrderByDescending(group => group.Self).ThenBy(group => group.Key, StringComparer.Ordinal).ToArray();

        return new ProfileRange(start, end, FrameStatistics(recording, start, end), count, methods, methodGroups, threads,
            Math.Min(1, luaCount * perLuaSample), luaCount, luaFunctions, luaOwners, luaGroups,
            collectionCount, collectionPause, pauses)
        {
            LuaAllocationGroups = allocationGroups,
            LuaCallTrees = callTrees,
            LuaLines = lineCounts.ToDictionary(owner => owner.Key,
                owner => (IReadOnlyDictionary<int, IReadOnlyList<ProfileLineTotal>>)owner.Value.ToDictionary(
                    function => function.Key, function => (IReadOnlyList<ProfileLineTotal>)ProfileLineTotals.Ordered(function.Value)),
                StringComparer.OrdinalIgnoreCase),
            WaitingSamples = waiting,
            RunningShare = thread < 0 ? null : Math.Min(1, weightSum / (end - start)),
            LuaAllocated = luaAllocated,
            GameThreadAllocated = GameThreadAllocatedIn(recording, start, end),
            MemoryStopMilliseconds = MemoryStopIn(recording, start, end, thread),
        };
    }

    /// <summary>The recording's kinds of pause: the collector's, which stop every thread, and a thread's wait for memory.</summary>
    public const string CollectorPause = "GCPhasePause", AllocationStall = "ZAllocationStall";

    /// <summary>
    /// How long <paramref name="thread"/> was stopped for memory inside the range, in milliseconds: the collector's
    /// pauses, as they happened (a collection is written where its cycle began, its pauses added up, so a frame-sized
    /// range finds them on the wrong frame), and the thread's own allocation stalls, which leave no samples behind. A
    /// stall waits for a collection, so where they overlap the time counts once. Null without the collector's pauses.
    /// </summary>
    public static double? MemoryStopIn(ProfileRecording recording, long start, long end, int thread)
    {
        if (!recording.HasCollectorPauses) return null;
        var pauses = recording.Pauses;
        long stopped = 0, covered = start;
        // In time order: each counts from where the ones before it ended.
        for (var index = LowerBound(pauses, start - LongestCollection, item => item.Time); index < pauses.Count && pauses[index].Time < end; index++)
        {
            var pause = pauses[index];
            if (pause.Kind != CollectorPause && !(pause.Kind == AllocationStall && thread >= 0 && pause.Thread == thread)) continue;
            long from = Math.Max(covered, pause.Time), to = Math.Min(end, pause.Time + pause.Duration);
            if (to <= from) continue;
            stopped += to - from;
            covered = to;
        }
        return stopped / 1000.0;
    }

    // Native calls that only wait: for a connection or data, a selector or completion port, a timer, a lock, the
    // scheduler. Only calls known to wait are listed; any other native call (drawing, file access, physics) is work.
    private static readonly HashSet<string> WaitingMethods = new(StringComparer.Ordinal)
    {
        "sun.nio.ch.Net.accept", "sun.nio.ch.Net.poll", "sun.nio.ch.SocketDispatcher.read0", "sun.nio.ch.WEPoll.wait",
        "sun.nio.ch.WindowsSelectorImpl$SubSelector.poll0", "sun.nio.ch.Iocp.getQueuedCompletionStatus",
        "sun.nio.fs.WindowsNativeDispatcher.GetQueuedCompletionStatus0",
        "java.lang.Thread.sleep0", "java.lang.Thread.sleepNanos0", "java.lang.Thread.yield0", "java.lang.Object.wait0",
        "jdk.internal.misc.Unsafe.park", "java.lang.ref.Reference.waitForReferencePendingList",
        // PZ Tools' own timed waits, made through Java's foreign function calls.
        "pztools.bridge.runtime.ProfileRecorder$PreciseWait.pause", "pztools.extensions.runtime.input.WindowsKeys.pause",
    };

    /// <summary>
    /// Whether a native sample's thread was only waiting: its innermost method, past the generated frames of a
    /// foreign function call, is a known wait.
    /// </summary>
    private static bool Waits(ProfileRecording recording, int[] stack)
    {
        foreach (var method in stack)
        {
            var name = recording.Methods[method];
            if (name.StartsWith("java.lang.invoke.", StringComparison.Ordinal) || name.StartsWith("jdk.internal.foreign.", StringComparison.Ordinal)
                || name.Contains("LambdaForm$", StringComparison.Ordinal) || name.Contains("DowncallStub", StringComparison.Ordinal))
                continue;
            return WaitingMethods.Contains(name);
        }
        return false;
    }

    /// <summary>
    /// A call tree's functions, each once, its paths added up: the list beside the tree, from the same samples. A function
    /// that calls itself counts a sample once, at its outermost call.
    /// </summary>
    public static IReadOnlyList<ProfileFunctionTotal> FunctionsIn(ProfileCallNode tree)
    {
        var totals = new Dictionary<int, ProfileFunctionTotal>();
        var onPath = new HashSet<int>();
        void Walk(ProfileCallNode node)
        {
            foreach (var child in node.Children)
            {
                var outermost = onPath.Add(child.Function);
                var total = totals.GetValueOrDefault(child.Function) ?? new(child.Function, child.Name, child.File, 0, 0, 0, 0);
                totals[child.Function] = total with
                {
                    SelfSamples = total.SelfSamples + child.SelfSamples,
                    AllocatedSelf = total.AllocatedSelf + child.AllocatedSelf,
                    Samples = total.Samples + (outermost ? child.Samples : 0),
                    AllocatedTotal = total.AllocatedTotal + (outermost ? child.AllocatedTotal : 0),
                };
                Walk(child);
                if (outermost) onPath.Remove(child.Function);
            }
        }
        Walk(tree);
        return totals.Values.OrderByDescending(row => row.SelfSamples).ThenByDescending(row => row.Samples)
            .ThenBy(row => row.Name, StringComparer.Ordinal).ToArray();
    }

    /// <summary>
    /// What names a script function across recordings: its name and its file from the mod's media/lua on, the part
    /// that holds when a mod moves (a workshop download, a local copy) or is updated. Function numbers are one
    /// recording's.
    /// </summary>
    public static string ScriptKey(string name, string file)
    {
        var at = file.IndexOf("media/lua/", StringComparison.OrdinalIgnoreCase);
        return name + "\n" + (at < 0 ? file : file[at..]);
    }

    /// <summary>
    /// Where one thread's time in the range went, as shares of the range that add up to one: its scripts running (the
    /// game functions they called included), the game's own code running, the thread stopped for memory (the collector's
    /// pauses and its own waits for memory), and the rest,
    /// which the thread spent waiting (for the next frame, mostly). The answer to "was this stutter the scripts, the game
    /// or the memory", without adding up figures from tabs that count the same time two ways. Null for all threads
    /// together, whose times overlap.
    /// </summary>
    public static ProfileTimeBreakdown? TimeBreakdown(ProfileRange range)
    {
        if (range.RunningShare is not { } running) return null;
        var length = Math.Max(1, range.End - range.Start);
        // Stopped for memory: the collector's pauses where they fell and the thread's waits for memory; a recording
        // without the pauses has only the collections' totals.
        return Split(running, range.LuaShare, (range.MemoryStopMilliseconds ?? range.CollectionPauseMilliseconds) * 1000 / length);
    }

    // The four parts from what was measured, each a share of the span.
    private static ProfileTimeBreakdown Split(double running, double lua, double memory)
    {
        var collections = Math.Clamp(memory, 0, 1);
        // Two samplers measure the scripts and the running code; where they disagree a little, the scripts win.
        var scripts = Math.Clamp(lua, 0, 1 - collections);
        var game = Math.Clamp(Math.Max(running, scripts) - scripts, 0, 1 - collections - scripts);
        return new ProfileTimeBreakdown(scripts, game, collections, Math.Max(0, 1 - scripts - game - collections));
    }

    /// <summary>
    /// <see cref="TimeBreakdown"/> for the game thread over a span as short as a frame, from the records alone: what the
    /// frame graph draws for one part of it. Null without a known game thread.
    /// </summary>
    public static ProfileTimeBreakdown? BreakdownIn(ProfileRecording recording, long start, long end)
    {
        var thread = recording.GameThread;
        if (thread < 0 || end <= start) return null;
        double length = end - start, running = 0;
        var samples = recording.Samples;
        for (var index = LowerBound(samples, start, sample => sample.Time); index < samples.Length && samples[index].Time < end; index++)
        {
            var sample = samples[index];
            // As in the range's figures: a thread only waiting in a native call was not running.
            if (sample.Thread != thread || sample.Native && Waits(recording, recording.Stacks[sample.Stack])) continue;
            running += sample.Native ? recording.NativePeriod : recording.JavaPeriod;
        }
        var lua = recording.LuaSamples;
        var luaSamples = 0;
        for (var index = LowerBound(lua, start, sample => sample.Time); index < lua.Length && lua[index].Time < end; index++) luaSamples++;
        var memory = MemoryStopIn(recording, start, end, thread) ?? CollectionsIn(recording, start, end).PauseMilliseconds;
        return Split(Math.Min(1, running / length), Math.Min(1, luaSamples * (double)recording.LuaPeriod / length), memory * 1000 / length);
    }

    /// <summary>
    /// For each slice the frame graph draws, the milliseconds of its bar (the slice's slowest frame) that went to each
    /// part of <see cref="BreakdownIn"/>; null where no frame began. Counted from samples, so in steps of a period.
    /// </summary>
    public static ProfileTimeBreakdown?[] BreakdownPerBucket(ProfileRecording recording, long start, long end, int buckets)
    {
        var slowest = SlowestFrames(recording, start, end, buckets);
        var result = new ProfileTimeBreakdown?[slowest.Length];
        for (var bucket = 0; bucket < slowest.Length; bucket++)
        {
            if (slowest[bucket] < 0) continue;
            var frame = recording.Frames[slowest[bucket]];
            if (BreakdownIn(recording, frame.Start, frame.Start + frame.Duration) is not { } shares) continue;
            var milliseconds = frame.Duration / 1000.0;
            result[bucket] = new(shares.Scripts * milliseconds, shares.GameCode * milliseconds,
                shares.Collections * milliseconds, shares.Waiting * milliseconds);
        }
        return result;
    }

    // The index of each slice's slowest frame, as the frame graph draws it; -1 where no frame began.
    private static int[] SlowestFrames(ProfileRecording recording, long start, long end, int buckets)
    {
        var slowest = new int[Math.Max(1, buckets)];
        Array.Fill(slowest, -1);
        if (end <= start) return slowest;
        var frames = recording.Frames;
        var span = (double)(end - start);
        for (var index = LowerBound(frames, start, frame => frame.Start); index < frames.Length && frames[index].Start < end; index++)
        {
            var bucket = Math.Min(slowest.Length - 1, (int)((frames[index].Start - start) / span * slowest.Length));
            if (slowest[bucket] < 0 || frames[index].Duration > frames[slowest[bucket]].Duration) slowest[bucket] = index;
        }
        return slowest;
    }

    /// <summary>
    /// Each node of <paramref name="current"/> with the one at the same call path in <paramref name="baseline"/>, matched
    /// by <see cref="ScriptKey"/> level by level; a path the baseline never took is left out.
    /// </summary>
    public static IReadOnlyDictionary<ProfileCallNode, ProfileCallNode> MatchCallTrees(ProfileCallNode current, ProfileCallNode baseline)
    {
        var matched = new Dictionary<ProfileCallNode, ProfileCallNode>(ReferenceEqualityComparer.Instance);
        void Match(ProfileCallNode node, ProfileCallNode other)
        {
            matched[node] = other;
            if (node.Children.Count == 0 || other.Children.Count == 0) return;
            var byKey = new Dictionary<string, ProfileCallNode>();
            // Two functions of one name in one file (a local function and a global) share a key; the heavier one is
            // kept, as the children come most samples first.
            foreach (var child in other.Children) byKey.TryAdd(ScriptKey(child.Name, child.File), child);
            foreach (var child in node.Children)
                if (byKey.TryGetValue(ScriptKey(child.Name, child.File), out var same)) Match(child, same);
        }
        Match(current, baseline);
        return matched;
    }

    /// <summary>
    /// Each function of an owner's tree with its total as a part of the whole range, by <see cref="ScriptKey"/>: the
    /// owner's share split by the samples that passed through the function.
    /// </summary>
    public static IReadOnlyDictionary<string, double> FunctionShares(ProfileCallNode tree)
    {
        var shares = new Dictionary<string, double>();
        if (tree.Samples <= 0) return shares;
        foreach (var row in FunctionsIn(tree))
            shares.TryAdd(ScriptKey(row.Name, row.File), tree.Total * row.Samples / tree.Samples);
        return shares;
    }

    /// <summary>
    /// What the game thread allocated in the range, in Lua or not; null without readings. Each reading covers the time
    /// since the one before (the first, a second), and counts in the part of it that falls inside the range.
    /// </summary>
    public static long? GameThreadAllocatedIn(ProfileRecording recording, long start, long end)
    {
        var readings = recording.GameThreadAllocations;
        if (readings.Count == 0) return null;
        double bytes = 0;
        for (var index = 0; index < readings.Count; index++)
        {
            long to = readings[index].Time, from = index > 0 ? readings[index - 1].Time : to - 1_000_000;
            var overlap = Math.Min(end, to) - Math.Max(start, from);
            if (overlap > 0) bytes += readings[index].Bytes * (double)overlap / Math.Max(1, to - from);
        }
        return (long)Math.Round(bytes);
    }

    /// <summary>The most heap in use, and the most video memory on the graphics card, during the range; null without readings.</summary>
    public static (long? Heap, long? VideoMemory) MemoryPeaksIn(ProfileRecording recording, long start, long end)
    {
        long? heap = null, video = null;
        var heapReadings = recording.Heap;
        for (var index = LowerBound(heapReadings, start, item => item.Time); index < heapReadings.Count && heapReadings[index].Time < end; index++)
            heap = Math.Max(heap ?? 0, heapReadings[index].Used);
        var videoReadings = recording.VideoMemory;
        for (var index = LowerBound(videoReadings, start, item => item.Time); index < videoReadings.Count && videoReadings[index].Time < end; index++)
            video = Math.Max(video ?? 0, videoReadings[index].Dedicated);
        return (heap, video);
    }

    /// <summary>
    /// The part of the range the collector was at work, 0 to 1; null in recordings made before its runs were kept.
    /// ZGC stops the game for well under a millisecond but works beside it, on the CPU the game would use: with memory
    /// short it runs nearly all the time, which its pauses never show.
    /// </summary>
    public static double? CollectorBusyIn(ProfileRecording recording, long start, long end)
    {
        var runs = recording.CollectorRuns;
        if (runs.Count == 0 || end <= start) return runs.Count == 0 ? null : 0;
        // Young and old collections can overlap: the time any of them ran.
        long busy = 0, coveredTo = start;
        foreach (var run in runs)
        {
            if (run.Time >= end) break;
            long from = Math.Max(Math.Max(run.Time, coveredTo), start), to = Math.Min(run.Time + run.Duration, end);
            if (to > from) { busy += to - from; coveredTo = to; }
        }
        return Math.Clamp(busy / (double)(end - start), 0, 1);
    }

    /// <summary>
    /// The callers of a method's own time in the range, bottom up (see <see cref="ProfileCallerNode"/>): where the samples
    /// that ended in it came from. Counted as the range's figures are (the thread's samples, waits left out), so the
    /// root's share is the method's own share. Worked out for one method at a time, when its row is opened.
    /// </summary>
    /// <param name="thread">The thread whose samples count; -1 all.</param>
    public static ProfileCallerNode CallersOf(ProfileRecording recording, long start, long end, int thread, string method)
    {
        // A name can stand at more than one place in the method table; its rows in the lists are by name.
        var targets = new HashSet<int>();
        for (var index = 0; index < recording.Methods.Count; index++)
            if (recording.Methods[index] == method) targets.Add(index);
        var root = new ProfileCallerNode(targets.Count > 0 ? targets.First() : -1) { Methods = [method] };
        if (targets.Count == 0 || end <= start) return root;
        var span = (double)(end - start);
        var waits = new bool?[recording.Stacks.Count];
        var samples = recording.Samples;
        for (var index = LowerBound(samples, start, sample => sample.Time); index < samples.Length && samples[index].Time < end; index++)
        {
            var sample = samples[index];
            if (thread >= 0 && sample.Thread != thread) continue;
            var stack = recording.Stacks[sample.Stack];
            if (stack.Length == 0 || !targets.Contains(stack[0])) continue;
            if (sample.Native && (waits[sample.Stack] ??= Waits(recording, stack))) continue;
            var weight = (sample.Native ? recording.NativePeriod : recording.JavaPeriod) / span;
            var node = root;
            node.Share += weight; node.Samples++;
            // Up the stack, nearest caller first; a recursive call counts each frame it passes.
            for (var depth = 1; depth < stack.Length; depth++)
            {
                if (!node.ByMethod.TryGetValue(stack[depth], out var caller)) node.ByMethod[stack[depth]] = caller = new ProfileCallerNode(stack[depth]);
                node = caller;
                node.Share += weight; node.Samples++;
            }
        }
        Finish(root, recording, isRoot: true);
        return root;
    }

    // Callers heaviest first; a caller with one caller of its own taking all its samples joins it in one row, up to the
    // game's own code (or a few methods, so a row stays readable).
    private static void Finish(ProfileCallerNode node, ProfileRecording recording, bool isRoot)
    {
        const int longestChain = 6;
        if (!isRoot)
            // A library chain ends at the first game method it reaches; a chain of the game's own methods folds on.
            while (node.ByMethod.Count == 1 && node.MethodIndexes.Count < longestChain
                && !(IsGameMethod(recording.Methods[node.MethodIndexes[^1]])
                    && node.MethodIndexes.Any(index => !IsGameMethod(recording.Methods[index]))))
            {
                var only = node.ByMethod.Values.First();
                if (only.Samples != node.Samples) break;
                node.MethodIndexes.Add(only.MethodIndexes[0]);
                node.ByMethod.Clear();
                foreach (var pair in only.ByMethod) node.ByMethod[pair.Key] = pair.Value;
            }
        if (!isRoot)
        {
            node.Methods = node.MethodIndexes.Select(index => recording.Methods[index]).ToArray();
            node.ReachesGame = node.Methods.Any(IsGameMethod);
        }
        var callers = node.ByMethod.Values.OrderByDescending(caller => caller.Samples).ToArray();
        foreach (var caller in callers) Finish(caller, recording, isRoot: false);
        node.Callers = callers;
    }

    // The game's own code, where reading up from a library method has found what in the game asked for it.
    private static bool IsGameMethod(string method) => method.StartsWith("zombie.", StringComparison.Ordinal);

    /// <summary>
    /// How long frames took while the collector was at work against while it was not, in milliseconds on average: what
    /// running short of memory cost the game in this recording, measured rather than guessed. ZGC hardly stops the game
    /// but slows it while it works; the time breakdown counts that slower code as running. A frame counts as with the
    /// collector when it ran through most of it, as without when none of it did. Null without the collector's runs.
    /// </summary>
    public static ProfileCollectorFrames? FramesWithCollector(ProfileRecording recording)
    {
        if (recording.CollectorRuns.Count == 0) return null;
        double during = 0, outside = 0;
        int duringCount = 0, outsideCount = 0;
        foreach (var frame in recording.Frames)
        {
            var busy = CollectorBusyIn(recording, frame.Start, frame.Start + Math.Max(1, frame.Duration)) ?? 0;
            if (busy >= 0.5) { during += frame.Duration; duringCount++; }
            else if (busy == 0) { outside += frame.Duration; outsideCount++; }
        }
        return new(duringCount == 0 ? 0 : during / duringCount / 1000, duringCount,
            outsideCount == 0 ? 0 : outside / outsideCount / 1000, outsideCount);
    }

    /// <summary>
    /// The share of all the machine's processors other programs used while it recorded, on average: a machine kept busy
    /// by something else slows the game however light its mods. Null in recordings made before it was kept.
    /// </summary>
    public static double? OtherProgramsCpu(ProfileRecording recording) => recording.MachineCpu.Count == 0 ? null
        : recording.MachineCpu.Average(reading => Math.Max(0, reading.MachineTotal - reading.GameUser - reading.GameSystem));

    /// <summary>
    /// How many times a thread, any thread, stopped in the range until the collector freed memory for it, and the
    /// longest of those waits.
    /// </summary>
    public static (int Count, long Longest) StallsIn(ProfileRecording recording, long start, long end)
    {
        int count = 0;
        long longest = 0;
        foreach (var pause in recording.Pauses)
        {
            if (pause.Kind != AllocationStall || pause.Time >= end || pause.Time + pause.Duration < start) continue;
            count++;
            longest = Math.Max(longest, pause.Duration);
        }
        return (count, longest);
    }

    /// <summary>
    /// Whether the game ran short of memory in the recording: threads stopped until memory was freed (the collector's
    /// allocation stalls), or the heap stood near its maximum for a quarter of its readings or more. Either says the
    /// game's memory, not its code, is what to change. Judged on the whole recording, not a range: the setting is.
    /// </summary>
    public static ProfileMemoryPressure MemoryPressure(ProfileRecording recording)
    {
        int stalls = 0;
        long stalled = 0;
        foreach (var pause in recording.Pauses)
        {
            if (pause.Kind != AllocationStall) continue;
            stalls++;
            stalled += pause.Duration;
        }
        var readings = recording.Heap.Where(sample => sample.Maximum > 0).ToArray();
        // Too few readings say nothing about how long the heap stood full.
        double full = readings.Length < 8 ? 0
            : readings.Count(sample => sample.Used >= sample.Maximum * NearlyFull) / (double)readings.Length;
        return new(stalls, stalled, full, readings.Length > 0 ? readings.Max(sample => sample.Maximum) : 0);
    }

    /// <summary>The share of the maximum above which the heap counts as full.</summary>
    public const double NearlyFull = 0.9;

    /// <summary>The last readings at or before a moment: what memory looked like then.</summary>
    public static (ProfileHeapSample? Heap, ProfileVideoMemorySample? VideoMemory) MemoryAt(ProfileRecording recording, long time)
    {
        var heapIndex = LowerBound(recording.Heap, time + 1, item => item.Time) - 1;
        var videoIndex = LowerBound(recording.VideoMemory, time + 1, item => item.Time) - 1;
        return (heapIndex >= 0 ? recording.Heap[heapIndex] : null, videoIndex >= 0 ? recording.VideoMemory[videoIndex] : null);
    }

    /// <summary>
    /// Garbage collections that overlap the range, and how long they paused the game in all. A pause stops
    /// every thread, so it leaves no samples behind; this is where it shows instead.
    /// </summary>
    // No collection pauses the game this long; one that began longer before a range cannot reach into it.
    private const long LongestCollection = 60_000_000;

    public static (int Count, double PauseMilliseconds) CollectionsIn(ProfileRecording recording, long start, long end)
    {
        var count = 0;
        long pause = 0;
        var collections = recording.Collections;
        // In time order; one that began a little before the range may still reach into it.
        for (var index = LowerBound(collections, start - LongestCollection, item => item.Time); index < collections.Count && collections[index].Time < end; index++)
        {
            var item = collections[index];
            if (item.Time + item.Duration < start) continue;
            count++;
            pause += item.Duration;
        }
        return (count, pause / 1000.0);
    }

    /// <summary>Frames that begin inside the range.</summary>
    public static ProfileFrameStatistics FrameStatistics(ProfileRecording recording, long start, long end)
    {
        var frames = recording.Frames;
        var first = LowerBound(frames, start, frame => frame.Start);
        var durations = new List<long>();
        for (var index = first; index < frames.Length && frames[index].Start < end; index++) durations.Add(frames[index].Duration);
        if (durations.Count == 0) return new(0, 0, 0, 0, 0);
        durations.Sort();
        // "1% low" as players know it: the average of the slowest hundredth of the frames.
        var worst = Math.Max(1, durations.Count / 100);
        return new(durations.Count, durations.Average() / 1000.0, durations[durations.Count / 2] / 1000.0, durations[^1] / 1000.0,
            durations.Skip(durations.Count - worst).Average() / 1000.0);
    }

    /// <summary>
    /// For each slice the frame graph draws, how many milliseconds of its bar (the slice's slowest frame) one owner's
    /// code ran: a mod's or the game's scripts (<paramref name="java"/> false, a key of <see cref="ProfileRange.LuaGroups"/>)
    /// or a part of the game code (true, a key of <see cref="ProfileRange.MethodGroups"/>). The same frame as the bar, so
    /// the two compare directly; 0 where no frame began. Counted from samples, so in steps of a sampling period.
    /// </summary>
    /// <param name="thread">For game code, the thread whose samples count (the game thread: frames are its own); -1 all.</param>
    public static double[] OwnerTimePerBucket(ProfileRecording recording, long start, long end, int buckets, bool java, string owner, int thread)
    {
        var result = new double[Math.Max(1, buckets)];
        if (end <= start) return result;
        var frames = recording.Frames;
        var slowest = SlowestFrames(recording, start, end, buckets);
        for (var bucket = 0; bucket < result.Length; bucket++)
        {
            if (slowest[bucket] < 0) continue;
            var frame = frames[slowest[bucket]];
            result[bucket] = OwnerTimeIn(recording, frame.Start, frame.Start + frame.Duration, java, owner, thread);
        }
        return result;
    }

    /// <summary>
    /// For each of <paramref name="buckets"/> equal slices of the range, the bytes the game thread allocated while one
    /// owner's scripts ran (a key of <see cref="ProfileRange.LuaGroups"/>), by the Lua samples taken in it: the same
    /// figures as the allocation tab, spread over time. All 0 for a recording without allocations.
    /// </summary>
    public static long[] OwnerAllocationPerBucket(ProfileRecording recording, long start, long end, int buckets, string owner)
    {
        var result = new long[Math.Max(1, buckets)];
        if (end <= start || !recording.HasLuaAllocations) return result;
        var lua = recording.LuaSamples;
        var span = (double)(end - start);
        var ownerOf = new Dictionary<int, bool>();
        for (var index = LowerBound(lua, start, sample => sample.Time); index < lua.Length && lua[index].Time < end; index++)
        {
            var sample = lua[index];
            var stack = recording.LuaStacks[sample.Stack];
            if (sample.Allocated <= 0 || stack.Length == 0) continue;
            var function = stack[0].Function;
            if (!ownerOf.TryGetValue(function, out var mine))
                ownerOf[function] = mine = OwnerOf(recording.LuaFunctions[function].File).Equals(owner, StringComparison.OrdinalIgnoreCase);
            if (!mine) continue;
            result[Math.Min(result.Length - 1, (int)((sample.Time - start) / span * result.Length))] += sample.Allocated;
        }
        return result;
    }

    /// <summary>Milliseconds one owner's code ran between two moments, by the samples taken then (see <see cref="OwnerTimePerBucket"/>).</summary>
    public static double OwnerTimeIn(ProfileRecording recording, long start, long end, bool java, string owner, int thread)
    {
        double micros = 0;
        if (!java)
        {
            var lua = recording.LuaSamples;
            var owners = FunctionOwners(recording);
            for (var index = LowerBound(lua, start, sample => sample.Time); index < lua.Length && lua[index].Time < end; index++)
            {
                var stack = recording.LuaStacks[lua[index].Stack];
                if (stack.Length > 0 && owners[stack[0].Function].Equals(owner, StringComparison.OrdinalIgnoreCase))
                    micros += recording.LuaPeriod;
            }
            return micros / 1000;
        }
        var samples = recording.Samples;
        for (var index = LowerBound(samples, start, sample => sample.Time); index < samples.Length && samples[index].Time < end; index++)
        {
            var sample = samples[index];
            if (thread >= 0 && sample.Thread != thread) continue;
            var stack = recording.Stacks[sample.Stack];
            // As in the shares: a thread only waiting in a native call was not running anyone's code.
            if (stack.Length == 0 || sample.Native && Waits(recording, stack)) continue;
            if (MethodGroups(recording)[stack[0]] == owner) micros += sample.Native ? recording.NativePeriod : recording.JavaPeriod;
        }
        return micros / 1000;
    }

    /// <summary>
    /// The slowest frame in each of <paramref name="buckets"/> equal slices of the range, in milliseconds;
    /// 0 where no frame began. Taking the maximum keeps a single spike visible however far the chart is zoomed out.
    /// </summary>
    public static double[] SlowestFramePerBucket(ProfileRecording recording, long start, long end, int buckets)
    {
        var result = new double[Math.Max(1, buckets)];
        if (end <= start) return result;
        var frames = recording.Frames;
        var span = (double)(end - start);
        for (var index = LowerBound(frames, start, frame => frame.Start); index < frames.Length && frames[index].Start < end; index++)
        {
            var bucket = Math.Min(result.Length - 1, (int)((frames[index].Start - start) / span * result.Length));
            result[bucket] = Math.Max(result[bucket], frames[index].Duration / 1000.0);
        }
        return result;
    }

    /// <summary>The frame that contains <paramref name="time"/>, or the nearest one that began before it.</summary>
    public static ProfileFrame? FrameAt(ProfileRecording recording, long time)
    {
        var frames = recording.Frames;
        if (frames.Length == 0) return null;
        var index = LowerBound(frames, time + 1, frame => frame.Start) - 1;
        return frames[Math.Max(0, index)];
    }

    /// <summary>Which mod a Lua file belongs to, from the shortened path the recording keeps.</summary>
    // Each Lua function's owner and each method's group, worked out once per recording: the frame graph asks for them
    // for every sample of every bar it draws, and again on each pan, zoom and pointer over the list.
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<ProfileRecording, string[]> functionOwners = new();
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<ProfileRecording, string[]> methodGroups = new();

    private static string[] FunctionOwners(ProfileRecording recording) =>
        functionOwners.GetValue(recording, current => Array.ConvertAll(current.LuaFunctions.ToArray(), function => OwnerOf(function.File)));

    private static string[] MethodGroups(ProfileRecording recording) =>
        methodGroups.GetValue(recording, current => Array.ConvertAll(current.Methods.ToArray(), GroupOf));

    public static string OwnerOf(string file)
    {
        var path = file.Replace('\\', '/');
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var mods = Array.FindIndex(parts, part => part.Equals("mods", StringComparison.OrdinalIgnoreCase));
        if (mods >= 0 && mods + 1 < parts.Length) return parts[mods + 1];
        if (parts.Length > 0 && parts[0].Equals("media", StringComparison.OrdinalIgnoreCase)) return GameOwner;
        return UnknownOwner;
    }

    /// <summary>
    /// Where a Java method comes from, by its package. Only what the name settles is decided here:
    /// anything unrecognised is a bundled library, never guessed to be a mod.
    /// </summary>
    public static string GroupOf(string method)
    {
        if (method.StartsWith("zombie.", StringComparison.Ordinal)) return GameCode;
        if (method.StartsWith("se.krka.kahlua.", StringComparison.Ordinal)) return LuaRuntime;
        if (method.StartsWith("pztools.", StringComparison.Ordinal)) return Tools;
        foreach (var prefix in (ReadOnlySpan<string>)["java.", "javax.", "jdk.", "sun.", "com.sun."])
            if (method.StartsWith(prefix, StringComparison.Ordinal)) return JavaRuntime;
        return Libraries;
    }

    private static int LowerBound<T>(IReadOnlyList<T> items, long time, Func<T, long> key)
    {
        int low = 0, high = items.Count;
        while (low < high)
        {
            var middle = (low + high) >>> 1;
            if (key(items[middle]) < time) low = middle + 1; else high = middle;
        }
        return low;
    }
}
