using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using DiagnosticsProcess = System.Diagnostics.Process;

namespace PzTools.GameBridge;

/// <summary>What the game's recorder reports: fixed fields, no free text.</summary>
public sealed record GameProfileStatus(string State, long ElapsedMilliseconds, long Frames, string Mode, string Lua, bool HasFrames)
{
    public bool Recording => State == "recording";
    /// <summary>Keeping only its last stretch, until saved from or stopped.</summary>
    public bool Rolling => State == "rolling";

    public static GameProfileStatus Parse(string detail)
    {
        var parts = detail.Split(';');
        if (parts.Length is < 5 or > 6 || parts[0] is not ("idle" or "recording" or "rolling" or "finished")
            || !long.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var elapsed)
            || !long.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var frames)
            || parts[3] is not ("general" or "detailed"))
            throw new GameSaveException("invalid-response", "Unexpected profile status.");
        return new(parts[0], elapsed, frames, parts[3], parts[4], parts.Length != 6 || parts[5] == "frames");
    }
}

public sealed record GameProfileExport(long Samples, long Frames, long LuaSamples, long DurationMicroseconds);

/// <summary>
/// Starts and stops a recording inside the running game and converts the result. Each call is one
/// short request on the ordinary bridge channel; the recording itself runs in the game between calls.
/// </summary>
public sealed partial class GameProfileClient(string bridgeDirectory, int connectionTimeoutSeconds = 30)
{
    public const int MaximumSeconds = 1800;

    /// <summary>The one running game, or an error that says why there is no single one.</summary>
    public static int FindGame()
    {
        var games = PzTools.Process.Contracts.GameProcessFinder.Find();
        try
        {
            return games.Length == 1 ? games[0].Id
                : throw new GameSaveException(games.Length == 0 ? "game-not-running" : "multiple-games",
                    games.Length == 0 ? "Start the game first." : "More than one game process is running.");
        }
        finally { foreach (var game in games) game.Dispose(); }
    }

