using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Process.Hosting;

/// <summary>In-memory freshness belongs to receipt time, never a persisted UTC timestamp.</summary>
public sealed class RuntimeSnapshotStore(TimeProvider? timeProvider = null)
{
    private sealed record Stamped(RuntimeObservation Observation, long Timestamp);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private Stamped? current;
    public void Publish(RuntimeObservation value) => Volatile.Write(ref current, new(value.Validate(), clock.GetTimestamp()));
    public RuntimeObservation Read()
    {
        var value = Volatile.Read(ref current);
        if (value is null) return RuntimeObservation.Unknown("connecting");
        var elapsed = Math.Max(0, (long)clock.GetElapsedTime(value.Timestamp).TotalMilliseconds);
        var age = Math.Min(long.MaxValue - elapsed, value.Observation.AgeMilliseconds) + elapsed;
        var result = value.Observation with { AgeMilliseconds = age };
        return result.Quality == RuntimeQuality.Fresh && (!result.IsFresh
            || result.Snapshot!.SampleAgeMilliseconds > 2000 - Math.Min(age, 2000))
            ? result with { Quality = RuntimeQuality.Stale, Reason = "stale-game-sample" } : result;
    }
}

/// <summary>Read-only feed. Four bounded listeners, no mutation requests, user/elevation-scoped access.</summary>
public static class RuntimeStateFeed
{
    public static string PipeName(string schedulerPath) => "PzTools.Runtime." + Convert.ToHexString(
        SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(schedulerPath).ToUpperInvariant())))[..24];

    public static Task ServeAsync(string schedulerPath, RuntimeSnapshotStore source, CancellationToken token) =>
        Task.WhenAll(Enumerable.Range(0, 4).Select(_ => ServeOneAsync(PipeName(schedulerPath), source, token)));

    private static async Task ServeOneAsync(string name, RuntimeSnapshotStore source, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            await using var pipe = new NamedPipeServerStream(name, PipeDirection.Out, 4, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 4096, 16384);
            try
            {
                await pipe.WaitForConnectionAsync(token);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
                while (pipe.IsConnected)
                {
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
                    deadline.CancelAfter(TimeSpan.FromSeconds(2));
                    await writer.WriteLineAsync(RuntimeJson.Write(source.Read()).AsMemory(), deadline.Token);
                    await Task.Delay(250, token);
                }
            }
            catch (Exception error) when (error is IOException || error is OperationCanceledException && !token.IsCancellationRequested) { }
        }
    }

    public static async Task FollowAsync(string schedulerPath, RuntimeSnapshotStore target, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeClientStream(".", PipeName(schedulerPath), PipeDirection.In,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.ConnectAsync(1500, token);
                using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
                while (pipe.IsConnected)
                {
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
                    deadline.CancelAfter(TimeSpan.FromSeconds(2));
                    var line = await ReadBoundedAsync(reader, deadline.Token);
                    target.Publish(RuntimeJson.Read<RuntimeObservation>(line).Validate());
                }
            }
            catch (Exception error) when (error is IOException or TimeoutException or InvalidDataException or UnauthorizedAccessException
                or System.Text.Json.JsonException || error is OperationCanceledException && !token.IsCancellationRequested)
            {
                target.Publish(RuntimeObservation.Unknown("runtime-feed-disconnected"));
                await Task.Delay(500, token);
            }
        }
    }

    public static async Task<string> ReadBoundedAsync(StreamReader reader, CancellationToken token)
    {
        var text = new StringBuilder();
        var buffer = new char[1];
        while (await reader.ReadAsync(buffer.AsMemory(), token) != 0)
        {
            if (buffer[0] == '\n') return text.ToString();
            if (buffer[0] != '\r') text.Append(buffer[0]);
            if (text.Length > 65536) throw new InvalidDataException("Oversized runtime frame.");
        }
        throw new EndOfStreamException("Runtime feed ended.");
    }
}