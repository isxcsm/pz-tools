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

    public async Task<string> SaveRunningGameAsync(string expectedSavePath,
        CancellationToken cancellationToken = default) =>
        (await RequestRunningGameAsync(expectedSavePath, true, null, false, cancellationToken)).Detail;

    public Task<GameSaveResponse> PrepareRunningGameAsync(string expectedSavePath, string providerId,
        CancellationToken cancellationToken = default, bool forceVersion = false) =>
        RequestRunningGameAsync(expectedSavePath, true, providerId, forceVersion, cancellationToken);

    public async Task<string> ProbeRunningGameAsync(string expectedSavePath, CancellationToken cancellationToken = default) =>
        (await RequestRunningGameAsync(expectedSavePath, false, null, false, cancellationToken)).Detail;

    private async Task<GameSaveResponse> RequestRunningGameAsync(string expectedSavePath, bool save, string? providerId, bool forceVersion,
        CancellationToken cancellationToken)
    {
        var games = new[] { "ProjectZomboid64", "ProjectZomboid32", "ProjectZomboid" }
            .SelectMany(DiagnosticsProcess.GetProcessesByName).ToArray();
        try
        {
            if (games.Length != 1)
                throw new GameSaveException(games.Length == 0 ? "game-not-running" : "multiple-games",
                    games.Length == 0 ? "Start the game and load the selected save first."
                        : "More than one game process is running. No process was selected.");
            return await RequestCoreAsync(games[0].Id, expectedSavePath, save, providerId, cancellationToken, forceVersion);
        }
        finally { foreach (var game in games) game.Dispose(); }
    }

    // Explicit PID supports a no-save probe and isolated JVM integration tests.
    public async Task<string> RequestAsync(int processId, string expectedSavePath, bool save,
        CancellationToken cancellationToken = default) =>
        (await RequestCoreAsync(processId, expectedSavePath, save, null, cancellationToken)).Detail;

    public Task<GameSaveResponse> RequestProviderAsync(int processId, string expectedSavePath, string providerId,
        CancellationToken cancellationToken = default, bool forceVersion = false) =>
        RequestCoreAsync(processId, expectedSavePath, true, providerId, cancellationToken, forceVersion);

    private async Task<GameSaveResponse> RequestCoreAsync(int processId, string expectedSavePath, bool save,
        string? providerId, CancellationToken cancellationToken, bool forceVersion = false)
    {
        if (providerId is not null && (providerId.Length > 80 || !System.Text.RegularExpressions.Regex.IsMatch(providerId, @"\A[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+\z")))
            throw new ArgumentException("Invalid save provider identifier.", nameof(providerId));
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
            var supportsExtensions = hello == $"HELLO\t6\t{processId}\t{token}";
            // Protocol 5 meant different capabilities on the two former branches.
            if (runtimeTicket is not null && !supportsExtensions)
                throw new GameSaveException("unsupported-protocol", "Restart the game with the integrated runtime bridge.");
            var supportsSchedule = supportsExtensions || hello == $"HELLO\t4\t{processId}\t{token}";
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
            var useProvider = save && providerId is not null && supportsExtensions;
            if (runtimeTicket is not null && preparationAllowed is not null
                && !await PreparationAllowedAsync(completionDeadline.Token))
                throw new GameSaveException("runtime-deferred", "Scheduling permission was withdrawn before submission.");
            var encodedPath = Convert.ToBase64String(Encoding.UTF8.GetBytes(expectedSavePath));
            string command = useProvider
                ? $"{(runtimeTicket is null ? "PREPARE_SAVE" : "PREPARE_SAVE_ACTIVE")}\t{encodedPath}\t{queueTimeoutSeconds}\t{completionTimeoutSeconds}\t{notificationLanguage ?? "off"}\t{(runtimeTicket is null ? (scheduledSaveUtc?.ToUnixTimeMilliseconds() ?? 0).ToString(System.Globalization.CultureInfo.InvariantCulture) : runtimeTicket.Encode())}\t{providerId}\t{(forceVersion ? "force" : "normal")}" 
                : $"{(runtimeTicket is not null ? save ? "SAVE_ACTIVE" : "PROBE_ACTIVE" : timedSave ? "SAVE_AT" : showCountdown ? "SAVE_COUNTDOWN" : save ? "SAVE" : "PROBE")}\t"
                    + encodedPath + (extendedTimeouts ? $"\t{queueTimeoutSeconds}\t{completionTimeoutSeconds}" : "")
                    + (runtimeTicket is not null ? $"\t{(save ? notificationLanguage : null) ?? "off"}\t{runtimeTicket.Encode()}"
                        : timedSave ? $"\t{notificationLanguage ?? "off"}\t{scheduledSaveUtc!.Value.ToUnixTimeMilliseconds()}"
                        : showCountdown ? $"\t{notificationLanguage}" : "");
            await writer.WriteLineAsync(command.AsMemory(), completionDeadline.Token);
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
                var response = ParseResponse(result, useProvider ? providerId : null);
                if (providerId is not null && !supportsExtensions)
                    response = response with { FallbackReason = "unsupported-extension-protocol" };
                if (save && notificationLanguage is not null && !supportsCountdown)
                    response = response with { Detail = response.Detail + "; notice-unavailable=The connected bridge does not support notifications." };
                return response;
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

    private async Task<bool> PreparationAllowedAsync(CancellationToken token)
    {
        try { return await preparationAllowed!(token); }
        catch (OperationCanceledException) { throw; }
        catch (Exception) { return false; }
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

    public static string ParseResult(string? result) => ParseResponse(result).Detail;

    public static GameSaveResponse ParseResponse(string? result, string? requestedProvider = null)
    {
        var parts = result?.Split('\t') ?? [];
        if (parts is ["ERROR", var code, var message]) throw new GameSaveException(code, Decode(message));
        if (parts is ["OK", var success] && requestedProvider is null)
            return new("pztools.standard-save", GameSaveCompletion.StandardCallReturned, Decode(success));
        if (parts is ["SAVED", var provider, var completion, var detail, var fallback]
            && requestedProvider is not null && (provider == requestedProvider || provider == "pztools.standard-save"))
        {
            var kind = completion switch
            {
                "STANDARD_CALL_RETURNED" => GameSaveCompletion.StandardCallReturned,
                "DETACHED_WRITES_COMMITTED" => GameSaveCompletion.DetachedWritesCommitted,
                "GAME_SAVE_AND_DATABASE_QUEUES_DRAINED" => GameSaveCompletion.GameSaveAndDatabaseQueuesDrained,
                "GAME_SAVE_AND_PENDING_WRITES_DRAINED" => GameSaveCompletion.GameSaveAndPendingWritesDrained,
                _ => throw new GameSaveException("invalid-response", "Unknown save completion kind."),
            };
            if ((provider == "pztools.standard-save") != (kind == GameSaveCompletion.StandardCallReturned)
                || (provider == requestedProvider && fallback != "-")
                || (provider == "pztools.standard-save" && string.IsNullOrWhiteSpace(fallback)))
                throw new GameSaveException("invalid-response", "Inconsistent save completion receipt.");
            return new(provider, kind, Decode(detail), fallback == "-" ? null : fallback);
        }
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
