using System.Diagnostics;
using System.Text.Json;

namespace PzTools.Process.Telemetry;

/// <summary>Records operation events in order, and progress as its latest value only, in the background.</summary>
public sealed class ProcessTelemetrySession : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly Queue<PendingEvent> events = new();
    private readonly ProcessTelemetryStore? store;
    private readonly ProcessTelemetrySettings settings;
    private readonly string component;
    private readonly long runIndex;
    private readonly Task worker;
    private readonly FileStream? activity;
    private ProgressSnapshot? latestProgress;
    private bool stopping;
    public TimeSpan HeartbeatInterval => TimeSpan.FromMilliseconds(settings.HeartbeatIntervalMs);

    private ProcessTelemetrySession(ProcessTelemetryStore? store, ProcessTelemetrySettings settings,
        string component, long runIndex, TimeSpan interval, FileStream? activity)
    {
        this.store = store;
        this.activity = activity;
        this.settings = settings;
        this.component = component;
        this.runIndex = Math.Max(1, runIndex);
        worker = store is null ? Task.CompletedTask : Task.Run(() => RunAsync(interval));
    }

    public static async Task<ProcessTelemetrySession> StartAsync(
        string identity, string component, long runIndex,
        string? configurationPath = null, TimeSpan? interval = null)
    {
        var settings = new ProcessTelemetrySettings(true, 100, 64);
        ProcessTelemetryStore? store = null;
        FileStream? activity = null;
        try
        {
            settings = BestEffortProcessTelemetry.LoadSettings(identity, component, configurationPath);
            if (settings.Enabled)
            {
                activity = ProcessTelemetryActivity.Acquire(identity, component);
                store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, component);
            }
        }
        catch (Exception)
        {
            activity?.Dispose();
            activity = null;
            // Failing to store diagnostics does not change whether the operation itself succeeded.
        }
        return new ProcessTelemetrySession(store, settings, component, runIndex,
            interval ?? TimeSpan.FromMilliseconds(settings.ProgressFlushIntervalMs), activity);
    }

    public void RecordEvent(string name, string? payloadJson = null)
    {
        if (store is null) return;
        lock (gate)
        {
            if (stopping) return;
            // The final progress goes before the end event, so 100% does not disappear after the end.
            if (name is "run.committed" or "run.failed" or "run.busy" or "run.cancelled" or "run.unavailable")
                MoveLatestToQueue();
            events.Enqueue(new PendingEvent(name, payloadJson, null,
                DateTimeOffset.UtcNow, Stopwatch.GetTimestamp()));
        }
    }

    public void SetProgress(string phase, long completedItems, long totalItems,
        long completedBytes, long totalBytes, string? relativePath)
    {
        if (store is null) return;
        lock (gate)
        {
            if (stopping) return;
            if (latestProgress is not null && latestProgress.Phase != phase)
                MoveLatestToQueue();
            latestProgress = new ProgressSnapshot(phase, completedItems, totalItems,
                completedBytes, totalBytes, relativePath, DateTimeOffset.UtcNow,
                Stopwatch.GetTimestamp());
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (gate)
        {
            if (!stopping)
            {
                MoveLatestToQueue();
                stopping = true;
            }
        }
        try { await worker; }
        finally { activity?.Dispose(); }
    }

    private void MoveLatestToQueue()
    {
        if (latestProgress is null) return;
        events.Enqueue(new PendingEvent("progress.snapshot", null, latestProgress,
            latestProgress.OccurredUtc, latestProgress.Timestamp));
        latestProgress = null;
    }

    private async Task RunAsync(TimeSpan interval)
    {
        using var timer = new PeriodicTimer(interval);
        var pending = new List<PendingEvent>();
        var failures = 0;
        while (await timer.WaitForNextTickAsync())
        {
            bool done;
            lock (gate)
            {
                MoveLatestToQueue();
                while (events.TryDequeue(out var item))
                {
                    // Retry keeps the latest sample, not one sample per failed flush.
                    // Never cross an event or phase boundary when coalescing.
                    if (item.Progress is { } progress && pending.Count > 0
                        && pending[^1].Progress?.Phase == progress.Phase)
                        pending[^1] = item;
                    else
                        pending.Add(item);
                }
                done = stopping;
            }
            if (pending.Count > 0)
            {
                try
                {
                    var batch = pending.Select(item => new ProcessTelemetryWrite(
                        item.Name,
                        item.Progress is { } progress
                            ? JsonSerializer.Serialize(new
                            {
                                phase = progress.Phase,
                                completedItems = progress.CompletedItems,
                                totalItems = progress.TotalItems,
                                completedBytes = progress.CompletedBytes,
                                totalBytes = progress.TotalBytes,
                                relativePath = progress.RelativePath,
                            })
                            : item.PayloadJson,
                        item.OccurredUtc, item.Timestamp)).ToArray();
                    await store!.WriteBatchAsync(component, runIndex, batch);
                    pending.Clear();
                    failures = 0;
                }
                catch (Exception)
                {
                    // A brief database lock is retried on the next tick. While shutting down, the retries are limited.
                    failures++;
                }
            }
            if (done && (pending.Count == 0 || failures >= 3)) break;
        }
        try { await store!.TrimAsync(component, settings.RetainRuns, settings.MaxDatabaseMib); }
        catch (Exception) { }
    }

    private sealed record PendingEvent(string Name, string? PayloadJson, ProgressSnapshot? Progress,
        DateTimeOffset OccurredUtc, long Timestamp);

    private sealed record ProgressSnapshot(string Phase, long CompletedItems, long TotalItems,
        long CompletedBytes, long TotalBytes, string? RelativePath,
        DateTimeOffset OccurredUtc, long Timestamp);
}
