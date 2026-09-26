using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using DiagnosticsProcess = System.Diagnostics.Process;

namespace PzTools.SaveBridge;

public sealed class GameSaveException(string code, string message) : Exception($"[{code}] {message}")
{
    public string Code { get; } = code;
}

/// <summary>Authenticated, game-thread save requests through the JVM Attach bridge.</summary>
public sealed class GameSaveClient(string bridgeDirectory,
    int connectionTimeoutSeconds = 30, int completionTimeoutSeconds = 150, int queueTimeoutSeconds = 15,
    string? notificationLanguage = null, DateTimeOffset? scheduledSaveUtc = null,
    RuntimeSaveTicket? runtimeTicket = null,
    Func<CancellationToken, Task<bool>>? preparationAllowed = null)
{
    private static readonly SemaphoreSlim RequestGate = new(1, 1);

    public Task<string> SaveRunningGameAsync(string expectedSavePath, CancellationToken cancellationToken = default) =>
        RequestRunningGameAsync(expectedSavePath, true, cancellationToken);
    public Task<string> ProbeRunningGameAsync(string expectedSavePath, CancellationToken cancellationToken = default) =>
        RequestRunningGameAsync(expectedSavePath, false, cancellationToken);
    private async Task<string> RequestRunningGameAsync(string expectedSavePath, bool save, CancellationToken cancellationToken)
    {
        var games = new[] { "ProjectZomboid64", "ProjectZomboid32", "ProjectZomboid" }
            .SelectMany(DiagnosticsProcess.GetProcessesByName).ToArray();
        try
        {
            if (games.Length != 1)
                throw new GameSaveException(games.Length == 0 ? "game-not-running" : "multiple-games",
                    games.Length == 0 ? "Start the game and load the selected save first."
                        : "More than one game process is running. No process was selected.");
            return await RequestAsync(games[0].Id, expectedSavePath, save, cancellationToken);
        }
        finally { foreach (var game in games) game.Dispose(); }
    }

    // Explicit PID supports a no-save probe and isolated JVM integration tests.
    public async Task<string> RequestAsync(int processId, string expectedSavePath, bool save,
        CancellationToken cancellationToken = default)
    {
        runtimeTicket?.Validate();
        if (processId <= 0) throw new ArgumentOutOfRangeException(nameof(processId));
        if (notificationLanguage is not null && !LanguageCatalog.All.Any(language =>
                language.Tag == notificationLanguage) && notificationLanguage is not ("ko" or "en"))
            throw new ArgumentOutOfRangeException(nameof(notificationLanguage));
        if (save && scheduledSaveUtc > DateTimeOffset.UtcNow.AddMinutes(1))
            throw new ArgumentOutOfRangeException(nameof(scheduledSaveUtc), "Scheduled saves must be due within one minute.");
        if (connectionTimeoutSeconds is < 5 or > 120 || completionTimeoutSeconds is < 30 or > 600)
            throw new ArgumentOutOfRangeException(nameof(connectionTimeoutSeconds));
        if (queueTimeoutSeconds is < 1 or > 60 || completionTimeoutSeconds < queueTimeoutSeconds + 20)
            throw new ArgumentOutOfRangeException(nameof(queueTimeoutSeconds));
        if (!Path.IsPathFullyQualified(expectedSavePath) || !Directory.Exists(expectedSavePath))
            throw new GameSaveException("missing-save", "The selected save folder does not exist.");
        if (!await RequestGate.WaitAsync(0, cancellationToken))
            throw new GameSaveException("busy", "A game save request is already running.");
        DiagnosticsProcess? helper = null;
        var listener = new TcpListener(IPAddress.Loopback, 0);
        var sent = false;
        try
        {
            var java = Path.Combine(bridgeDirectory, "runtime", "bin", "java.exe");
            var jar = Path.Combine(bridgeDirectory, "pztools-save-bridge.jar");
            if (!File.Exists(java) || !File.Exists(jar)
                || !File.Exists(Path.Combine(bridgeDirectory, "pztools-save-bootstrap.jar"))
                || !File.Exists(Path.Combine(bridgeDirectory, "pztools-attach-bootstrap.dll")))
                throw new GameSaveException("bridge-not-built", "The game save bridge is not included in this build.");
            listener.Start(1);
            var token = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
            var start = new ProcessStartInfo(java)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var argument in new[] { "--add-modules", "jdk.attach", "-jar", jar,
                processId.ToString(System.Globalization.CultureInfo.InvariantCulture), jar,
                ((IPEndPoint)listener.LocalEndpoint).Port.ToString(System.Globalization.CultureInfo.InvariantCulture), token })
                start.ArgumentList.Add(argument);
            helper = DiagnosticsProcess.Start(start) ?? throw new IOException("Could not start the attach helper.");
            var output = helper.StandardOutput.ReadToEndAsync(cancellationToken);
            var error = helper.StandardError.ReadToEndAsync(cancellationToken);
            using var connectionDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connectionDeadline.CancelAfter(TimeSpan.FromSeconds(connectionTimeoutSeconds));
            var accepted = listener.AcceptTcpClientAsync(connectionDeadline.Token).AsTask();
            var exited = helper.WaitForExitAsync(connectionDeadline.Token);
            if (await Task.WhenAny(accepted, exited) == exited)
            {
                await exited;
                if (helper.ExitCode != 0)
                    throw new GameSaveException("attach-failed", (await error + "\n" + await output).Trim());
            }
            using var client = await accepted;
            using var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
            using var writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            var hello = await ReadLineAsync(reader, connectionDeadline.Token);
            var supportsGuard = hello == $"HELLO\t5\t{processId}\t{token}";
            if (runtimeTicket is not null && !supportsGuard) throw new GameSaveException("unsupported-protocol", "Restart the game with the current runtime bridge.");
            var supportsSchedule = supportsGuard || hello == $"HELLO\t4\t{processId}\t{token}";
            var supportsCountdown = supportsSchedule || hello == $"HELLO\t3\t{processId}\t{token}";
            var extendedTimeouts = supportsCountdown || hello == $"HELLO\t2\t{processId}\t{token}";
            if (!extendedTimeouts && hello != $"HELLO\t1\t{processId}\t{token}")
                throw new GameSaveException("authentication-failed", "Unexpected bridge session or process.");
            if (!extendedTimeouts && (queueTimeoutSeconds != 15 || completionTimeoutSeconds != 150))
                throw new GameSaveException("unsupported-protocol", "The bridge does not support configured timeouts. No save command was sent.");
            if (save && scheduledSaveUtc is not null && !supportsSchedule)
                throw new GameSaveException("unsupported-protocol", "The bridge does not support scheduled saves. No save command was sent.");
            using var completionDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var scheduledWait = save && scheduledSaveUtc is { } due && due > DateTimeOffset.UtcNow
                ? due - DateTimeOffset.UtcNow : TimeSpan.Zero;
            // Preparation lead is not time spent waiting for the save call to return.
            completionDeadline.CancelAfter(TimeSpan.FromSeconds(completionTimeoutSeconds) + scheduledWait);
            var showCountdown = save && notificationLanguage is not null && supportsCountdown;
            var timedSave = save && scheduledSaveUtc is not null;
            await writer.WriteLineAsync(($"{(runtimeTicket is not null ? save ? "SAVE_ACTIVE" : "PROBE_ACTIVE" : timedSave ? "SAVE_AT" : showCountdown ? "SAVE_COUNTDOWN" : save ? "SAVE" : "PROBE")}\t"
                + Convert.ToBase64String(Encoding.UTF8.GetBytes(expectedSavePath))
                + (extendedTimeouts ? $"\t{queueTimeoutSeconds}\t{completionTimeoutSeconds}" : "")
                + (runtimeTicket is not null ? $"\t{(save ? notificationLanguage : null) ?? "off"}\t{runtimeTicket.Encode()}"
                    : timedSave ? $"\t{notificationLanguage ?? "off"}\t{scheduledSaveUtc!.Value.ToUnixTimeMilliseconds()}"
                    : showCountdown ? $"\t{notificationLanguage}" : "")).AsMemory(), completionDeadline.Token);
            sent = true;
            using var permissionCancellation = CancellationTokenSource.CreateLinkedTokenSource(completionDeadline.Token);
            int saving = 0;
            var permission = runtimeTicket is null || preparationAllowed is null ? Task.CompletedTask
                : MonitorPermissionAsync(writer, runtimeTicket.RequestId, () => Volatile.Read(ref saving) != 0, permissionCancellation.Token);
            try
            {
                var result = await ReadLineAsync(reader, completionDeadline.Token);
                while (result is "RUNNING" or "SAVING")
                {
                    if (result == "SAVING") Interlocked.Exchange(ref saving, 1);
                    result = await ReadLineAsync(reader, completionDeadline.Token);
                }
                var detail = ParseResult(result);
                return save && notificationLanguage is not null && !supportsCountdown
                    ? detail + "; notice-unavailable=The connected bridge does not support notifications." : detail;
            }
            finally
            {
                await permissionCancellation.CancelAsync();
                try { await permission; } catch (OperationCanceledException) { }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new GameSaveException(sent ? "completion-unknown" : "connection-timeout",
                sent ? "No completion response. The game may still be saving; do not assume success or retry immediately."
                    : "Could not connect to the game. No save command was sent.");
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
            RequestGate.Release();
        }
    }

    private async Task MonitorPermissionAsync(StreamWriter writer, string requestId, Func<bool> hasStarted, CancellationToken token)
    {
        while (!hasStarted())
        {
            bool allowed;
            try { allowed = await preparationAllowed!(token); }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { allowed = false; } // Missing authority is never permission to begin saving.
            if (hasStarted()) return;
            if (!allowed)
            {
                try { await writer.WriteLineAsync(("CANCEL\t" + requestId).AsMemory(), token); }
                catch (IOException) { } // The response reader still decides whether completion is known.
                return;
            }
            await Task.Delay(100, token);
        }
    }

    public static string ParseResult(string? result)
    {
        var parts = result?.Split('\t') ?? [];
        if (parts is ["OK", var success]) return Decode(success);
        if (parts is ["ERROR", var code, var detail]) throw new GameSaveException(code, Decode(detail));
        throw new GameSaveException("invalid-response", "Game connection ended without a valid result; completion is unknown.");
    }

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
