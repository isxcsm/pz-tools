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
public sealed record StartupLoaderState(StartupLoaderStatus Status, string? GameFolder = null, string? InstallFolder = null);

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
    private static readonly TimeSpan ToolTimeout = TimeSpan.FromMinutes(2);

    private readonly string bridgeDirectory;
    private readonly Func<string?> gameFolder;
    private readonly Func<bool> gameRunning;
    private readonly Tool tool;
    private readonly SemaphoreSlim gate = new(1, 1);
    private StartupLoaderState state = new(StartupLoaderStatus.Unknown);

    /// <param name="bridgeDirectory">The app's <c>game-bridge</c> folder: the runtime, the tool, and the files copied
    /// to the install.</param>
    /// <param name="gameFolder">The game's folder (the one holding <c>projectzomboid.jar</c>), or null when unknown.</param>
    /// <param name="gameRunning">Whether a game runs now; by default any process <see cref="GameProcessFinder"/> finds.</param>
    /// <param name="tool">Runs the install tool; by default the bridge's runtime.</param>
    public StartupLoader(string bridgeDirectory, Func<string?> gameFolder, Func<bool>? gameRunning = null, Tool? tool = null)
    {
        this.bridgeDirectory = Path.GetFullPath(bridgeDirectory);
        this.gameFolder = gameFolder;
        this.gameRunning = gameRunning ?? (() => GameProcessFinder.Count() > 0);
        this.tool = tool ?? RunBridgeTool;
    }

    /// <summary>Raised after the state changed, on whichever thread changed it.</summary>
    public event Action? Changed;

    public StartupLoaderState State => state;

    /// <summary>Looks at the game's folder again. A look that fails leaves what was known.</summary>
    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            var folder = gameFolder();
            if (folder is null) { Publish(new(StartupLoaderStatus.NotFound)); return; }
            try { Publish(ReadState(await RunAsync(["status", folder], cancellationToken), folder)); }
            catch (StartupLoaderException error) when (error.Code == "game-not-found") { Publish(new(StartupLoaderStatus.NotFound)); }
            catch (StartupLoaderException) { if (state.Status == StartupLoaderStatus.Unknown) Publish(new(StartupLoaderStatus.Unknown, folder)); }
        }
        finally { gate.Release(); }
    }

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
    /// Nothing happens when nothing is installed. Not while a game runs: the bridge it started with, and the
    /// extensions it runs from there, stay until it ends. False when it did not run for that.
    /// </summary>
    public async Task<bool> RefreshBridgeAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (gameRunning()) return false;
            await RunAsync(["refresh", bridgeDirectory], cancellationToken);
            return true;
        }
        finally { gate.Release(); }
    }

    /// <summary>
    /// Writes what a game started by the loader runs without the app (<see cref="ResidentExtensionRequest"/>) to the
    /// install folder, when it changed. Nothing happens unless installed. True when it was written.
    /// </summary>
    /// <param name="runtimeRoot">The app's data folder: the extension settings and the tuning files.</param>
    public async Task<bool> UpdateResidentExtensionsAsync(string runtimeRoot, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            // Under the gate: an uninstall removes the folder, and must not find a file being written into it.
            if (state is not { Status: StartupLoaderStatus.Installed, InstallFolder: { } folder }) return false;
            return await Task.Run(() => ResidentExtensionRequest.Write(folder, ResidentExtensionRequest.Build(bridgeDirectory, runtimeRoot)),
                cancellationToken);
        }
        finally { gate.Release(); }
    }

    private async Task ChangeAsync(Func<string, string[]> arguments, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            var folder = gameFolder() ?? throw new StartupLoaderException("game-not-found", "The game's folder was not found.");
            if (gameRunning()) throw new StartupLoaderException("game-running", "Close the game first.");
            try { await RunAsync(arguments(folder), cancellationToken); }
            finally
            {
                // What the game has now, whether the change went through or stopped half way.
                try { Publish(ReadState(await RunAsync(["status", folder], CancellationToken.None), folder)); }
                catch (StartupLoaderException) { }
            }
        }
        finally { gate.Release(); }
    }

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

    /// <summary>The state a status result gives: installed results name the install folder after the entry's digest.</summary>
    internal static StartupLoaderState ReadState(string result, string gameFolder)
    {
        var status = Parse(result);
        var fields = result.Split('\t');
        return new(status, gameFolder, status == StartupLoaderStatus.Installed && fields.Length >= 3 && Path.IsPathFullyQualified(fields[2])
            ? fields[2] : null);
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
