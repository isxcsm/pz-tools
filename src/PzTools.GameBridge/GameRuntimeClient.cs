using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.GameBridge;

/// <summary>Owns a read-only stream, never takes GameSaveClient's request gate.</summary>
public sealed class GameRuntimeClient(string bridgeDirectory)
{
    /// <summary>An app run's name for the game: 32 lowercase hex digits.</summary>
    public static bool IsAppRun(string value) =>
        value.Length == 32 && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    public IAsyncEnumerable<RuntimeSnapshot> WatchAsync(int processId, CancellationToken cancellationToken = default) =>
        WatchAsync(processId, null, cancellationToken);

    /// <param name="appRun">The app run this stream speaks for: the game renews its lease while the stream is open, and
    /// what the run asked of the game lasts as long (the game bridge's Leases).</param>
    public async IAsyncEnumerable<RuntimeSnapshot> WatchAsync(int processId, string? appRun,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (appRun is not null && !IsAppRun(appRun)) throw new ArgumentException("Not an app run.", nameof(appRun));
        if (processId <= 0) throw new ArgumentOutOfRangeException(nameof(processId));
        var java = Path.Combine(bridgeDirectory, "runtime", "bin", "java.exe");
        var jar = Path.Combine(bridgeDirectory, "pztools-game-bridge.jar");
        if (!File.Exists(java) || !File.Exists(jar)) throw new GameSaveException("bridge-not-built", "Runtime observer is not included in this build.");
        var listener = new TcpListener(IPAddress.Loopback, 0);
        System.Diagnostics.Process? helper = null;
        Task<string>? output = null, error = null;
        try
        {
            listener.Start(1);
            var secret = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
            var start = new ProcessStartInfo(java) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var value in new[] { "--add-modules", "jdk.attach", "-jar", jar,
                processId.ToString(System.Globalization.CultureInfo.InvariantCulture), jar,
                ((IPEndPoint)listener.LocalEndpoint).Port.ToString(System.Globalization.CultureInfo.InvariantCulture), secret, "WATCH" })
                start.ArgumentList.Add(value);
            helper = System.Diagnostics.Process.Start(start) ?? throw new IOException("Cannot start runtime observer helper.");
            output = helper.StandardOutput.ReadToEndAsync(); error = helper.StandardError.ReadToEndAsync();
            using var connection = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connection.CancelAfter(TimeSpan.FromSeconds(20));
            var accept = listener.AcceptTcpClientAsync(connection.Token).AsTask();
            var exit = helper.WaitForExitAsync(connection.Token);
            if (await Task.WhenAny(accept, exit) == exit)
            {
                await exit;
                if (helper.ExitCode != 0)
                {
                    var detail = (await error + "\n" + await output).Trim();
                    if (GameSaveException.NamesRestart(detail))
                        throw new GameSaveException("restart-required", "The loaded bootstrap requires one game restart after this bridge update.");
                    // A known cause keeps its own code, for the card to name; any other stays this link's own failure.
                    var failure = AttachDiagnostics.Failure(processId, detail, helper.ExitCode, bridgeDirectory);
                    throw failure.Code == "attach-failed"
                        ? new GameSaveException("runtime-unavailable", "Runtime observer attach failed.", failure.Diagnostics) : failure;
                }
            }
            using var client = await accept;
            using var reader = new StreamReader(client.GetStream(), Encoding.UTF8);
            if (await ReadLineAsync(reader, connection.Token) != $"RUNTIME\t1\t{processId}\t{secret}")
                throw new GameSaveException("authentication-failed", "Unexpected runtime observer identity.");
            // The one thing this stream says to the game, once: which run of the app it is.
            if (appRun is not null)
                await client.GetStream().WriteAsync(Encoding.ASCII.GetBytes($"LEASE\t{appRun}\n"), connection.Token);
            RuntimeSnapshot? previous = null;
            while (true)
            {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                deadline.CancelAfter(TimeSpan.FromSeconds(2));
                var line = await ReadLineAsync(reader, deadline.Token);
                if (line.StartsWith("ERROR", StringComparison.Ordinal)) throw new GameSaveException("runtime-unavailable", "Runtime observer is unavailable.");
                var snapshot = RuntimeSnapshot.ParseWire(line);
                if (previous is not null && (snapshot.ProcessSession != previous.ProcessSession
                    || snapshot.ObserverEpoch != previous.ObserverEpoch || snapshot.Sequence < previous.Sequence))
                    throw new InvalidDataException("Runtime stream identity/sequence changed without reconnecting.");
                if (previous is not null && snapshot.Sequence == previous.Sequence
                    && (snapshot with { SampleAgeMilliseconds = previous.SampleAgeMilliseconds }) != previous)
                    throw new InvalidDataException("A repeated runtime sequence changed its content.");
                if (previous is not null && snapshot.WorldSession == previous.WorldSession && snapshot.ClockEpoch == previous.ClockEpoch
                    && snapshot.ActiveMilliseconds < previous.ActiveMilliseconds)
                    throw new InvalidDataException("Runtime active time moved backwards.");
                previous = snapshot;
                yield return snapshot;
            }
        }
        finally
        {
            listener.Stop();
            if (helper is not null)
            {
                try { if (!helper.HasExited) helper.Kill(entireProcessTree: true); await helper.WaitForExitAsync(CancellationToken.None); }
                catch (Exception failure) when (failure is InvalidOperationException or System.ComponentModel.Win32Exception) { }
                helper.Dispose();
                if (output is not null) await output;
                if (error is not null) await error;
            }
        }
    }

    private static async Task<string> ReadLineAsync(StreamReader reader, CancellationToken token)
    {
        var value = new StringBuilder(); var buffer = new char[1];
        while (await reader.ReadAsync(buffer.AsMemory(), token) != 0)
        {
            if (buffer[0] == '\n') return value.ToString();
            if (buffer[0] != '\r') value.Append(buffer[0]);
            if (value.Length > 65536) throw new InvalidDataException("Oversized runtime frame.");
        }
        throw new EndOfStreamException("Runtime observer disconnected.");
    }
}
