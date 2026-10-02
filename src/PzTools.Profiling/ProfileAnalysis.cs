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

    internal void Count(bool self, long allocated)
    {
        Samples++;
        if (self) SelfSamples++;
        if (allocated < 0) return;
        AllocatedTotal += allocated;
        if (self) AllocatedSelf += allocated;
    }

    internal void Finish(double perSample)
    {
        Total = Math.Min(1, Samples * perSample);
        Self = Math.Min(1, SelfSamples * perSample);
        children = byFunction.Values.OrderByDescending(node => node.Samples).ThenBy(node => node.Name, StringComparer.Ordinal).ToArray();
        foreach (var child in children) child.Finish(perSample);
    }
}

/// <summary>
/// One function of a call tree, its paths added up: <see cref="SelfSamples"/> ended in it, <see cref="Samples"/> passed
/// through it (a recursive call counted once per sample). The same samples as the tree, so the same whole.
/// </summary>
public sealed record ProfileFunctionTotal(int Function, string Name, string File, int SelfSamples, int Samples,
    long AllocatedSelf, long AllocatedTotal);

/// <summary>
/// One line of a Lua function: <see cref="Samples"/> found it at that line, whatever it had called from there (a
/// recursive call counted once, at its outermost call); <see cref="SelfSamples"/> found it running that line itself.
/// Line 0 is a frame the interpreter gave no line for.
/// </summary>
public sealed record ProfileLineTotal(int Line, int SelfSamples, int Samples, long AllocatedSelf, long AllocatedTotal);

