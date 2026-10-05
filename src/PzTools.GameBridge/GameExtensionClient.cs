using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.GameBridge;

/// <summary>One module on a shared lease. Disposing it does nothing: the lease belongs to the client.</summary>
public sealed class GameExtensionModule : IGameExtensionSession
{
    private readonly GameExtensionClient client;
    internal GameExtensionModule(GameExtensionClient client, string moduleId) { this.client = client; ModuleId = moduleId; }
    public string ModuleId { get; }
    public Task<RuntimeExtensionStatus> StatusAsync(CancellationToken token) => client.ModuleCommandAsync("STATUS", ModuleId, token);
    public Task<RuntimeExtensionStatus> PingAsync(CancellationToken token) => client.ModuleCommandAsync("PING", ModuleId, token);
    /// <summary>Retires this module only; the others keep running on the same lease.</summary>
    public Task<RuntimeExtensionStatus> DisableAsync(CancellationToken token) => client.ModuleCommandAsync("OFF", ModuleId, token);
    public Task<RuntimeExtensionStatus> ApplyAsync(string processSession, string worldSession,
        long expectedRevision, long revision, string moduleId, bool forceVersion,
        IReadOnlyDictionary<string, string> configuration, CancellationToken token) =>
        moduleId == ModuleId
            ? client.ApplyAsync(processSession, worldSession, expectedRevision, revision, moduleId, forceVersion, configuration, token)
            : throw new ArgumentException("This session addresses another module.", nameof(moduleId));
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

/// <summary>
/// Independent continuous-extension lease; never occupies the save request gate. The lease is one
/// connection for every continuous module. Its own status and OFF are about the host as a whole
/// (OFF retires every module); <see cref="Module"/> addresses one.
/// </summary>
public sealed class GameExtensionClient : IGameExtensionSession
{
    private readonly TcpClient client;
    private readonly StreamReader reader;
    private readonly StreamWriter writer;
    private readonly SemaphoreSlim requests = new(1, 1);
    private readonly string epoch = Guid.NewGuid().ToString("N");
    private int disposed;
    private readonly object disposalGate = new();
    private Task? disposal;

    private GameExtensionClient(TcpClient client)
    {
        this.client = client;
        reader = new(client.GetStream(), new UTF8Encoding(false, true), leaveOpen: true);
        writer = new(client.GetStream(), new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true, NewLine = "\n" };
    }

    public static Task<GameExtensionClient> ConnectAsync(string bridgeDirectory, int processId, CancellationToken token) =>
        ConnectAsync(bridgeDirectory, processId, TimeSpan.FromSeconds(20), token);

