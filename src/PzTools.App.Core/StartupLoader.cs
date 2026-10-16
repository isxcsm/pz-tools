using System.Diagnostics;
using PzTools.GameExtensions;
using PzTools.Process.Contracts;

namespace PzTools.App.Core;

public enum StartupLoaderStatus
{
    /// <summary>Not looked at yet, or the last look could not finish.</summary>
    Unknown,
    /// <summary>No game folder known: no game installed through Steam, and none running.</summary>
    NotFound,
    /// <summary>The game's folder has no startup loader.</summary>
    NotInstalled,
    /// <summary>The game's folder has the install's entry: the game loads the bridge as it starts.</summary>
    Installed,
    /// <summary>Installed before, and the game's folder no longer has all of it (or, for an install an earlier version
    /// put in the jar, a game update replaced the jar).</summary>
    Reverted,
    /// <summary>The game's jar has a startup loader patched in that this install has no record of; it is left alone.</summary>
    Foreign,
}

/// <param name="InstallFolder">Where the install keeps its files, while installed: the app writes there what the game's
/// resident extensions run.</param>
/// <param name="Game">How the loader went in the game that runs now, while installed and one game runs; null when
/// that is not known.</param>
/// <param name="LauncherEntry">What the game's launcher file (<c>ProjectZomboid64.json</c>) says of the loader's own class
/// path entry, while installed; <see cref="StartupLauncherEntry.Unknown"/> when the install tool did not say.</param>
public sealed record StartupLoaderState(StartupLoaderStatus Status, string? GameFolder = null, string? InstallFolder = null,
    StartupGameReport? Game = null, StartupLauncherEntry LauncherEntry = StartupLauncherEntry.Unknown);

/// <summary>
/// The loader's jar in the class path of the game's launcher file. Tools that rewrite that file (PZ Optimize's AOT step
/// drops the game's folder from the class path) keep an entry added after the game's jar, so the loader starts through
/// the entry where the game's folder is no longer on the class path.
/// </summary>
public enum StartupLauncherEntry
{
    /// <summary>Not said: the install tool's result had no launcher field.</summary>
    Unknown,
    /// <summary>The class path lists the jar.</summary>
    Listed,
    /// <summary>The class path lacks it (a reset of the game's files put the plain file back): the next game start, or the
    /// next refresh, adds it.</summary>
    Absent,
    /// <summary>There is no launcher file; the game's folder serves.</summary>
    None,
    /// <summary>The file has no class path list the install can edit; the game's folder serves where it is still on the
    /// class path.</summary>
    Unreadable,
}

/// <summary>A game process, by its identifier and the time it started.</summary>
public readonly record struct RunningGame(int ProcessId, DateTime StartedUtc);

public enum StartupGameStatus
{
    /// <summary>The loader loaded the bridge as the game started.</summary>
    Loaded,
    /// <summary>The game started without the loader: before it was installed, or the game did not run it.</summary>
    StartedWithout,
    /// <summary>The loader ran and did not load the bridge; the report's detail says why.</summary>
    LoadFailed,
}

/// <summary>What a loader (PZ Tools' startup loader, or PZ Extension API's) says about one game run, from its install folder.</summary>
/// <param name="Detail">The loader's own line, for the log.</param>
/// <param name="MissingHooks">PZ Extension API's hooks the game could not put in, one per line as
/// <c>Class.method: why</c>; empty when all went in, or the game has not said yet.</param>
public sealed record StartupGameReport(StartupGameStatus Status, int ProcessId, string Detail = "", string MissingHooks = "")
{
    /// <summary>Whether the player should hear about it: the loader did not load, or a hook is missing.</summary>
    public bool HasProblem => Status != StartupGameStatus.Loaded || MissingHooks.Length > 0;

    /// <summary>The missing hooks' names, without the reasons.</summary>
    public IEnumerable<string> MissingHookNames =>
        MissingHooks.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.Split(": ", 2)[0]);
}

/// <summary>
/// Why the install or uninstall did not happen: <c>game-running</c>, <c>game-not-found</c>, <c>unsupported-game</c>,
/// <c>foreign-install</c>, <c>original-missing</c>, <c>unsafe-folder</c>, <c>unsupported-path</c>,
/// <c>bridge-not-built</c> or <c>io</c>.
/// </summary>
public sealed class StartupLoaderException(string code, string message, Exception? inner = null) : Exception(message, inner)
{
    public string Code { get; } = code;
}

