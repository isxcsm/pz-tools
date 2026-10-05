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
    private static readonly System.Text.RegularExpressions.Regex ClientCommand = new(
        @"(?<![\w.$/\\])zombie\.gameStates\.MainScreenState(?![\w.$])", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    // A Java process's verdict, read once from its command line: by process instance (identifier and start time).
    private static readonly Dictionary<(int Id, DateTime Started), bool> javaVerdicts = [];

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
        foreach (var process in all)
        {
            bool game;
            try
            {
                var name = process.ProcessName;
                game = Names.Contains(name, StringComparer.OrdinalIgnoreCase)
                    || JavaNames.Contains(name, StringComparer.OrdinalIgnoreCase) && IsJavaGame(process, javas);
            }
            catch (Exception exception) when (exception is InvalidOperationException // exited during the snapshot
                or System.ComponentModel.Win32Exception or NotSupportedException) { game = false; }
            if (game) games.Add(process);
            else process.Dispose();
        }
        // Verdicts of Java processes gone since are forgotten.
        lock (Gate) foreach (var gone in javaVerdicts.Keys.Where(key => !javas.Contains(key)).ToArray()) javaVerdicts.Remove(gone);
        var found = games.ToArray();
        Remember(found);
        return found;
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

    private static bool IsJavaGame(DiagnosticsProcess process, HashSet<(int, DateTime)> seen)
    {
        var key = (process.Id, process.StartTime);
        seen.Add(key);
        lock (Gate) if (javaVerdicts.TryGetValue(key, out var known)) return known;
        // A command line that cannot be read (a process of another user) is not the player's game.
        var verdict = IsGameCommandLine(CommandLine(process.Id));
        lock (Gate) javaVerdicts[key] = verdict;
        return verdict;
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
    private const int ProcessCommandLineInformation = 60;

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
