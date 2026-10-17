using System.Diagnostics;
using DiagnosticsProcess = System.Diagnostics.Process;

namespace PzTools.Process.Contracts;

/// <summary>
/// The running game's processes. Asking for each process name separately took a snapshot of every
/// process on the system per name; one snapshot, filtered here, answers for all of them.
/// </summary>
public static class GameProcessFinder
{
    /// <summary>The executable names the game runs under.</summary>
    public static IReadOnlyList<string> Names { get; } = ["ProjectZomboid64", "ProjectZomboid32", "ProjectZomboid"];

    /// <summary>
    /// The Java runtime the game can be started with directly, without its launcher: the game's own
    /// ProjectZomboid64.bat does, and so do launch scripts players set in Steam. Such a process is the game only
    /// when its command line starts the game's client (<see cref="ClientMainClass"/>); a dedicated server and
    /// any other Java program are not.
    /// </summary>
    public static IReadOnlyList<string> JavaNames { get; } = ["java", "javaw"];

    private const string ClientMainClass = "zombie.gameStates.MainScreenState";
    // The class as a whole name: not part of a longer one, nor a file or package path that only ends in it.
    private static readonly System.Text.RegularExpressions.Regex ClientCommand = new(
        @"(?<![\w.$/\\])" + System.Text.RegularExpressions.Regex.Escape(ClientMainClass) + @"(?![\w.$])",
        System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    // A Java process's verdict, read once from its command line: by process instance (identifier and start time).
    private static readonly Dictionary<(int Id, DateTime Started), (bool Game, int? AssemblesFor)> javaVerdicts = [];

    /// <summary>The game was started by its Java runtime directly, not by its launcher, which then read nothing of
    /// the launcher's file (ProjectZomboid64.json).</summary>
    public static bool IsStartedWithoutLauncher(DiagnosticsProcess game)
    {
        try { return JavaNames.Contains(game.ProcessName, StringComparer.OrdinalIgnoreCase); }
        catch (InvalidOperationException) { return false; }
    }

    /// <summary>A Java command line that starts the game's client.</summary>
    public static bool IsGameCommandLine(string? commandLine) =>
        commandLine is not null && ClientCommand.IsMatch(commandLine);

    /// <summary>
    /// How old a shared snapshot may be for loops that only watch for the game to come or go. A snapshot
    /// costs about 5 ms; noticing a starting game a few seconds later does not matter, as its load takes
    /// far longer. An exit is not polled for: it is signalled by the process itself.
    /// </summary>
    public static readonly TimeSpan WatchSnapshotAge = TimeSpan.FromSeconds(5);

    private static readonly object Gate = new();
    private static (long Taken, (int Id, DateTime Started)[] Games)? recent;

    /// <summary>The game processes now running. The caller disposes them.</summary>
    public static DiagnosticsProcess[] Find()
    {
        var all = DiagnosticsProcess.GetProcesses();
        var games = new List<DiagnosticsProcess>(1);
        var javas = new HashSet<(int, DateTime)>();
        var assembling = new List<(int Parent, DateTime Started)>();
        foreach (var process in all)
        {
            bool game;
            try
            {
                var name = process.ProcessName;
                game = Names.Contains(name, StringComparer.OrdinalIgnoreCase);
                if (!game && JavaNames.Contains(name, StringComparer.OrdinalIgnoreCase))
                {
                    var verdict = JavaVerdict(process, javas);
                    game = verdict.Game;
                    if (verdict.AssemblesFor is { } parent) assembling.Add((parent, process.StartTime));
                }
            }
            catch (Exception exception) when (exception is InvalidOperationException // exited during the snapshot
                or System.ComponentModel.Win32Exception or NotSupportedException) { game = false; }
            if (game) games.Add(process);
            else process.Dispose();
        }
        // Verdicts of Java processes gone since are forgotten.
        lock (Gate) foreach (var gone in javaVerdicts.Keys.Where(key => !javas.Contains(key)).ToArray()) javaVerdicts.Remove(gone);
        // A game whose Java writes its AOT cache as it ends (-XX:AOTCacheOutput, which PZ Optimize sets) has left its
        // world and its window: its process only waits, minutes long, for the child Java that assembles the cache.
        // It is not a game to attach to or to wait for any more: the attach would fail on a JVM that is shutting down.
        if (assembling.Count > 0)
        {
            games.RemoveAll(game =>
            {
                bool ending;
                try { ending = assembling.Any(child => child.Parent == game.Id && child.Started >= game.StartTime); }
                catch (Exception exception) when (exception is InvalidOperationException
                    or System.ComponentModel.Win32Exception or NotSupportedException) { ending = false; }
                if (ending) game.Dispose();
                return ending;
            });
        }
        var found = games.ToArray();
        Remember(found);
        return found;
    }

    /// <summary>
    /// The command line the JVM gives the child it starts to assemble an AOT cache as it exits: its own launcher's path
    /// and nothing else (the options go in the child's environment, JAVA_TOOL_OPTIONS). A Java run by a person or a
    /// script always names something to run.
    /// </summary>
    public static bool IsAotAssemblyCommandLine(string? commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine)) return false;
        // The path is given unquoted even with spaces in it (C:\Program Files (x86)\...\jre64\bin\java): the whole
        // line is that path, which ends in the launcher's name; any argument after it would end the line instead.
        var text = commandLine.Trim().Trim('"');
        var slash = text.LastIndexOfAny(['\\', '/']);
        if (slash < 0) return false;
        var name = text[(slash + 1)..];
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        return JavaNames.Contains(name, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Like <see cref="Find"/>, but reuses a snapshot taken within <paramref name="maximumAge"/>: for loops
    /// that only watch for the game to come or go. A listing of every process on the machine is what such a
    /// loop costs; two loops a second each taking one was most of an idle scheduler's CPU. A process from
    /// that snapshot is returned only while it still runs as the same instance (same start time).
    /// </summary>
    public static DiagnosticsProcess[] Find(TimeSpan maximumAge)
    {
        (int Id, DateTime Started)[]? games = null;
        lock (Gate)
            if (recent is { } last && Stopwatch.GetElapsedTime(last.Taken) <= maximumAge) games = last.Games;
        if (games is null) return Find();
        var result = new List<DiagnosticsProcess>(games.Length);
        foreach (var (id, started) in games)
        {
            DiagnosticsProcess? process = null;
            try
            {
                process = DiagnosticsProcess.GetProcessById(id);
                if (!process.HasExited && process.StartTime == started) { result.Add(process); process = null; }
            }
            catch (Exception exception) when (exception is ArgumentException or InvalidOperationException
                or System.ComponentModel.Win32Exception or NotSupportedException) { }
            finally { process?.Dispose(); }
        }
        return [.. result];
    }

    /// <summary>How many game processes are running.</summary>
    public static int Count()
    {
        var found = Find();
        foreach (var process in found) process.Dispose();
        return found.Length;
    }

    // What a Java process is, read once from its command line: the game, or the AOT assembler of the process that
    // started it (its parent's id), or neither.
    private static (bool Game, int? AssemblesFor) JavaVerdict(DiagnosticsProcess process, HashSet<(int, DateTime)> seen)
    {
        var key = (process.Id, process.StartTime);
        seen.Add(key);
        lock (Gate) if (javaVerdicts.TryGetValue(key, out var known)) return known;
        // A command line that cannot be read (a protected process, or another user's where this runs without
        // administrator rights) is not taken for the game. As administrator another user's game is read and counts,
        // as one found by its launcher's name always has.
        var commandLine = CommandLine(process.Id);
        (bool, int?) verdict = IsGameCommandLine(commandLine) ? (true, null)
            : IsAotAssemblyCommandLine(commandLine) ? (false, ParentId(process.Id)) : (false, null);
        lock (Gate) javaVerdicts[key] = verdict;
        return verdict;
    }

    // ProcessBasicInformation: the parent's id is its sixth pointer-sized field (InheritedFromUniqueProcessId).
    private static int? ParentId(int processId)
    {
        if (!OperatingSystem.IsWindows()) return null;
        using var handle = OpenProcess(QueryLimitedInformation, false, processId);
        if (handle.IsInvalid) return null;
        var size = IntPtr.Size * 6;
        var buffer = System.Runtime.InteropServices.Marshal.AllocHGlobal(size);
        try
        {
            if (NtQueryInformationProcess(handle, ProcessBasicInformation, buffer, size, out _) != 0) return null;
            return (int)System.Runtime.InteropServices.Marshal.ReadIntPtr(buffer, IntPtr.Size * 5);
        }
        finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(buffer); }
    }

