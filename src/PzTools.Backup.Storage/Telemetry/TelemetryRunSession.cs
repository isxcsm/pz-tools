using System.Diagnostics;
using System.Threading.Channels;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Storage.Telemetry;

public sealed class TelemetryRunSession : IAsyncDisposable
{
    private readonly TelemetryStore? store;
    private readonly TelemetryMode mode;
    private readonly long startedTimestamp;
    private readonly Channel<PendingTelemetryEvent>? channel;
    private readonly Task? pumpTask;
    private long nextSequence;
    private bool completed;

    private TelemetryRunSession(
        TelemetryStore? store,
        long runIndex,
        TelemetryMode mode,
        int batchSize,
        int flushIntervalMilliseconds,
        Exception? failure)
    {
        this.store = store;
        this.mode = mode;
        RunIndex = runIndex;
        Failure = failure;
        startedTimestamp = Stopwatch.GetTimestamp();

        if (store is not null)
        {
            channel = Channel.CreateBounded<PendingTelemetryEvent>(new BoundedChannelOptions(
                Math.Max(batchSize * 2, 16))
            {
                FullMode = BoundedChannelFullMode.Wait,
                SingleReader = true,
                SingleWriter = false,
                AllowSynchronousContinuations = false,
            });
            pumpTask = PumpAsync(batchSize, TimeSpan.FromMilliseconds(flushIntervalMilliseconds));
        }
    }

    public long RunIndex { get; }

    public Exception? Failure { get; private set; }

    public bool IsHealthy => store is not null && Failure is null;

    internal static TelemetryRunSession Create(
        TelemetryStore store,
        long runIndex,
        DateTimeOffset startedUtc,
        TelemetryOptions options)
    {
        _ = startedUtc;
        return new TelemetryRunSession(
            store,
            runIndex,
            options.Mode,
            options.BatchSize,
            options.FlushIntervalMilliseconds,
            failure: null);
    }

    internal static TelemetryRunSession CreateDisabled(
        long runIndex,
        TelemetryMode mode,
        Exception? failure)
    {
        return new TelemetryRunSession(
            store: null,
            runIndex,
            mode,
            batchSize: 1,
            flushIntervalMilliseconds: 1,
            failure);
    }

    public async ValueTask<bool> EmitAsync(
        TelemetryEvent telemetryEvent,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(telemetryEvent);
        if (completed || channel is null || !Includes(telemetryEvent.Scope))
        {
            return false;
        }

        var pending = new PendingTelemetryEvent(
            RunIndex,
            Interlocked.Increment(ref nextSequence),
            telemetryEvent,
            DateTimeOffset.UtcNow,
            Stopwatch.GetElapsedTime(startedTimestamp).Ticks);
        try
        {
            await channel.Writer.WriteAsync(pending, cancellationToken);
            return true;
        }
        catch (ChannelClosedException)
        {
            return false;
        }
    }

    public async Task<bool> CompleteAsync(
        RunStatus status,
        string? failureCode = null,
        CancellationToken cancellationToken = default)
    {
        if (status == RunStatus.Running)
        {
            throw new ArgumentException("A completed run cannot remain Running.", nameof(status));
        }

        if (completed)
        {
            return Failure is null;
        }

        completed = true;
        if (channel is null || pumpTask is null || store is null)
        {
            return Failure is null;
        }

        channel.Writer.TryComplete();
        try
        {
            await pumpTask;
            if (Failure is null)
            {
                await store.CompleteRunAsync(
                    RunIndex,
                    status,
                    failureCode,
                    cancellationToken);
            }
        }
        catch (Exception exception) when (
            exception is SqliteException or IOException or UnauthorizedAccessException)
        {
            Failure ??= exception;
            store.RecordFailure(exception);
        }

        return Failure is null;
    }

    public async ValueTask DisposeAsync()
    {
        if (!completed)
        {
            await CompleteAsync(RunStatus.Abandoned);
        }
    }

    private bool Includes(TelemetryEventScope scope)
    {
        return mode switch
        {
            TelemetryMode.Off => false,
            TelemetryMode.Run => scope == TelemetryEventScope.Run,
            TelemetryMode.Phase => scope is TelemetryEventScope.Run or TelemetryEventScope.Phase,
            TelemetryMode.Raw => true,
            _ => false,
        };
    }

    private async Task PumpAsync(int batchSize, TimeSpan flushInterval)
    {
        var reader = channel!.Reader;
        var batch = new List<PendingTelemetryEvent>(batchSize);
        long batchStarted = 0;
        try
        {
            while (true)
            {
                while (batch.Count < batchSize && reader.TryRead(out var item))
                {
                    if (batch.Count == 0) batchStarted = Stopwatch.GetTimestamp();
                    batch.Add(item);
                }

                if (batch.Count >= batchSize)
                {
                    await FlushAsync(batch);
                    continue;
                }

                if (batch.Count == 0)
                {
                    if (!await reader.WaitToReadAsync())
                    {
                        break;
                    }

                    continue;
                }

                // The window starts with the first item. New arrivals must not postpone
                // a partially filled batch indefinitely while progress keeps changing.
                var remaining = flushInterval - Stopwatch.GetElapsedTime(batchStarted);
                if (remaining <= TimeSpan.Zero)
                {
                    await FlushAsync(batch);
                    continue;
                }
                using var timeout = new CancellationTokenSource(remaining);
                try
                {
                    if (!await reader.WaitToReadAsync(timeout.Token))
                    {
                        break;
                    }
                }
                catch (OperationCanceledException) when (timeout.IsCancellationRequested)
                {
                    await FlushAsync(batch);
                }
            }

            await FlushAsync(batch);
        }
        catch (Exception exception) when (
            exception is SqliteException or IOException or UnauthorizedAccessException)
        {
            Failure = exception;
            store!.RecordFailure(exception);
            channel.Writer.TryComplete(exception);
            while (reader.TryRead(out _))
            {
            }
        }
    }

    private async Task FlushAsync(List<PendingTelemetryEvent> batch)
    {
        if (batch.Count == 0)
        {
            return;
        }

        await store!.WriteBatchAsync(batch, CancellationToken.None);
        batch.Clear();
    }
}