    /// <param name="owner">The app run asking (AppRun): the game ends the recording once that run's lease lapses.</param>
    public Task<GameProfileStatus> StartAsync(int processId, string recordingPath, bool detailed, int maximumSeconds,
        CancellationToken cancellationToken = default, string? owner = null)
    {
        if (!Path.IsPathFullyQualified(recordingPath) || !recordingPath.EndsWith(".jfr", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("An absolute .jfr path is required.", nameof(recordingPath));
        if (maximumSeconds is < 5 or > MaximumSeconds) throw new ArgumentOutOfRangeException(nameof(maximumSeconds));
        if (owner is not null && !GameRuntimeClient.IsAppRun(owner)) throw new ArgumentException("Not an app run.", nameof(owner));
        var command = string.Join('\t', "PROFILE_START",
            Convert.ToBase64String(Encoding.UTF8.GetBytes(recordingPath)), detailed ? "detailed" : "general",
            maximumSeconds.ToString(CultureInfo.InvariantCulture));
        return RequestAsync(processId, owner is null ? command : command + "\t" + owner, cancellationToken);
    }

    public Task<GameProfileStatus> StopAsync(int processId, CancellationToken cancellationToken = default) =>
        RequestAsync(processId, "PROFILE_STOP", cancellationToken);

    public const int MinimumRollingSeconds = 10, MaximumRollingSeconds = 600;
    public const int MinimumRollingMegabytes = 64, MaximumRollingMegabytes = 2048;

    /// <summary>
    /// Starts a recording that keeps only about its last <paramref name="keepSeconds"/> and runs until stopped, for a
    /// stutter that already happened. A recording started with <see cref="StartAsync"/> runs beside it, and a file of
    /// either is converted back to its own mode's sampling by <see cref="ExportAsync"/> given its mode.
    /// </summary>
    /// <param name="maxMegabytes">The most the game holds on disk; 0 for the game's own default.</param>
    /// <param name="owner">The app run keeping it (32 hex digits): the game ends it once that run's lease lapses, so an
    /// app that crashed does not leave the game recording. The run's state stream renews it (GameRuntimeClient); none
    /// for a recording kept until stopped.</param>
    public Task<GameProfileStatus> StartRollingAsync(int processId, bool detailed, int keepSeconds,
        CancellationToken cancellationToken = default, int maxMegabytes = 0, string? owner = null)
    {
        if (keepSeconds is < MinimumRollingSeconds or > MaximumRollingSeconds) throw new ArgumentOutOfRangeException(nameof(keepSeconds));
        if (maxMegabytes != 0 && maxMegabytes is < MinimumRollingMegabytes or > MaximumRollingMegabytes)
            throw new ArgumentOutOfRangeException(nameof(maxMegabytes));
        if (owner is not null && !GameRuntimeClient.IsAppRun(owner)) throw new ArgumentException("Not an app run.", nameof(owner));
        var command = string.Join('\t', "PROFILE_ROLL_START", detailed ? "detailed" : "general", keepSeconds.ToString(CultureInfo.InvariantCulture));
        if (maxMegabytes != 0 || owner is not null) command += "\t" + maxMegabytes.ToString(CultureInfo.InvariantCulture);
        if (owner is not null) command += "\t" + owner;
        return RequestAsync(processId, command, cancellationToken);
    }

    /// <summary>Writes what the rolling recording holds to <paramref name="recordingPath"/>; it goes on recording.</summary>
    public Task<GameProfileStatus> SaveRollingAsync(int processId, string recordingPath, CancellationToken cancellationToken = default)
    {
        if (!Path.IsPathFullyQualified(recordingPath) || !recordingPath.EndsWith(".jfr", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("An absolute .jfr path is required.", nameof(recordingPath));
        return RequestAsync(processId, "PROFILE_ROLL_SAVE\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(recordingPath)), cancellationToken);
    }

    /// <summary>Ends the rolling recording; a recording started with <see cref="StartAsync"/> is left alone.</summary>
    public Task<GameProfileStatus> StopRollingAsync(int processId, CancellationToken cancellationToken = default) =>
        RequestAsync(processId, "PROFILE_ROLL_STOP", cancellationToken);

    public Task<GameProfileStatus> StatusAsync(int processId, CancellationToken cancellationToken = default) =>
        RequestAsync(processId, "PROFILE_STATUS", cancellationToken);

    /// <summary>
    /// Shows a note over the player's head, built in the game from its own catalog: each item a note's key, or
    /// "key:number". False when there is no one to show it to (the main menu, between worlds).
    /// </summary>
    public async Task<bool> NotifyAsync(int processId, string language, IReadOnlyList<string> items,
        CancellationToken cancellationToken = default)
    {
        if (items.Count is < 1 or > 4 || items.Any(item => !NoticeItem().IsMatch(item)))
            throw new ArgumentException("One to four notice items, each a key or key:number.", nameof(items));
        if (!LanguageTag().IsMatch(language)) throw new ArgumentException("A language tag is required.", nameof(language));
        return await RequestDetailAsync(processId, string.Join('\t', ["NOTICE", language, .. items]), cancellationToken) == "queued";
    }

    [System.Text.RegularExpressions.GeneratedRegex("^[a-z][a-z-]{0,39}(:[0-9]{1,6})?$")]
    private static partial System.Text.RegularExpressions.Regex NoticeItem();

    [System.Text.RegularExpressions.GeneratedRegex("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$")]
    private static partial System.Text.RegularExpressions.Regex LanguageTag();

    private async Task<GameProfileStatus> RequestAsync(int processId, string command, CancellationToken cancellationToken) =>
        GameProfileStatus.Parse(await RequestDetailAsync(processId, command, cancellationToken));

    private async Task<string> RequestDetailAsync(int processId, string command, CancellationToken cancellationToken)
    {
        if (processId <= 0) throw new ArgumentOutOfRangeException(nameof(processId));
        if (connectionTimeoutSeconds is < 5 or > 120) throw new ArgumentOutOfRangeException(nameof(connectionTimeoutSeconds));
        var (java, jar) = Locate();
        DiagnosticsProcess? helper = null;
        var listener = new TcpListener(IPAddress.Loopback, 0);
        try
        {
            listener.Start(1);
            var token = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
            var start = new ProcessStartInfo(java) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var argument in new[] { "--add-modules", "jdk.attach", "-jar", jar,
                processId.ToString(CultureInfo.InvariantCulture), jar,
                ((IPEndPoint)listener.LocalEndpoint).Port.ToString(CultureInfo.InvariantCulture), token })
                start.ArgumentList.Add(argument);
            try { helper = DiagnosticsProcess.Start(start); }
            catch (System.ComponentModel.Win32Exception blocked)
            { throw new GameSaveException("attach-failed", "Could not start the attach helper: " + blocked.Message); }
            if (helper is null) throw new GameSaveException("attach-failed", "Could not start the attach helper.");
            var output = helper.StandardOutput.ReadToEndAsync(cancellationToken);
            var error = helper.StandardError.ReadToEndAsync(cancellationToken);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(TimeSpan.FromSeconds(connectionTimeoutSeconds));
            var accepted = listener.AcceptTcpClientAsync(deadline.Token).AsTask();
            var exited = helper.WaitForExitAsync(deadline.Token);
            if (await Task.WhenAny(accepted, exited) == exited)
            {
                await exited;
                if (helper.ExitCode != 0)
                {
                    var detail = (await error + "\n" + await output).Trim();
                    // A save or another short request holds the channel for a moment; the caller may simply try again.
                    // A bootstrap from before an update cannot be used until the game restarts: say so, not "link failed".
                    if (detail.Contains(GameSaveClient.ChannelBusy, StringComparison.Ordinal)) throw new GameSaveException("busy", detail);
                    if (GameSaveException.NamesRestart(detail)) throw new GameSaveException("restart-required", detail);
                    // Otherwise why it could not attach: a known cause under its own code, and what the log needs either way.
                    throw AttachDiagnostics.Failure(processId, detail, helper.ExitCode, bridgeDirectory);
                }
            }
            using var client = await accepted;
            using var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
            using var writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            var hello = await ReadLineAsync(reader, deadline.Token);
            if (hello != $"HELLO\t6\t{processId}\t{token}")
                throw new GameSaveException("unsupported-protocol", "The game is running an older bridge. Restart the game.");
            await writer.WriteLineAsync(command.AsMemory(), deadline.Token);
            var parts = (await ReadLineAsync(reader, deadline.Token))?.Split('\t') ?? [];
            if (parts is ["OK", var detailText]) return Decode(detailText);
            if (parts is ["ERROR", var code, var message])
                // A bridge that predates recording answers every unknown request as a protocol error.
                throw new GameSaveException(code == "protocol" ? "unsupported-protocol" : code, Decode(message));
            throw new GameSaveException("invalid-response", "The game ended the connection without an answer.");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new GameSaveException("connection-timeout", "Could not reach the game.");
        }
        finally
        {
            listener.Stop();
            if (helper is not null)
            {
                try { if (!helper.HasExited) helper.Kill(entireProcessTree: true); }
                catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
                finally { helper.Dispose(); }
            }
        }
    }

    /// <summary>
    /// Converts a finished flight recording, outside the game, with the bundled runtime. With
    /// <paramref name="keepLastSeconds"/>, only that many seconds before its end are kept: a rolling recording's save
    /// holds more than its window. With <paramref name="keepFrom"/> instead, what began from then on: the converter
    /// need not read the file once more to find its end.
    /// </summary>
    public async Task<GameProfileExport> ExportAsync(string recordingPath, string outputPath,
        IReadOnlyDictionary<string, string>? information = null, CancellationToken cancellationToken = default, int keepLastSeconds = 0,
        DateTimeOffset? keepFrom = null)
    {
        if (keepLastSeconds < 0) throw new ArgumentOutOfRangeException(nameof(keepLastSeconds));
        var (java, jar) = Locate();
        if (!File.Exists(recordingPath)) throw new FileNotFoundException("The game did not leave a recording.", recordingPath);
        var start = new ProcessStartInfo(java) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in new[] { "-Xmx512m", "-cp", jar, "pztools.bridge.runtime.ProfileExport", recordingPath, outputPath })
            start.ArgumentList.Add(argument);
        foreach (var (key, value) in information ?? new Dictionary<string, string>())
            start.ArgumentList.Add(key + "=" + value);
        if (keepFrom is { } from) start.ArgumentList.Add("keepFromEpochMillis=" + from.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture));
        else if (keepLastSeconds > 0) start.ArgumentList.Add("keepLastSeconds=" + keepLastSeconds.ToString(CultureInfo.InvariantCulture));
        using var process = DiagnosticsProcess.Start(start) ?? throw new IOException("Could not start the recording converter.");
        try
        {
            var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
            var error = process.StandardError.ReadToEndAsync(cancellationToken);
            await process.WaitForExitAsync(cancellationToken);
            var line = (await output).Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .LastOrDefault(text => text.StartsWith("EXPORTED\t", StringComparison.Ordinal));
            var fields = line?.Split('\t') ?? [];
            if (process.ExitCode != 0 || fields.Length != 5)
                throw new InvalidDataException("The recording could not be converted: " + Truncate((await error).Trim()));
            long Number(int index) => long.Parse(fields[index], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
            return new(Number(1), Number(2), Number(3), Number(4));
        }
        finally
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (Exception exception) when (exception is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
    }

    private (string Java, string Jar) Locate()
    {
        var java = Path.Combine(bridgeDirectory, "runtime", "bin", "java.exe");
        var jar = Path.Combine(bridgeDirectory, "pztools-game-bridge.jar");
        if (!File.Exists(java) || !File.Exists(jar)
            || !File.Exists(Path.Combine(bridgeDirectory, "pztools-game-bootstrap.jar"))
            || !File.Exists(Path.Combine(bridgeDirectory, "pztools-attach-bootstrap.dll")))
            throw new GameSaveException("bridge-not-built", "The game bridge is not included in this build.");
        return (java, jar);
    }

    private static string Truncate(string value) => value.Length <= 600 ? value : value[..600];

    private static string Decode(string value)
    {
        try { return Encoding.UTF8.GetString(Convert.FromBase64String(value)); }
        catch (FormatException) { throw new GameSaveException("invalid-response", "Invalid bridge response encoding."); }
    }

    private static async Task<string?> ReadLineAsync(StreamReader reader, CancellationToken token)
    {
        var value = new StringBuilder();
        var buffer = new char[1];
        while (await reader.ReadAsync(buffer, token) != 0)
        {
            if (buffer[0] == '\n') return value.ToString();
            if (buffer[0] != '\r') value.Append(buffer[0]);
            if (value.Length > 16384) throw new GameSaveException("invalid-response", "Bridge response is too large.");
        }
        return null;
    }
}
