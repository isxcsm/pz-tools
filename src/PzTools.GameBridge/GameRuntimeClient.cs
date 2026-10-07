using System.Runtime.CompilerServices;
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
        var (client, reader) = await AttachLink.ConnectAsync(bridgeDirectory, processId, "WATCH", "Runtime observer",
            TimeSpan.FromSeconds(20), async (client, secret, deadline) =>
            {
                var reader = new StreamReader(client.GetStream(), Encoding.UTF8);
                if (await ReadLineAsync(reader, deadline) != $"RUNTIME\t1\t{processId}\t{secret}")
                    throw new GameSaveException("authentication-failed", "Unexpected runtime observer identity.");
                // The one thing this stream says to the game, once: which run of the app it is.
                if (appRun is not null)
                    await client.GetStream().WriteAsync(Encoding.ASCII.GetBytes($"LEASE\t{appRun}\n"), deadline);
                return (client, reader);
            }, cancellationToken);
        using (client)
        using (reader)
        {
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