/// <summary>
/// The startup loader (docs/design/startup-loader.md): an optional install that adds PZ Tools' own files to the game's
/// folder so the game loads the bridge as it starts, without the app; no game file changes. The work is done by the
/// bridge's own runtime (<c>pztools.bridge.StartupInstall</c>); this class decides when it may run and reads what it
/// says. Install and uninstall run only while no game runs: a game started mid-install would find half of one, and
/// turning an earlier version's install (a patched jar) into this kind puts back a jar a running game holds.
/// </summary>
public sealed class StartupLoader
{
    /// <summary>Runs the install tool with these arguments; gives its exit code and its standard output.</summary>
    public delegate Task<(int ExitCode, string Output)> Tool(IReadOnlyList<string> arguments, CancellationToken cancellationToken);

    private const string Mark = "PZTOOLS-STARTUP", Failed = "PZTOOLS-STARTUP-FAILED";
    // In the install folder: the loader's line for the last game start (pztools.launch.StartupLoader.LOG).
    private const string LoaderLog = "startup.log";
    // File times against a process's start: the loader writes its line about half a second after the game starts.
    private static readonly TimeSpan StartSlack = TimeSpan.FromSeconds(2);
    private const int MaxStatusBytes = 1 << 16;
    private static readonly TimeSpan ToolTimeout = TimeSpan.FromMinutes(2);

    private readonly string bridgeDirectory;
    private readonly Func<string?> gameFolder;
    private readonly Func<IReadOnlyList<RunningGame>> games;
    private readonly Tool tool;
    private readonly SemaphoreSlim gate = new(1, 1);
    // Written on the thread pool, read from any thread.
    private volatile StartupLoaderState state = new(StartupLoaderStatus.Unknown);

    /// <param name="bridgeDirectory">The app's <c>game-bridge</c> folder: the runtime, the tool, and the files copied
    /// to the install.</param>
    /// <param name="gameFolder">The game's folder (the one holding <c>projectzomboid.jar</c>), or null when unknown.</param>
    /// <param name="games">The games running now; by default the processes <see cref="GameProcessFinder"/> finds.</param>
    /// <param name="tool">Runs the install tool; by default the bridge's runtime.</param>
    public StartupLoader(string bridgeDirectory, Func<string?> gameFolder, Func<IReadOnlyList<RunningGame>>? games = null,
        Tool? tool = null)
    {
        this.bridgeDirectory = Path.GetFullPath(bridgeDirectory);
        this.gameFolder = gameFolder;
        this.games = games ?? RunningGames;
        this.tool = tool ?? RunBridgeTool;
    }

    private bool GameRunning() => games().Count > 0;

