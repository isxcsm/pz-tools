using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace PzTools.GameBridge;

/// <summary>
/// The attach helper started for a link the game opens back to this app and keeps open: the runtime stream
/// (<c>WATCH</c>, <see cref="GameRuntimeClient"/>) and the extension lease (<c>EXTENSIONS</c>,
/// <see cref="GameExtensionClient"/>). One launch for both, so that they find the bridge, wait and fail alike.
/// </summary>
internal static class AttachLink
{
    /// <summary>
    /// Starts the helper, waits for the game's connection and hands it to <paramref name="greet"/>, which reads the
    /// game's first line (naming the process and the secret) within the same deadline. The helper is gone when this
    /// returns; the connection is disposed when <paramref name="greet"/> fails.
    /// </summary>
    /// <param name="mode">What the game opens: <c>WATCH</c> or <c>EXTENSIONS</c>.</param>
    /// <param name="link">The link's name in a failure: "{link} attach failed.".</param>
    /// <exception cref="GameSaveException"><c>bridge-not-built</c>; <c>busy</c> for a moment; <c>restart-required</c>
    /// after a bridge update; a known cause under its own code (<see cref="AttachDiagnostics.DisabledCode"/>);
    /// <c>runtime-unavailable</c> for any other failed attach.</exception>
    public static async Task<T> ConnectAsync<T>(string bridgeDirectory, int processId, string mode, string link,
        TimeSpan timeout, Func<TcpClient, string, CancellationToken, Task<T>> greet, CancellationToken token)
    {
        var java = Path.Combine(bridgeDirectory, "runtime", "bin", "java.exe");
        var jar = Path.Combine(bridgeDirectory, "pztools-game-bridge.jar");
        if (!File.Exists(java) || !File.Exists(jar))
            throw new GameSaveException("bridge-not-built", $"{link} is not included in this build.");
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
                processId.ToString(CultureInfo.InvariantCulture), jar,
                ((IPEndPoint)listener.LocalEndpoint).Port.ToString(CultureInfo.InvariantCulture), secret, mode })
                start.ArgumentList.Add(value);
            // The game's own account may read what the helper hands it (a copy, from a folder of plain letters).
            AttachDiagnostics.PassGameAccount(start, processId);
            // A helper the system will not start (blocked by a security product) is this link failing, as any refused attach.
            try { helper = System.Diagnostics.Process.Start(start); }
            catch (System.ComponentModel.Win32Exception blocked)
            { throw new GameSaveException("runtime-unavailable", $"{link} attach failed: {blocked.Message}"); }
            if (helper is null) throw new GameSaveException("runtime-unavailable", $"{link} attach failed: the helper did not start.");
            output = helper.StandardOutput.ReadToEndAsync(); error = helper.StandardError.ReadToEndAsync();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            deadline.CancelAfter(timeout);
            var accept = listener.AcceptTcpClientAsync(deadline.Token).AsTask();
            var exit = helper.WaitForExitAsync(deadline.Token);
            if (await Task.WhenAny(accept, exit) == exit)
            {
                await exit;
                if (helper.ExitCode != 0)
                    throw Failure(link, processId, (await error + "\n" + await output).Trim(), helper.ExitCode, bridgeDirectory);
            }
            var client = await accept;
            try { return await greet(client, secret, deadline.Token); }
            catch
            {
                client.Dispose();
                throw;
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

    /// <summary>Why the helper ended without the game connecting, from what it printed.</summary>
    internal static GameSaveException Failure(string link, int processId, string detail, int exitCode, string bridgeDirectory)
    {
        // A bootstrap from before this app's update: one restart of the game is the answer, as the state stream reports
        // it, not a failed link.
        if (GameSaveException.NamesRestart(detail))
            return new("restart-required", "The loaded bootstrap requires one game restart after this bridge update.");
        // Busy with another request for a moment (a payload being reloaded): tried again as any outage is, and no
        // failure for the log, whose one entry per game would then hide a real one.
        if (detail.Contains(GameSaveClient.ChannelBusy, StringComparison.Ordinal))
            return new("busy", "The game was busy with another request.");
        // A known cause keeps its own code, for the card to name; any other stays this link's own failure.
        var failure = AttachDiagnostics.Failure(processId, detail, exitCode, bridgeDirectory);
        return failure.Code == "attach-failed" ? new("runtime-unavailable", $"{link} attach failed.", failure.Diagnostics) : failure;
    }
}