    // ProcessCommandLineInformation: the process's command line as a UNICODE_STRING followed by its text.
    private static string? CommandLine(int processId)
    {
        if (!OperatingSystem.IsWindows()) return null;
        using var handle = OpenProcess(QueryLimitedInformation, false, processId);
        if (handle.IsInvalid) return null;
        NtQueryInformationProcess(handle, ProcessCommandLineInformation, IntPtr.Zero, 0, out var length);
        if (length <= IntPtr.Size * 2 || length > 1 << 20) return null;
        var buffer = System.Runtime.InteropServices.Marshal.AllocHGlobal(length);
        try
        {
            if (NtQueryInformationProcess(handle, ProcessCommandLineInformation, buffer, length, out _) != 0) return null;
            int bytes = (ushort)System.Runtime.InteropServices.Marshal.ReadInt16(buffer);
            var text = System.Runtime.InteropServices.Marshal.ReadIntPtr(buffer, IntPtr.Size);
            return text == IntPtr.Zero ? null : System.Runtime.InteropServices.Marshal.PtrToStringUni(text, bytes / 2);
        }
        finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(buffer); }
    }

    private const uint QueryLimitedInformation = 0x1000;
    private const int ProcessCommandLineInformation = 60, ProcessBasicInformation = 0;

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern Microsoft.Win32.SafeHandles.SafeProcessHandle OpenProcess(uint access, bool inherit, int processId);

    [System.Runtime.InteropServices.DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(Microsoft.Win32.SafeHandles.SafeProcessHandle process, int informationClass,
        IntPtr information, int length, out int returnLength);

    private static void Remember(DiagnosticsProcess[] games)
    {
        var known = new List<(int, DateTime)>(games.Length);
        foreach (var game in games)
        {
            try { known.Add((game.Id, game.StartTime)); }
            catch (Exception exception) when (exception is InvalidOperationException
                or System.ComponentModel.Win32Exception or NotSupportedException)
            {
                // A game whose start time cannot be read is not remembered; the next call takes a new snapshot.
                lock (Gate) recent = null;
                return;
            }
        }
        lock (Gate) recent = (Stopwatch.GetTimestamp(), [.. known]);
    }
}