    public static async Task<GameExtensionClient> ConnectAsync(string bridgeDirectory, int processId,
        TimeSpan connectTimeout, CancellationToken token)
    {
        if (processId <= 0) throw new ArgumentOutOfRangeException(nameof(processId));
        if (connectTimeout < TimeSpan.FromSeconds(5) || connectTimeout > TimeSpan.FromSeconds(60))
            throw new ArgumentOutOfRangeException(nameof(connectTimeout), "Extension connection timeout must be between 5 and 60 seconds.");
        var java = Path.Combine(bridgeDirectory, "runtime", "bin", "java.exe");
        var jar = Path.Combine(bridgeDirectory, "pztools-game-bridge.jar");
        if (!File.Exists(java) || !File.Exists(jar))
            throw new GameSaveException("bridge-not-built", "Continuous extensions are not included in this build.");
        var listener = new TcpListener(IPAddress.Loopback, 0);
        System.Diagnostics.Process? helper = null;
        GameExtensionClient? session = null;
        Task<string>? output = null, error = null;
        try
        {
            listener.Start(1);
            var secret = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
            var start = new ProcessStartInfo(java) { UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var value in new[] { "--add-modules", "jdk.attach", "-jar", jar,
                processId.ToString(CultureInfo.InvariantCulture), jar,
                ((IPEndPoint)listener.LocalEndpoint).Port.ToString(CultureInfo.InvariantCulture), secret, "EXTENSIONS" })
                start.ArgumentList.Add(value);
            // The game's own account may read what the helper hands it (a copy, from a folder of plain letters).
            AttachDiagnostics.PassGameAccount(start, processId);
            helper = System.Diagnostics.Process.Start(start) ?? throw new IOException("Cannot start extension helper.");
            output = helper.StandardOutput.ReadToEndAsync(); error = helper.StandardError.ReadToEndAsync();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            deadline.CancelAfter(connectTimeout);
            var accept = listener.AcceptTcpClientAsync(deadline.Token).AsTask();
            var exit = helper.WaitForExitAsync(deadline.Token);
            if (await Task.WhenAny(accept, exit) == exit)
            {
                await exit;
                if (helper.ExitCode != 0)
                {
                    var detail = (await error + "\n" + await output).Trim();
                    // A bootstrap from before this app's update: one restart of the game is the answer, as the state
                    // stream already reports it (GameRuntimeClient), not a failure of the extension.
                    if (GameSaveException.NamesRestart(detail))
                        throw new GameSaveException("restart-required", "The loaded bootstrap requires one game restart after this bridge update.");
                    throw new GameSaveException("runtime-unavailable", "Continuous extension attach failed.",
                        AttachDiagnostics.Describe(processId, detail, helper.ExitCode, bridgeDirectory));
                }
            }
            session = new(await accept);
            if (await ReadLineAsync(session.reader, deadline.Token) != $"EXTENSIONS\t1\t{processId}\t{secret}")
                throw new GameSaveException("authentication-failed", "Unexpected extension controller identity.");
            return session;
        }
        catch
        {
            if (session is not null) await session.DisposeAsync();
            throw;
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

    public Task<RuntimeExtensionStatus> StatusAsync(CancellationToken token) => CommandAsync("STATUS", null, token);
    public Task<RuntimeExtensionStatus> PingAsync(CancellationToken token) => CommandAsync("PING", null, token);
    public Task<RuntimeExtensionStatus> DisableAsync(CancellationToken token) => CommandAsync("OFF", null, token);

    public GameExtensionModule Module(string moduleId)
    {
        ValidateModule(moduleId);
        return new(this, moduleId);
    }
    internal Task<RuntimeExtensionStatus> ModuleCommandAsync(string verb, string moduleId, CancellationToken token) =>
        CommandAsync(verb, moduleId, token);
    private static void ValidateModule(string moduleId)
    {
        if (string.IsNullOrWhiteSpace(moduleId) || moduleId.Length > 80
            || moduleId.Any(c => !char.IsAsciiLetterLower(c) && !char.IsAsciiDigit(c) && c is not '.' and not '-'))
            throw new ArgumentException("Invalid extension identity.", nameof(moduleId));
    }

    public Task<RuntimeExtensionStatus> ApplyAsync(string processSession, string worldSession,
        long expectedRevision, long revision, string moduleId, bool forceVersion,
        IReadOnlyDictionary<string, string> configuration, CancellationToken token)
    {
        if (processSession.Length != 32 || !Guid.TryParseExact(processSession, "N", out _)
            || worldSession.Length != 32 || !Guid.TryParseExact(worldSession, "N", out _)
            || expectedRevision < -1 || revision < 0 || string.IsNullOrWhiteSpace(moduleId)
            || moduleId.Length > 80 || moduleId.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not '.' and not '-'))
            throw new ArgumentException("Invalid extension identity or revision.");
        var text = new StringBuilder();
        foreach (var (key, value) in configuration.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (string.IsNullOrEmpty(key) || key.Length > 80 || key.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not '.' and not '_' and not '-')
                || value.Any(char.IsControl)) throw new ArgumentException("Invalid extension configuration field.");
            text.Append(key).Append('\t').Append(value).Append('\n');
        }
        var bytes = Encoding.UTF8.GetBytes(text.ToString());
        if (bytes.Length > 65536) throw new ArgumentException("Oversized extension configuration.");
        var suffix = string.Join('\t', processSession, worldSession, expectedRevision.ToString(CultureInfo.InvariantCulture),
            revision.ToString(CultureInfo.InvariantCulture), moduleId, forceVersion ? "force" : "normal", Convert.ToBase64String(bytes));
        return CommandAsync("APPLY", suffix, token);
    }

    private async Task<RuntimeExtensionStatus> CommandAsync(string verb, string? suffix, CancellationToken token)
    {
        await requests.WaitAsync(token);
        try
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
            var command = Guid.NewGuid().ToString("N");
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            // Applying or retiring a module can rightly take longer than a status check: the game waits
            // up to 5 seconds for running callbacks to finish, then retransforms classes. An unanswered
            // command ends the lease, which switches the extension off, so it must not come too soon.
            deadline.CancelAfter(TimeSpan.FromSeconds(verb is "APPLY" or "OFF" ? 15 : 3));
            await writer.WriteLineAsync(($"{verb}\t{command}\t{epoch}" + (suffix is null ? "" : "\t" + suffix)).AsMemory(), deadline.Token);
            return RuntimeExtensionStatus.ParseWire(await ReadLineAsync(reader, deadline.Token), command);
        }
        catch
        {
            // A cancelled/partial reply cannot be reused as the next command's response. EOF also revokes the remote lease.
            CloseTransport();
            throw;
        }
        finally { requests.Release(); }
    }

    private static async Task<string> ReadLineAsync(StreamReader reader, CancellationToken token)
    {
        var value = new StringBuilder(); var buffer = new char[1];
        while (await reader.ReadAsync(buffer.AsMemory(), token) != 0)
        {
            if (buffer[0] == '\n') return value.ToString();
            if (buffer[0] != '\r') value.Append(buffer[0]);
            if (value.Length > 16384) throw new InvalidDataException("Oversized extension response.");
        }
        throw new EndOfStreamException("Extension controller disconnected.");
    }

    public ValueTask DisposeAsync()
    {
        // Closing the socket revokes the remote capability before waiting for local I/O cleanup.
        CloseTransport();
        lock (disposalGate) return new(disposal ??= DisposeStreamsAsync());
    }

    private void CloseTransport()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0) client.Dispose();
    }

    private async Task DisposeStreamsAsync()
    {
        await requests.WaitAsync();
        try
        {
            try { writer.Dispose(); } catch (Exception failure) when (failure is IOException or ObjectDisposedException) { }
            try { reader.Dispose(); } catch (Exception failure) when (failure is IOException or ObjectDisposedException) { }
        }
        finally { requests.Release(); }
    }
}
