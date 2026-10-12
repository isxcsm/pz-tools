using System.Diagnostics;
using PzTools.Process.Contracts;

namespace PzTools.App.Core;

public enum ExtensionApiStatus
{
    /// <summary>Not looked at yet, or the last look could not finish.</summary>
    Unknown,
    /// <summary>This build of the app carries no PZ Extension API release to install.</summary>
    NotBundled,
    /// <summary>No game folder known.</summary>
    NotFound,
    NotInstalled,
    /// <summary>The game loads PZ Extension API as it starts.</summary>
    Installed,
    /// <summary>Installed, and the game's folder lost part of its entry: installing again puts it back.</summary>
    Reverted,
}

/// <param name="InstallFolder">Where PZ Extension API keeps its files while installed (its <c>loader.log</c> and <c>api.tsv</c>).</param>
/// <param name="Game">How it went in the game that runs now, while installed and one game runs; null when not known.</param>
public sealed record ExtensionApiState(ExtensionApiStatus Status, string? GameFolder = null, string? InstallFolder = null,
    StartupGameReport? Game = null);

/// <summary>
/// Why the install or uninstall did not happen: <c>game-running</c>, <c>game-not-found</c>, <c>not-bundled</c>,
/// <c>unsafe-folder</c>, <c>unsupported-path</c>, <c>release-incomplete</c> or <c>io</c>.
/// </summary>
public sealed class ExtensionApiException(string code, string message, Exception? inner = null) : Exception(message, inner)
{
    public string Code { get; } = code;
}

/// <summary>
/// PZ Extension API is a program of its own (its own repository): Java hooks the game loads as it starts, which Lua
/// mods use through <c>PZExtAPI</c>. PZ Tools only helps to install it: the app carries a release of it (its
/// <c>extension-api</c> folder) and runs that release's installer (<c>pzext-install.jar</c>) with the bridge's runtime,
/// then reads what the API writes to its install folder about the game that runs. Install and uninstall run only while
/// no game runs.
/// </summary>
public sealed class ExtensionApiInstall
{
    /// <summary>Runs the installer with these arguments; gives its exit code and its standard output.</summary>
    public delegate Task<(int ExitCode, string Output)> Tool(IReadOnlyList<string> arguments, CancellationToken cancellationToken);

    private const string Mark = "PZEXT-INSTALL", Failed = "PZEXT-INSTALL-FAILED";
    /// <summary>The installer, in the release folder.</summary>
    public const string Installer = "pzext-install.jar";
    // In the install folder: the loader's line for the last game start, and the API's hooks in the game that runs.
    private const string LoaderLog = "loader.log", ApiStatus = "api.tsv";
    private static readonly TimeSpan StartSlack = TimeSpan.FromSeconds(2);
    private const int MaxStatusBytes = 1 << 16;
    private static readonly TimeSpan ToolTimeout = TimeSpan.FromMinutes(2);

    private readonly string releaseDirectory, java;
    private readonly Func<string?> gameFolder;
    private readonly Func<IReadOnlyList<RunningGame>> games;
    private readonly Tool tool;
    private readonly SemaphoreSlim gate = new(1, 1);
    private volatile ExtensionApiState state = new(ExtensionApiStatus.Unknown);

    /// <param name="releaseDirectory">The app's <c>extension-api</c> folder: a release of PZ Extension API.</param>
    /// <param name="java">A Java 25 runtime's <c>java.exe</c> to run the installer with.</param>
    /// <param name="gameFolder">The game's folder, or null when unknown.</param>
    public ExtensionApiInstall(string releaseDirectory, string java, Func<string?> gameFolder,
        Func<IReadOnlyList<RunningGame>>? games = null, Tool? tool = null)
    {
        this.releaseDirectory = Path.GetFullPath(releaseDirectory);
        this.java = java;
        this.gameFolder = gameFolder;
        this.games = games ?? RunningGames;
        this.tool = tool ?? RunInstaller;
    }

    /// <summary>Raised after the state changed, on a thread-pool thread.</summary>
    public event Action? Changed;

    public ExtensionApiState State => state;

    private bool Bundled => File.Exists(Path.Combine(releaseDirectory, Installer));