public sealed record ProfileFrameStatistics(int Count, double AverageMilliseconds, double MedianMilliseconds,
    double SlowestMilliseconds, double OnePercentWorstMilliseconds);

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
    /// Per owner (the keys of <see cref="LuaGroups"/>), the call paths of the samples that ended in its functions, as a
    /// tree under a root: its outermost functions sum to the owner's own samples, as its row in the list does.
    /// </summary>
    public IReadOnlyDictionary<string, ProfileCallNode> LuaCallTrees { get; init; } = new Dictionary<string, ProfileCallNode>();
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

        // A sample stands for the time until the next one of its kind, so its weight is that period.
        var samples = recording.Samples;
        var first = LowerBound(samples, start, sample => sample.Time);
        var methodSelf = new Dictionary<int, (double Weight, int Count)>();
        var methodTotal = new Dictionary<int, double>();
        var threadWeight = new Dictionary<int, (double Weight, int Count)>();
        double weightSum = 0;
        var count = 0;
        var seen = new HashSet<int>();
        // Per group, each method's total over the samples that ended in that group's code: the group's table counts its
        // own samples only, as a script owner's does, so a total never exceeds the group.
        var groupOf = new string?[recording.Methods.Count];
        var totalInGroup = new Dictionary<(string Group, int Method), double>();
        // A thread inside a native call is sampled whether it works there (drawing, reading a file) or only waits (for
        // a connection, a timer, an event). The waits are left out, so a thread's share is time it ran.
        var waits = new bool?[recording.Stacks.Count];
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
            double weight = sample.Native ? recording.NativePeriod : recording.JavaPeriod;
            var byThread = threadWeight.GetValueOrDefault(sample.Thread);
            threadWeight[sample.Thread] = (byThread.Weight + weight, byThread.Count + 1);
            if (thread >= 0 && sample.Thread != thread) continue;
            count++;
            weightSum += weight;
            var stack = recording.Stacks[sample.Stack];
            if (stack.Length == 0) continue;
            var self = methodSelf.GetValueOrDefault(stack[0]);
            methodSelf[stack[0]] = (self.Weight + weight, self.Count + 1);
            var group = groupOf[stack[0]] ??= GroupOf(recording.Methods[stack[0]]);
            // Recursion must not count one sample twice for the same method.
            seen.Clear();
            foreach (var method in stack)
                if (seen.Add(method))
                {
                    methodTotal[method] = methodTotal.GetValueOrDefault(method) + weight;
                    if ((groupOf[method] ??= GroupOf(recording.Methods[method])) == group)
                        totalInGroup[(group, method)] = totalInGroup.GetValueOrDefault((group, method)) + weight;
                }
        }
        var indexed = methodTotal
            .Select(item =>
            {
                var self = methodSelf.GetValueOrDefault(item.Key);
                return (Method: item.Key, Row: new ProfileShare(recording.Methods[item.Key], "", self.Weight / Math.Max(1, weightSum),
                    item.Value / Math.Max(1, weightSum), self.Count));
            })
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
                    .Select(item => item.Row with { Total = totalInGroup.GetValueOrDefault((group.Key, item.Method)) / Math.Max(1, weightSum) })
                    .Where(row => row.Total > 0)
                    .OrderByDescending(row => row.Self).ThenByDescending(row => row.Total).ThenBy(row => row.Name, StringComparer.Ordinal);
                return new ProfileGroup(group.Key, group.Sum(item => item.Row.Self), group.Sum(item => item.Row.Samples), rows.Take(maximumRows).ToArray());
            })
            .Where(group => group.Samples > 0)
            .OrderByDescending(group => group.Self).ThenBy(group => group.Key, StringComparer.Ordinal).ToArray();
        var allThreads = threadWeight.Values.Sum(item => item.Weight);
        var threads = threadWeight
            .Select(item => new ProfileShare(recording.Threads[item.Key], "", item.Value.Weight / Math.Max(1, allThreads),
                item.Value.Weight / Math.Max(1, allThreads), item.Value.Count))
            .OrderByDescending(row => row.Self).ThenBy(row => row.Name, StringComparer.Ordinal).Take(maximumRows).ToArray();

        var lua = recording.LuaSamples;
        var luaFirst = LowerBound(lua, start, sample => sample.Time);
        var functionSelf = new Dictionary<int, int>();
        var functionTotal = new Dictionary<int, int>();
        var ownerSelf = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var ownerTotal = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var luaCount = 0;
        var owners = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // Worked out once per function, not once per sample and depth.
        var ownerOf = new string?[recording.LuaFunctions.Count];
        // Bytes the game thread allocated, given to the functions each sample found, the way its time is.
        var allocatedSelf = new Dictionary<int, (long Bytes, int Count)>();
        var allocatedTotal = new Dictionary<int, long>();
        long luaAllocated = 0;
        var callTrees = new Dictionary<string, ProfileCallNode>(StringComparer.OrdinalIgnoreCase);
        for (var index = luaFirst; index < lua.Length && lua[index].Time < end; index++)
        {
            if ((index & 4095) == 0) cancellation.ThrowIfCancellationRequested();
            var stack = recording.LuaStacks[lua[index].Stack];
            if (stack.Length == 0) continue;
            luaCount++;
            functionSelf[stack[0].Function] = functionSelf.GetValueOrDefault(stack[0].Function) + 1;
            var allocated = lua[index].Allocated;
            if (allocated >= 0)
            {
                luaAllocated += allocated;
                var self = allocatedSelf.GetValueOrDefault(stack[0].Function);
                allocatedSelf[stack[0].Function] = (self.Bytes + allocated, self.Count + 1);
            }
            seen.Clear(); owners.Clear();
            for (var depth = 0; depth < stack.Length; depth++)
            {
                var function = stack[depth].Function;
                if (seen.Add(function))
                {
                    functionTotal[function] = functionTotal.GetValueOrDefault(function) + 1;
                    if (allocated >= 0) allocatedTotal[function] = allocatedTotal.GetValueOrDefault(function) + allocated;
                }
                var owner = ownerOf[function] ??= OwnerOf(recording.LuaFunctions[function].File);
                if (depth == 0) ownerSelf[owner] = ownerSelf.GetValueOrDefault(owner) + 1;
                if (owners.Add(owner)) ownerTotal[owner] = ownerTotal.GetValueOrDefault(owner) + 1;
            }
            // The sample's path, outermost first, in the tree of the owner whose function it ended in.
            var innermostOwner = ownerOf[stack[0].Function]!;
            if (!callTrees.TryGetValue(innermostOwner, out var node))
                callTrees[innermostOwner] = node = new ProfileCallNode(-1, innermostOwner, "");
            node.Count(false, allocated);
            for (var depth = stack.Length - 1; depth >= 0; depth--)
            {
                node = node.Child(stack[depth].Function, recording);
                node.Count(depth == 0, allocated);
            }
        }
        // Lua rows are shares of the whole range, so a mod's row reads directly as "this much of the time".
        var perLuaSample = recording.LuaPeriod <= 0 ? 0 : Math.Min(1.0, (double)recording.LuaPeriod / (end - start));
        foreach (var tree in callTrees.Values) tree.Finish(perLuaSample);
        var allLuaFunctions = functionTotal
            .Select(item => new ProfileShare(recording.LuaFunctions[item.Key].Name, recording.LuaFunctions[item.Key].File,
                Math.Min(1, functionSelf.GetValueOrDefault(item.Key) * perLuaSample), Math.Min(1, item.Value * perLuaSample), functionSelf.GetValueOrDefault(item.Key)))
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
        var allocationGroups = allocatedTotal
            .Select(item =>
            {
                var self = allocatedSelf.GetValueOrDefault(item.Key);
                var function = recording.LuaFunctions[item.Key];
                return new ProfileAllocation(function.Name, function.File, self.Bytes, item.Value, self.Count);
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
            WaitingSamples = waiting,
            LuaAllocated = luaAllocated,
            GameThreadAllocated = GameThreadAllocatedIn(recording, start, end),
        };
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
    /// One function's lines in a range, counting the samples that ended in <paramref name="owner"/>'s functions, as the
    /// owner's table does: where in the function the time (and the bytes) went. Most samples first.
    /// </summary>
    public static IReadOnlyList<ProfileLineTotal> LinesIn(ProfileRecording recording, long start, long end, string owner, int function)
    {
        var lines = new Dictionary<int, ProfileLineTotal>();
        var lua = recording.LuaSamples;
        for (var index = LowerBound(lua, start, sample => sample.Time); index < lua.Length && lua[index].Time < end; index++)
        {
            var stack = recording.LuaStacks[lua[index].Stack];
            if (stack.Length == 0 || !OwnerOf(recording.LuaFunctions[stack[0].Function].File).Equals(owner, StringComparison.OrdinalIgnoreCase))
                continue;
            // The function's outermost call on the stack: the line it was at, whatever it had called from there.
            var depth = stack.Length - 1;
            while (depth >= 0 && stack[depth].Function != function) depth--;
            if (depth < 0) continue;
            // Running the line itself, the outer call being innermost; a line that called anything, itself included, is
            // only the total's, so a line's self never exceeds its total.
            var allocated = Math.Max(0, lua[index].Allocated);
            var own = depth == 0;
            var at = stack[depth].Line;
            var total = lines.GetValueOrDefault(at) ?? new(at, 0, 0, 0, 0);
            lines[at] = new(at, total.SelfSamples + (own ? 1 : 0), total.Samples + 1,
                total.AllocatedSelf + (own ? allocated : 0), total.AllocatedTotal + allocated);
        }
        return lines.Values.OrderByDescending(line => line.Samples).ThenByDescending(line => line.SelfSamples).ThenBy(line => line.Line).ToArray();
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
        foreach (var item in recording.Heap)
            if (item.Time >= start && item.Time < end) heap = Math.Max(heap ?? 0, item.Used);
        foreach (var item in recording.VideoMemory)
            if (item.Time >= start && item.Time < end) video = Math.Max(video ?? 0, item.Dedicated);
        return (heap, video);
    }

    /// <summary>The last readings at or before a moment: what memory looked like then.</summary>
    public static (ProfileHeapSample? Heap, ProfileVideoMemorySample? VideoMemory) MemoryAt(ProfileRecording recording, long time)
    {
        ProfileHeapSample? heap = null;
        foreach (var item in recording.Heap) { if (item.Time > time) break; heap = item; }
        ProfileVideoMemorySample? video = null;
        foreach (var item in recording.VideoMemory) { if (item.Time > time) break; video = item; }
        return (heap, video);
    }

    /// <summary>
    /// Garbage collections that overlap the range, and how long they paused the game in all. A pause stops
    /// every thread, so it leaves no samples behind; this is where it shows instead.
    /// </summary>
    public static (int Count, double PauseMilliseconds) CollectionsIn(ProfileRecording recording, long start, long end)
    {
        var count = 0;
        long pause = 0;
        foreach (var item in recording.Collections)
        {
            if (item.Time >= end || item.Time + item.Duration < start) continue;
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
        var slowest = new int[result.Length];
        Array.Fill(slowest, -1);
        var span = (double)(end - start);
        for (var index = LowerBound(frames, start, frame => frame.Start); index < frames.Length && frames[index].Start < end; index++)
        {
            var bucket = Math.Min(result.Length - 1, (int)((frames[index].Start - start) / span * result.Length));
            if (slowest[bucket] < 0 || frames[index].Duration > frames[slowest[bucket]].Duration) slowest[bucket] = index;
        }
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
            for (var index = LowerBound(lua, start, sample => sample.Time); index < lua.Length && lua[index].Time < end; index++)
            {
                var stack = recording.LuaStacks[lua[index].Stack];
                if (stack.Length > 0 && OwnerOf(recording.LuaFunctions[stack[0].Function].File).Equals(owner, StringComparison.OrdinalIgnoreCase))
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
            if (GroupOf(recording.Methods[stack[0]]) == owner) micros += sample.Native ? recording.NativePeriod : recording.JavaPeriod;
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

    private static int LowerBound<T>(T[] items, long time, Func<T, long> key)
    {
        int low = 0, high = items.Length;
        while (low < high)
        {
            var middle = (low + high) >>> 1;
            if (key(items[middle]) < time) low = middle + 1; else high = middle;
        }
        return low;
    }
}