    private static IReadOnlyList<RunningGame> RunningGames()
    {
        var found = GameProcessFinder.Find();
        var result = new List<RunningGame>(found.Length);
        foreach (var process in found)
        {
            using (process)
            {
                try { result.Add(new(process.Id, process.StartTime.ToUniversalTime())); }
                // Gone since, or its start time cannot be read: still a game that runs, of unknown start.
                catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    result.Add(new(process.Id, DateTime.MaxValue));
                }
            }
        }
        return result;
    }

    /// <summary>Raised after the state changed, on a thread-pool thread: a UI subscriber moves to its own thread.</summary>
    public event Action? Changed;

    public StartupLoaderState State => state;

    // Every public method does its work on the thread pool, whichever thread calls it: each one may start the install
    // tool, look for the game's processes or read files, and the app calls them from its UI thread.

    /// <summary>Looks at the game's folder again. A look that fails leaves what was known.</summary>
    public Task RefreshAsync(CancellationToken cancellationToken = default) => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            var folder = gameFolder();
            if (folder is null) { Publish(new(StartupLoaderStatus.NotFound)); return; }
            try
            {
                var next = ReadState(await RunAsync(["status", folder], cancellationToken), folder);
                if (next is { Status: StartupLoaderStatus.Installed, InstallFolder: { } install } && games() is [var game])
                    next = next with { Game = ReadGame(install, game) };
                Publish(next);
            }
            catch (StartupLoaderException error) when (error.Code == "game-not-found") { Publish(new(StartupLoaderStatus.NotFound)); }
            catch (StartupLoaderException) { if (state.Status == StartupLoaderStatus.Unknown) Publish(new(StartupLoaderStatus.Unknown, folder)); }
        }
        finally { gate.Release(); }
    }, cancellationToken);

    /// <summary>Adds the loader to the game's folder; installing again over an install only brings it up to date.</summary>
    /// <exception cref="StartupLoaderException">A game runs, the game was not found, or the tool refused.</exception>
    public Task InstallAsync(CancellationToken cancellationToken = default) =>
        ChangeAsync(folder => ["install", folder, bridgeDirectory], cancellationToken);

    /// <summary>Removes the loader from the game's folder (and puts back the jar an earlier version patched, unless an
    /// update already did), then the install folder.</summary>
    /// <exception cref="StartupLoaderException">A game runs, the game was not found, or the tool refused.</exception>
    public Task UninstallAsync(CancellationToken cancellationToken = default) =>
        ChangeAsync(folder => ["uninstall", folder], cancellationToken);

    /// <summary>
    /// Brings the install's copy of the bridge, and its entry in the game's folder, up to this app's, so the next game
    /// start loads the bridge of this version; an earlier version's install in the jar becomes one in the folder.
    /// A launcher file that lost the jar's entry (a reset of the game's files) gets it back. Nothing happens when nothing is
    /// installed. Not while a game runs: the bridge it started with, and the
    /// extensions it runs from there, stay until it ends. False when it did not run for that.
    /// </summary>
    public Task<bool> RefreshBridgeAsync(CancellationToken cancellationToken = default) => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (GameRunning()) return false;
            await RunAsync(["refresh", bridgeDirectory], cancellationToken);
            return true;
        }
        finally { gate.Release(); }
    }, cancellationToken);

    /// <summary>
    /// Writes what a game started by the loader runs without the app (<see cref="ResidentExtensionRequest"/>) to the
    /// install folder, when it changed. Nothing happens unless installed. True when it was written. While the files the
    /// request is built from, and the request's own file, keep their time and length, it is not built again.
    /// </summary>
    /// <param name="runtimeRoot">The app's data folder: the extension settings and the tuning files.</param>
    public Task<bool> UpdateResidentExtensionsAsync(string runtimeRoot, CancellationToken cancellationToken = default) => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            // Under the gate: an uninstall removes the folder, and must not find a file being written into it.
            if (state is not { Status: StartupLoaderStatus.Installed, InstallFolder: { } folder }) return false;
            var target = Path.Combine(folder, ResidentExtensionRequest.FileName);
            // Taken before the build: a file that changes while it is read differs from this the next time.
            var inputs = ResidentExtensionRequest.InputStamp(bridgeDirectory, runtimeRoot);
            if (inputs is not null && residentWritten is { } last && last == (folder, inputs, ResidentExtensionRequest.Stamp(target))) return false;
            var written = ResidentExtensionRequest.Write(folder, ResidentExtensionRequest.Build(bridgeDirectory, runtimeRoot));
            residentWritten = inputs is null ? null : (folder, inputs, ResidentExtensionRequest.Stamp(target));
            return written;
        }
        finally { gate.Release(); }
    }, cancellationToken);

    // Where the resident request was last written, the stamp of what it was built from, and its own file's stamp after.
    private (string Folder, string Inputs, string? Request)? residentWritten;

    private Task ChangeAsync(Func<string, string[]> arguments, CancellationToken cancellationToken) => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            var folder = gameFolder() ?? throw new StartupLoaderException("game-not-found", "The game's folder was not found.");
            if (GameRunning()) throw new StartupLoaderException("game-running", "Close the game first.");
            try { await RunAsync(arguments(folder), cancellationToken); }
            finally
            {
                // What the game has now, whether the change went through or stopped half way.
                try { Publish(ReadState(await RunAsync(["status", folder], CancellationToken.None), folder)); }
                catch (StartupLoaderException) { }
            }
        }
        finally { gate.Release(); }
    }, cancellationToken);

    private void Publish(StartupLoaderState next)
    {
        if (next == state) return;
        state = next;
        Changed?.Invoke();
    }

    /// <summary>The tool's result line after the mark, or its failure as an exception.</summary>
    private async Task<string> RunAsync(IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        (int exitCode, string output) = await tool(arguments, cancellationToken);
        return Result(exitCode, output);
    }

    internal static string Result(int exitCode, string output)
    {
        foreach (var line in output.Split('\n').Select(line => line.TrimEnd('\r')).Reverse())
        {
            var fields = line.Split('\t');
            if (fields[0] == Failed && fields.Length >= 3)
                throw new StartupLoaderException(fields[1], string.Join(' ', fields.Skip(2)));
            if (fields[0] == Mark && fields.Length >= 2 && exitCode == 0) return string.Join('\t', fields.Skip(1));
        }
        throw new StartupLoaderException("io", $"The install tool ended with {exitCode} and no result.");
    }

    /// <summary>The state a status result gives: installed results name the install folder after the entry's digest, then
    /// what the launcher file says of the jar's entry (<c>launcher=listed</c>).</summary>
    internal static StartupLoaderState ReadState(string result, string gameFolder)
    {
        var status = Parse(result);
        var fields = result.Split('\t');
        bool installed = status == StartupLoaderStatus.Installed;
        var launcher = installed && fields.Length >= 4 && fields[3].StartsWith("launcher=", StringComparison.Ordinal)
            ? fields[3]["launcher=".Length..] switch
            {
                "listed" => StartupLauncherEntry.Listed,
                "absent" => StartupLauncherEntry.Absent,
                "none" => StartupLauncherEntry.None,
                "unreadable" => StartupLauncherEntry.Unreadable,
                _ => StartupLauncherEntry.Unknown,
            }
            : StartupLauncherEntry.Unknown;
        return new(status, gameFolder, installed && fields.Length >= 3 && Path.IsPathFullyQualified(fields[2]) ? fields[2] : null,
            LauncherEntry: launcher);
    }

    /// <summary>
    /// What the install folder says about this game run: whether the loader's line is this run's, and what it says.
    /// Null when the file cannot be read.
    /// </summary>
    internal static StartupGameReport? ReadGame(string installFolder, RunningGame game)
    {
        if (game.StartedUtc == DateTime.MaxValue) return null;
        var log = new FileInfo(Path.Combine(installFolder, LoaderLog));
        if (!log.Exists || log.LastWriteTimeUtc < game.StartedUtc - StartSlack) return new(StartupGameStatus.StartedWithout, game.ProcessId);
        if (ReadSmall(log) is not { } logText) return null;
        var line = logText.Split('\n')[0].TrimEnd('\r');
        // "<time> loaded bridge-<id>"; anything else is why it did not load.
        if (!line.Contains(" loaded bridge-", StringComparison.Ordinal)) return new(StartupGameStatus.LoadFailed, game.ProcessId, line);
        return new(StartupGameStatus.Loaded, game.ProcessId, line);
    }

    private static string? ReadSmall(FileInfo file)
    {
        try
        {
            using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var buffer = new byte[MaxStatusBytes];
            int length = 0, read;
            while (length < buffer.Length && (read = stream.Read(buffer, length, buffer.Length - length)) > 0) length += read;
            return System.Text.Encoding.UTF8.GetString(buffer, 0, length);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return null; }
    }

    internal static StartupLoaderStatus Parse(string result) => result.Split('\t')[0] switch
    {
        "installed" => StartupLoaderStatus.Installed,
        "not-installed" => StartupLoaderStatus.NotInstalled,
        "reverted" => StartupLoaderStatus.Reverted,
        "foreign" => StartupLoaderStatus.Foreign,
        var other => throw new StartupLoaderException("io", $"The install tool said '{other}'."),
    };

    private async Task<(int ExitCode, string Output)> RunBridgeTool(IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        var java = Path.Combine(bridgeDirectory, "runtime", "bin", "java.exe");
        var jar = Path.Combine(bridgeDirectory, "pztools-game-bridge.jar");
        if (!File.Exists(java) || !File.Exists(jar))
            throw new StartupLoaderException("bridge-not-built", "The bridge is not included in this build.");
        var start = new ProcessStartInfo(java)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        foreach (var value in new[] { "-cp", jar, "pztools.bridge.StartupInstall" }.Concat(arguments)) start.ArgumentList.Add(value);
        // No game's account is passed (unlike an attach): the install folder is named for the account the app works
        // for (USERDOMAIN\USERNAME of this process), the same on every run whether or not a game runs.
        using var process = System.Diagnostics.Process.Start(start) ?? throw new StartupLoaderException("io", "The install tool did not start.");
        var output = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var error = process.StandardError.ReadToEndAsync(CancellationToken.None);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(ToolTimeout);
        try { await process.WaitForExitAsync(deadline.Token); }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            await process.WaitForExitAsync(CancellationToken.None);
            if (cancellationToken.IsCancellationRequested) throw;
            throw new StartupLoaderException("io", "The install tool did not finish in time.");
        }
        await error;
        return (process.ExitCode, await output);
    }
}