    /// <summary>Looks at the game's folder again. A look that fails leaves what was known.</summary>
    public Task RefreshAsync(CancellationToken cancellationToken = default) => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (!Bundled) { Publish(new(ExtensionApiStatus.NotBundled)); return; }
            var folder = gameFolder();
            if (folder is null) { Publish(new(ExtensionApiStatus.NotFound)); return; }
            try
            {
                var next = ReadState(await RunAsync(["status", folder], cancellationToken), folder);
                if (next is { Status: ExtensionApiStatus.Installed, InstallFolder: { } install } && games() is [var game])
                    next = next with { Game = ReadGame(install, game) };
                Publish(next);
            }
            catch (ExtensionApiException error) when (error.Code == "game-not-found") { Publish(new(ExtensionApiStatus.NotFound)); }
            catch (ExtensionApiException) { if (state.Status == ExtensionApiStatus.Unknown) Publish(new(ExtensionApiStatus.Unknown, folder)); }
        }
        finally { gate.Release(); }
    }, cancellationToken);

    /// <summary>Installs the app's release; over an install, brings it up to that release.</summary>
    /// <exception cref="ExtensionApiException">A game runs, the game was not found, or the installer refused.</exception>
    public Task InstallAsync(CancellationToken cancellationToken = default) => ChangeAsync("install", cancellationToken);

    /// <summary>Removes it from the game's folder, then its install folder.</summary>
    /// <exception cref="ExtensionApiException">A game runs, the game was not found, or the installer refused.</exception>
    public Task UninstallAsync(CancellationToken cancellationToken = default) => ChangeAsync("uninstall", cancellationToken);

    private Task ChangeAsync(string command, CancellationToken cancellationToken) => Task.Run(async () =>
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (!Bundled) throw new ExtensionApiException("not-bundled", "This build carries no PZ Extension API.");
            var folder = gameFolder() ?? throw new ExtensionApiException("game-not-found", "The game's folder was not found.");
            if (games().Count > 0) throw new ExtensionApiException("game-running", "Close the game first.");
            try { await RunAsync([command, folder], cancellationToken); }
            finally
            {
                try { Publish(ReadState(await RunAsync(["status", folder], CancellationToken.None), folder)); }
                catch (ExtensionApiException) { }
            }
        }
        finally { gate.Release(); }
    }, cancellationToken);

    private void Publish(ExtensionApiState next)
    {
        if (next == state) return;
        state = next;
        Changed?.Invoke();
    }

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
                throw new ExtensionApiException(fields[1], string.Join(' ', fields.Skip(2)));
            if (fields[0] == Mark && fields.Length >= 2 && exitCode == 0) return string.Join('\t', fields.Skip(1));
        }
        throw new ExtensionApiException("io", $"The installer ended with {exitCode} and no result.");
    }

    /// <summary>The state a status result gives: <c>installed</c>, the version folder and the install folder.</summary>
    internal static ExtensionApiState ReadState(string result, string gameFolder)
    {
        var fields = result.Split('\t');
        var status = fields[0] switch
        {
            "installed" => ExtensionApiStatus.Installed,
            "not-installed" or "uninstalled" => ExtensionApiStatus.NotInstalled,
            "reverted" => ExtensionApiStatus.Reverted,
            var other => throw new ExtensionApiException("io", $"The installer said '{other}'."),
        };
        return new(status, gameFolder, status == ExtensionApiStatus.Installed && fields.Length >= 3 && Path.IsPathFullyQualified(fields[2])
            ? fields[2] : null);
    }

    /// <summary>
    /// What the install folder says about this game run: whether the loader's line is this run's and what it says, and
    /// which hooks the API could not put in. Null when the files cannot be read.
    /// </summary>
    internal static StartupGameReport? ReadGame(string installFolder, RunningGame game)
    {
        if (game.StartedUtc == DateTime.MaxValue) return null;
        var log = new FileInfo(Path.Combine(installFolder, LoaderLog));
        if (!log.Exists || log.LastWriteTimeUtc < game.StartedUtc - StartSlack) return new(StartupGameStatus.StartedWithout, game.ProcessId);
        if (ReadSmall(log) is not { } logText) return null;
        var line = logText.Split('\n')[0].TrimEnd('\r');
        // "<time> loaded api-<id>"; anything else is why it did not load.
        if (!line.Contains(" loaded api-", StringComparison.Ordinal)) return new(StartupGameStatus.LoadFailed, game.ProcessId, line);
        var missing = new List<string>();
        var status = new FileInfo(Path.Combine(installFolder, ApiStatus));
        if (status.Exists && status.LastWriteTimeUtc >= game.StartedUtc - StartSlack && ReadSmall(status) is { } text)
        {
            var lines = text.Split('\n').Select(entry => entry.TrimEnd('\r')).ToArray();
            if (lines is ["PZEXT-API\t1", var pid, ..] && pid == "pid\t" + game.ProcessId)
                foreach (var fields in lines.Skip(2).Select(entry => entry.Split('\t')))
                    if (fields is ["hook", var hook, var hookState] && hookState is not ("applied" or "not-loaded")) missing.Add(hook + ": " + hookState);
        }
        return new(StartupGameStatus.Loaded, game.ProcessId, line, string.Join('\n', missing));
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

    private static IReadOnlyList<RunningGame> RunningGames()
    {
        var found = GameProcessFinder.Find();
        var result = new List<RunningGame>(found.Length);
        foreach (var process in found)
        {
            using (process)
            {
                try { result.Add(new(process.Id, process.StartTime.ToUniversalTime())); }
                catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    result.Add(new(process.Id, DateTime.MaxValue));
                }
            }
        }
        return result;
    }

    private async Task<(int ExitCode, string Output)> RunInstaller(IReadOnlyList<string> arguments, CancellationToken cancellationToken)
    {
        if (!File.Exists(java)) throw new ExtensionApiException("not-bundled", "The runtime to run the installer with is missing.");
        var start = new ProcessStartInfo(java)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        foreach (var value in new[] { "-jar", Path.Combine(releaseDirectory, Installer) }.Concat(arguments)) start.ArgumentList.Add(value);
        using var process = System.Diagnostics.Process.Start(start) ?? throw new ExtensionApiException("io", "The installer did not start.");
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
            throw new ExtensionApiException("io", "The installer did not finish in time.");
        }
        await error;
        return (process.ExitCode, await output);
    }
}
