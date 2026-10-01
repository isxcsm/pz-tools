using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts;

namespace PzTools.Projections;

public enum TelemetryDatabaseKind { Backup, Process }
public enum TelemetryHealth { Waiting, Healthy, Stale, Disabled, Unreadable, UnsupportedSchema }
public enum OperationStatus { Waiting, Running, Succeeded, NoChange, Failed, Cancelled, Busy, Degraded }
public enum LogLevel { Trace, Information, Warning, Error, Critical }

public sealed record LogProjectionOptions(
    LogLevel MinimumLevel = LogLevel.Warning,
    int DisplayLimit = 1000)
{
    public LogProjectionOptions Validate()
    {
        if (DisplayLimit is < 100 or > 10000)
            throw new ArgumentOutOfRangeException(nameof(DisplayLimit));
        return this;
    }
}

public sealed record LogEntryView(
    string EntryId,
    string SourceId,
    Guid TelemetryInstanceId,
    long EventId,
    DateTimeOffset OccurredUtc,
    LogLevel Level,
    string Component,
    long RunIndex,
    string EventName,
    string? PayloadJson,
    long LogIndex = 0,
    string? IncidentKey = null,
    bool IsAcknowledged = true);

public sealed record LogsView(IReadOnlyList<LogEntryView> Entries, int UnreadIssues = 0);

public sealed record WorkflowOperation(
    string OperationId,
    string Kind,
    long RunIndex,
    OperationStatus Status,
    DateTimeOffset StartedUtc,
    DateTimeOffset? CompletedUtc = null);

public sealed record TelemetrySourceRegistration(
    string SourceId,
    string Component,
    string Identity,
    string DatabasePath,
    TelemetryDatabaseKind DatabaseKind,
    bool Enabled,
    WorkflowOperation? CurrentWorkflow = null,
    bool Transient = false,
    bool LogsOnly = false);

public sealed record TelemetrySourceView(
    string SourceId,
    string Component,
    string Identity,
    Guid? InstanceId,
    TelemetryHealth Health,
    DateTimeOffset? LastEventUtc,
    string? Message)
{
    public string? ErrorPayloadJson { get; init; }
}

public sealed record OperationView(
    string SourceId,
    string OperationId,
    string Kind,
    string Producer,
    long RunIndex,
    OperationStatus Status,
    string? Phase,
    long CompletedItems,
    long? TotalItems,
    long CompletedBytes,
    long? TotalBytes,
    TelemetryHealth TelemetryHealth,
    string? Message,
    DateTimeOffset? CompletedUtc);

public sealed record OperationsView(IReadOnlyList<OperationView> Operations);

/// <summary>How long a finished operation stays on screen: the same rule for the projection and the app.</summary>
public static class OperationCardLifetime
{
    public static TimeSpan Of(OperationStatus status, bool maintenance, TimeSpan success, TimeSpan failure) =>
        // Postponed cleanup is not a failure to dwell on.
        status is OperationStatus.Succeeded or OperationStatus.NoChange
            || maintenance && status == OperationStatus.Cancelled ? success : failure;

    public static bool IsExpired(OperationStatus status, DateTimeOffset? completedUtc, DateTimeOffset now,
        bool maintenance, TimeSpan success, TimeSpan failure)
    {
        if (status is OperationStatus.Running or OperationStatus.Waiting) return false;
        if (completedUtc is null) return true;
        return now - completedUtc.Value > Of(status, maintenance, success, failure);
    }
}

public sealed record ProducerMetricsView(
    string Producer,
    int RunCount,
    int SuccessCount,
    int FailureCount,
    long BytesProcessed,
    double? BytesPerSecond,
    IReadOnlyDictionary<string, TimeSpan> PhaseDurations);

public sealed record MetricsView(IReadOnlyList<ProducerMetricsView> Producers);
public sealed record TelemetrySourcesView(IReadOnlyList<TelemetrySourceView> Sources);

public sealed class TelemetrySourceCatalog
{
    private readonly ConcurrentDictionary<string, TelemetrySourceRegistration> sources =
        new(StringComparer.OrdinalIgnoreCase);

    public void Register(TelemetrySourceRegistration source)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentException.ThrowIfNullOrWhiteSpace(source.SourceId);
        sources[source.SourceId] = source with
        {
            DatabasePath = Path.GetFullPath(source.DatabasePath),
        };
    }

    public bool Remove(string sourceId) => sources.TryRemove(sourceId, out _);

    public void SetWorkflow(string sourceId, WorkflowOperation? workflow)
    {
        while (sources.TryGetValue(sourceId, out var current))
        {
            if (sources.TryUpdate(sourceId, current with { CurrentWorkflow = workflow }, current))
                return;
        }
        throw new KeyNotFoundException($"Telemetry source '{sourceId}' is not registered.");
    }

    public IReadOnlyList<TelemetrySourceRegistration> Snapshot() =>
        sources.Values.OrderBy(item => item.SourceId, StringComparer.OrdinalIgnoreCase).ToArray();
}

public sealed class TelemetryProjectionHost(
    TelemetrySourceCatalog catalog,
    RevisionedViewStore views,
    TimeSpan? heartbeatTimeout = null,
    int maximumPagesPerProjection = 64,
    LogInboxStore? logInbox = null,
    TimeSpan? initialReadGrace = null,
    TimeSpan? successCardLifetime = null,
    TimeSpan? failureCardLifetime = null,
    Func<TelemetrySourceRegistration, bool>? retireSource = null,
    int readTimeoutSeconds = 1)
{
    private readonly TimeSpan InitialDatabaseReadGrace = initialReadGrace ?? TimeSpan.FromSeconds(2);
    private readonly int maximumPagesPerProjection = maximumPagesPerProjection > 0
        ? maximumPagesPerProjection
        : throw new ArgumentOutOfRangeException(nameof(maximumPagesPerProjection));
    private readonly TimeSpan staleAfter = heartbeatTimeout ?? TimeSpan.FromSeconds(10);
    // In memory only, on purpose: each app start replays what the sources retain, because that replay
    // rebuilds the operation cards and run metrics. Retention bounds it (runs and size per source).
    private readonly Dictionary<string, SourceCursor> cursors =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DateTimeOffset> initialReadFailures =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<(string Source, long Run), OperationAccumulator> operations = [];
    private readonly Dictionary<(string Source, long Run), RunMetricAccumulator> runMetrics = [];
    private readonly List<RunMetricAccumulator> retainedMetrics = [];
    private readonly Dictionary<string, LogEntryView> logs = new(StringComparer.Ordinal);
    private readonly List<LogEntryView> pendingLogs = [];
    private readonly Dictionary<string, TelemetryHealth> lastSourceHealth =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, byte> dismissedOperations =
        new(StringComparer.Ordinal);
    private readonly object logOptionsGate = new();
    private readonly SemaphoreSlim logPublishGate = new(1, 1);
    private LogProjectionOptions logOptions = new();
    private int minimumRecordedLogLevel = (int)LogLevel.Trace;

    public void ConfigureRecordingLevel(LogLevel level)
    {
        if (!Enum.IsDefined(level)) throw new ArgumentOutOfRangeException(nameof(level));
        Volatile.Write(ref minimumRecordedLogLevel, (int)level);
    }

    public void ConfigureLogs(LogProjectionOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        lock (logOptionsGate) logOptions = options.Validate();
    }

    public void DismissOperation(string operationId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(operationId);
        dismissedOperations[operationId] = 0;
    }

    public async Task ProjectOnceAsync(
        DateTimeOffset? observedUtc = null,
        CancellationToken cancellationToken = default)
    {
        var now = observedUtc ?? DateTimeOffset.UtcNow;
        var healthViews = new List<TelemetrySourceView>();
        var sourcesCatchingUp = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var historicalSourcesFullyRead = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var registrations = catalog.Snapshot();
        var registeredIds = registrations.Select(item => item.SourceId)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var removed in cursors.Keys.Where(id => !registeredIds.Contains(id)).ToArray())
        {
            cursors.Remove(removed);
            RemoveSourceState(removed);
        }
        foreach (var removed in initialReadFailures.Keys
                     .Where(id => !registeredIds.Contains(id)).ToArray())
            initialReadFailures.Remove(removed);
        foreach (var source in registrations)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var workflowRunning = source.CurrentWorkflow?.Status == OperationStatus.Running;
            var completedSource = source.Transient
                && source.CurrentWorkflow is { Status: not (OperationStatus.Running or OperationStatus.Waiting) }
                && !PzTools.Process.Telemetry.ProcessTelemetryActivity.IsActive(source.Identity, source.Component);
            if (!source.Enabled)
            {
                initialReadFailures.Remove(source.SourceId);
                healthViews.Add(Health(source, null, TelemetryHealth.Disabled, null, "disabled"));
                if (completedSource)
                    historicalSourcesFullyRead.Add(source.SourceId);
                continue;
            }
            if (!File.Exists(source.DatabasePath))
            {
                var health = workflowRunning
                    && now - source.CurrentWorkflow!.StartedUtc > staleAfter
                    ? TelemetryHealth.Stale : TelemetryHealth.Waiting;
                healthViews.Add(Health(source, null, health, null, "database-missing"));
                if (completedSource) historicalSourcesFullyRead.Add(source.SourceId);
                continue;
            }

            try
            {
                var page = await TelemetryDatabaseReader.ReadAsync(
                    source, cursors.GetValueOrDefault(source.SourceId),
                    (int)Math.Min((long)maximumPagesPerProjection * 512, int.MaxValue),
                    cancellationToken, readTimeoutSeconds);
                initialReadFailures.Remove(source.SourceId);
                if (page.Reset) RemoveSourceState(source.SourceId);
                foreach (var telemetryEvent in page.Events)
                    Reduce(source, page.InstanceId, telemetryEvent);
                cursors[source.SourceId] = new SourceCursor(
                    page.InstanceId, page.LastEventId, page.LastEventUtc,
                    page.MinimumEventId);
                if (page.HasMore) sourcesCatchingUp.Add(source.SourceId);
                else if (completedSource) historicalSourcesFullyRead.Add(source.SourceId);
                if (page.RetainedRunIndexes is not null)
                    PruneSourceRuns(source.SourceId, page.RetainedRunIndexes,
                        source.CurrentWorkflow?.RunIndex);
                var health = TelemetryHealth.Healthy;
                if (workflowRunning)
                {
                    var workflow = source.CurrentWorkflow!;
                    var hasCurrentRunEvent = operations.TryGetValue(
                        (source.SourceId, workflow.RunIndex), out var currentRun);
                    var lastActivity = hasCurrentRunEvent
                        && currentRun!.LastEventUtc > workflow.StartedUtc
                            ? currentRun.LastEventUtc : workflow.StartedUtc;
                    // The database's last event can belong to a previous run. Until this
                    // run emits its first event, use its start time instead. A partial
                    // replay cannot prove that the worker stopped sending heartbeats.
                    health = page.HasMore ? TelemetryHealth.Waiting
                        : now - lastActivity > staleAfter ? TelemetryHealth.Stale
                        : hasCurrentRunEvent ? TelemetryHealth.Healthy
                        : TelemetryHealth.Waiting;
                }
                healthViews.Add(Health(
                    source, page.InstanceId, health, page.LastEventUtc,
                    health == TelemetryHealth.Stale ? "heartbeat-stale" : null));
            }
            catch (UnsupportedTelemetrySchemaException exception)
            {
                healthViews.Add(Health(
                    source, null, TelemetryHealth.UnsupportedSchema, null, exception.Message, exception));
            }
            catch (Exception exception) when (IsInitializingDatabase(
                       source, exception, now))
            {
                healthViews.Add(Health(
                    source, null, TelemetryHealth.Waiting, null, "database-initializing"));
            }
            catch (Exception exception) when (
                exception is SqliteException or IOException or UnauthorizedAccessException
                    or InvalidDataException)
            {
                healthViews.Add(Health(
                    source, null, TelemetryHealth.Unreadable, null, exception.GetType().Name, exception));
            }
        }

        var healthBySource = healthViews.ToDictionary(item => item.SourceId, StringComparer.OrdinalIgnoreCase);
        RecordHealthTransitions(healthViews, now);
        var operationViews = BuildOperations(registrations, healthBySource, sourcesCatchingUp, now);
        views.Publish(
            ViewKey.TelemetrySources,
            new TelemetrySourcesView(healthViews),
            comparer: ViewComparers.TelemetrySources);
        views.Publish(
            ViewKey.Operations,
            new OperationsView(operationViews),
            comparer: ViewComparers.Operations);
        views.Publish(
            ViewKey.Metrics,
            BuildMetrics(),
            comparer: ViewComparers.Metrics);
        await PublishLogsAsync(cancellationToken);
        if (logInbox is not null)
        {
            foreach (var sourceId in historicalSourcesFullyRead)
                await logInbox.MarkSourceImportedAsync(sourceId, cancellationToken);
        }
        await RetireTransientSourcesAsync(registrations, now, historicalSourcesFullyRead, cancellationToken);
    }

    private bool IsInitializingDatabase(
        TelemetrySourceRegistration source,
        Exception exception,
        DateTimeOffset now)
    {
        // A worker creates the database file before its tables and metadata are ready.
        // Allow only initial missing-schema, metadata or lock errors a brief grace period;
        // persistent failures and corrupt databases must still surface as errors.
        // Background collectors also initialize databases without a UI workflow.
        if (cursors.ContainsKey(source.SourceId)
            || exception is not (TelemetryNotReadyException
                or SqliteException { SqliteErrorCode: 1 or 5 or 6 }))
            return false;
        if (!initialReadFailures.TryGetValue(source.SourceId, out var firstFailure))
        {
            initialReadFailures[source.SourceId] = now;
            firstFailure = now;
        }
        return now >= firstFailure && now - firstFailure < InitialDatabaseReadGrace;
    }

    private void Reduce(
        TelemetrySourceRegistration source,
        Guid instanceId,
        NormalizedTelemetryEvent telemetryEvent)
    {
        var key = (source.SourceId, telemetryEvent.RunIndex);
        if (!operations.TryGetValue(key, out var operation))
        {
            var workflow = source.CurrentWorkflow?.RunIndex == telemetryEvent.RunIndex
                ? source.CurrentWorkflow
                : null;
            operation = new OperationAccumulator(
                workflow?.OperationId ?? $"{source.SourceId}:{telemetryEvent.RunIndex}",
                workflow?.Kind ?? source.Component,
                source.Component,
                telemetryEvent.RunIndex);
            operations.Add(key, operation);
        }
        if (!runMetrics.TryGetValue(key, out var metrics))
        {
            metrics = new RunMetricAccumulator(source.Component, telemetryEvent.RunIndex);
            runMetrics.Add(key, metrics);
        }
        operation.Apply(telemetryEvent);
        metrics.Apply(telemetryEvent);
        AddLog(source, instanceId, telemetryEvent, operation.CurrentFile);
    }

    private void AddLog(
        TelemetrySourceRegistration source,
        Guid instanceId,
        NormalizedTelemetryEvent item,
        string? currentFile)
    {
        var level = ClassifyLogLevel(source.Component, item.Name, item.Payload);
        if (level is null || level.Value < (LogLevel)Volatile.Read(ref minimumRecordedLogLevel)) return;
        var entryId = $"{source.SourceId}:{instanceId:N}:{item.EventId}";
        var payloadJson = item.Payload?.GetRawText();
        if (item.Name == "run.failed" && currentFile is not null
            && LogDiagnostics.Parse(payloadJson) is
                { FailureCode: "UnstableFileException", Path: null }
            && JsonNode.Parse(payloadJson!) is JsonObject details)
        {
            details["path"] = currentFile;
            details["phase"] = "capture";
            payloadJson = details.ToJsonString();
        }
        var entry = new LogEntryView(
            entryId,
            source.SourceId,
            instanceId,
            item.EventId,
            item.OccurredUtc,
            level.Value,
            source.Component,
            item.RunIndex,
            item.Name,
            payloadJson);
        pendingLogs.Add(entry);
        if (logInbox is null)
        {
            logs[entryId] = entry;
            TrimLogBuffer();
        }
    }

    private void RecordHealthTransitions(
        IReadOnlyList<TelemetrySourceView> healthViews,
        DateTimeOffset now)
    {
        foreach (var source in healthViews)
        {
            var hadPrevious = lastSourceHealth.TryGetValue(source.SourceId, out var previous);
            lastSourceHealth[source.SourceId] = source.Health;
            if (hadPrevious && previous == source.Health) continue;

            var level = source.Health switch
            {
                TelemetryHealth.Unreadable or TelemetryHealth.UnsupportedSchema => LogLevel.Error,
                TelemetryHealth.Stale => LogLevel.Warning,
                TelemetryHealth.Healthy when hadPrevious
                    && previous is TelemetryHealth.Unreadable
                        or TelemetryHealth.UnsupportedSchema
                        or TelemetryHealth.Stale => LogLevel.Information,
                _ => (LogLevel?)null,
            };
            if (level is null || level.Value < (LogLevel)Volatile.Read(ref minimumRecordedLogLevel)) continue;
            var entryId = $"health:{source.SourceId}:{Guid.NewGuid():N}";
            var entry = new LogEntryView(
                entryId,
                source.SourceId,
                source.InstanceId ?? Guid.Empty,
                0,
                now,
                level.Value,
                source.Component,
                0,
                source.Health == TelemetryHealth.Healthy
                    ? "telemetry.source.recovered"
                    : $"telemetry.source.{source.Health.ToString().ToLowerInvariant()}",
                source.ErrorPayloadJson ?? (source.Message is null
                    ? null
                    : JsonSerializer.Serialize(new { message = source.Message })));
            pendingLogs.Add(entry);
            if (logInbox is not null) continue;
            logs[entryId] = entry;
        }
        if (logInbox is null) TrimLogBuffer();
    }

    private void TrimLogBuffer()
    {
        const int capacity = 10000;
        if (logs.Count <= capacity) return;
        foreach (var key in logs.Values
                     .OrderByDescending(item => item.OccurredUtc)
                     .ThenByDescending(item => item.EventId)
                     .Skip(capacity)
                     .Select(item => item.EntryId)
                     .ToArray())
            logs.Remove(key);
    }

    private async Task PublishLogsAsync(CancellationToken cancellationToken)
    {
        await logPublishGate.WaitAsync(cancellationToken);
        try
        {
            LogProjectionOptions options;
            lock (logOptionsGate) options = logOptions;
            if (logInbox is not null)
            {
                await logInbox.AppendAsync(pendingLogs, cancellationToken);
                pendingLogs.Clear();
                views.Publish(
                    ViewKey.Logs,
                    await logInbox.ReadViewAsync(options, cancellationToken),
                    comparer: ViewComparers.Logs);
                return;
            }
            pendingLogs.Clear();
            var entries = logs.Values
                .Where(item => item.Level >= options.MinimumLevel)
                .OrderByDescending(item => item.OccurredUtc)
                .ThenByDescending(item => item.EventId)
                .Take(options.DisplayLimit)
                .ToArray();
            views.Publish(
                ViewKey.Logs,
                new LogsView(entries),
                comparer: ViewComparers.Logs);
        }
        finally { logPublishGate.Release(); }
    }

    public async Task<LogsView> RefreshLogViewAsync(CancellationToken cancellationToken = default)
    {
        if (logInbox is null) throw new InvalidOperationException("The log inbox is not configured.");
        await logPublishGate.WaitAsync(cancellationToken);
        try
        {
            LogProjectionOptions options;
            lock (logOptionsGate) options = logOptions;
            var result = await logInbox.ReadViewAsync(options, cancellationToken);
            views.Publish(ViewKey.Logs, result,
                comparer: ViewComparers.Logs);
            return result;
        }
        finally { logPublishGate.Release(); }
    }

    private static LogLevel? ClassifyLogLevel(string component, string name, JsonElement? payload)
    {
        if (name == "operation.heartbeat"
            || name == "workload.discovered"
            || name == "progress.snapshot"
            || IsCompletedFileEvent(name))
            return null;
        if (name.StartsWith("maintenance.", StringComparison.Ordinal))
        {
            // Background cleanup is logged when it has real work; routine no-op checks stay trace-only.
            if (name.EndsWith(".started", StringComparison.Ordinal))
                return IsPlannedMaintenance(payload) ? LogLevel.Information : LogLevel.Trace;
            // Yielding to a backup or to the game postpones the work; it is not a fault.
            if (name.EndsWith(".cancelled", StringComparison.Ordinal)) return LogLevel.Information;
            if (name == "maintenance.recovery.completed") return LogLevel.Information;
        }
        // The backup went ahead without the game's own save: worth seeing, though nothing failed.
        if (name == "source.prepare.completed" && payload is { ValueKind: JsonValueKind.Object } prepared
            && LogDiagnostics.ReadOutcome(prepared) == "save-unavailable")
            return LogLevel.Warning;
        if (name.Contains("critical", StringComparison.OrdinalIgnoreCase))
            return LogLevel.Critical;
        if (name.EndsWith(".failed", StringComparison.Ordinal)
            || name.Contains("error", StringComparison.OrdinalIgnoreCase))
            return LogLevel.Error;
        // Work that did not start because other work was running: the card says so and it can simply be
        // started again. Nothing failed, so it is no problem to acknowledge in the logs.
        if (name.EndsWith(".busy", StringComparison.Ordinal)) return LogLevel.Information;
        // Work that could not start because what it needs is absent, such as a recording with no game running.
        if (name.EndsWith(".unavailable", StringComparison.Ordinal)) return LogLevel.Information;
        if (name.Contains("warning", StringComparison.OrdinalIgnoreCase)
            || name.EndsWith(".degraded", StringComparison.Ordinal)
            || name.EndsWith(".cancelled", StringComparison.Ordinal))
            return LogLevel.Warning;
        if (name.EndsWith(".started", StringComparison.Ordinal)
            && name != "run.started")
            return LogLevel.Trace;
        // 주기적인 상태 확인은 추적용입니다. 완료 이벤트라도 실패 결과는 숨기지 않습니다.
        if (IsOutcomeCompletion(name))
        {
            if (payload is { ValueKind: JsonValueKind.Object } value)
            {
                if (LogDiagnostics.ReadOutcome(value) is { } outcomeText)
                {
                    if (outcomeText == "Abandoned") return LogLevel.Error;
                    if (!Enum.TryParse<ProcessOutcome>(outcomeText, true, out var outcome)
                        || !Enum.IsDefined(outcome)) return LogLevel.Warning;
                    return outcome switch
                    {
                        ProcessOutcome.Busy when name == "tick.completed"
                            && component == "state-scheduler"
                            && value.TryGetProperty("Started", out var started)
                            && started.ValueKind == JsonValueKind.False => LogLevel.Trace,
                        ProcessOutcome.Failed => LogLevel.Error,
                        ProcessOutcome.Busy or ProcessOutcome.Degraded or ProcessOutcome.Cancelled => LogLevel.Warning,
                        _ when name.StartsWith("maintenance.", StringComparison.Ordinal)
                            && (IsPlannedMaintenance(value) || AffectedMaintenanceItems(value) > 0) => LogLevel.Information,
                        _ => LogLevel.Trace,
                    };
                }
            }
            // tick은 outcome 계약이 있으므로 불완전한 레코드를 정상 점검으로 간주하지 않습니다.
            return name == "tick.completed" ? LogLevel.Information : LogLevel.Trace;
        }
        return LogLevel.Information;
    }

    private static bool IsPlannedMaintenance(JsonElement? payload) =>
        payload is { ValueKind: JsonValueKind.Object } value
        && value.TryGetProperty("planned", out var planned) && planned.ValueKind == JsonValueKind.True;

    private static long AffectedMaintenanceItems(JsonElement payload) =>
        ReadInt64(payload, "affectedItems") ?? 0;

    private IReadOnlyList<OperationView> BuildOperations(
        IReadOnlyList<TelemetrySourceRegistration> registrations,
        IReadOnlyDictionary<string, TelemetrySourceView> healthBySource,
        IReadOnlySet<string> sourcesCatchingUp,
        DateTimeOffset now)
    {
        var result = new List<OperationView>();
        foreach (var source in registrations)
        {
            if (source.LogsOnly) continue;
            var health = healthBySource[source.SourceId];
            if (source.CurrentWorkflow is not null)
            {
                var key = (source.SourceId, source.CurrentWorkflow.RunIndex);
                var completedUtc = source.CurrentWorkflow.CompletedUtc
                    ?? (source.CurrentWorkflow.Status is OperationStatus.Running or OperationStatus.Waiting
                        ? null : source.CurrentWorkflow.StartedUtc);
                if (!operations.TryGetValue(key, out var accumulator))
                {
                    result.Add(new OperationView(
                        source.SourceId,
                        source.CurrentWorkflow.OperationId,
                        source.CurrentWorkflow.Kind,
                        source.Component,
                        source.CurrentWorkflow.RunIndex,
                        source.CurrentWorkflow.Status,
                        null, 0, null, 0, null, health.Health,
                        health.Health is TelemetryHealth.Healthy
                            ? null : "running-progress-unavailable",
                        completedUtc));
                }
                else
                {
                    result.Add(accumulator.ToView(
                        source.SourceId, source.CurrentWorkflow.Status, health.Health,
                        completedUtc));
                }
            }
            foreach (var item in operations.Where(item =>
                          StringComparer.OrdinalIgnoreCase.Equals(item.Key.Source, source.SourceId)
                          && item.Key.Run != source.CurrentWorkflow?.RunIndex))
            {
                // 재생 중인 과거 기록은 완료 이벤트를 아직 읽지 못해 진행 중처럼 보일 수 있습니다.
                if (sourcesCatchingUp.Contains(source.SourceId)) continue;
                if (item.Value.IsUnfinished
                    && now - item.Value.LastEventUtc > staleAfter) continue;
                if (item.Value.IsMaintenance && !item.Value.ShowMaintenance(now)) continue;
                result.Add(item.Value.ToView(source.SourceId, null, health.Health, null));
            }
        }
        return result.Where(item => !dismissedOperations.ContainsKey(item.OperationId))
            .Where(item => !IsTerminalExpired(item.Status, item.CompletedUtc, now, IsMaintenanceProducer(item.Producer)))
            .OrderByDescending(item => item.RunIndex).ToArray();
    }

    private static bool IsMaintenanceProducer(string producer) =>
        producer.StartsWith("maintenance", StringComparison.Ordinal);

    private bool IsTerminalExpired(
        OperationStatus status, DateTimeOffset? completedUtc, DateTimeOffset now, bool maintenance = false) =>
        OperationCardLifetime.IsExpired(status, completedUtc, now, maintenance,
            successCardLifetime ?? TimeSpan.FromSeconds(5), failureCardLifetime ?? TimeSpan.FromSeconds(10));

    private MetricsView BuildMetrics()
    {
        var producers = runMetrics.Values.Concat(retainedMetrics)
            .GroupBy(item => item.Producer, StringComparer.Ordinal);
        return new MetricsView(producers.Select(group =>
        {
            var runs = group.ToArray();
            var bytes = runs.Sum(item => item.Bytes);
            var seconds = runs.Sum(item => item.ElapsedSeconds);
            var phases = runs.SelectMany(item => item.PhaseDurations)
                .GroupBy(item => item.Key, StringComparer.Ordinal)
                .ToDictionary(
                    item => item.Key,
                    item => TimeSpan.FromTicks(item.Sum(value => value.Value.Ticks)),
                    StringComparer.Ordinal);
            return new ProducerMetricsView(
                group.Key,
                runs.Length,
                runs.Count(item => item.Status is OperationStatus.Succeeded or OperationStatus.NoChange),
                runs.Count(item => item.Status is OperationStatus.Failed or OperationStatus.Cancelled),
                bytes,
                seconds > 0 ? bytes / seconds : null,
                phases);
        }).OrderBy(item => item.Producer, StringComparer.Ordinal).ToArray());
    }

    private async Task RetireTransientSourcesAsync(
        IReadOnlyList<TelemetrySourceRegistration> registrations,
        DateTimeOffset now,
        IReadOnlySet<string> historicalSourcesFullyRead, CancellationToken cancellationToken)
    {
        foreach (var source in registrations.Where(item => item.Transient
                     && item.CurrentWorkflow is not null))
        {
            var workflow = source.CurrentWorkflow!;
            var dismiss = dismissedOperations.ContainsKey(workflow.OperationId);
            var expired = IsTerminalExpired(workflow.Status,
                workflow.CompletedUtc ?? workflow.StartedUtc, now);
            if (workflow.Status is OperationStatus.Running or OperationStatus.Waiting) continue;
            if (!historicalSourcesFullyRead.Contains(source.SourceId)) continue;
            if (!dismiss && !expired) continue;
            if (retireSource is not null && (logInbox is null || !retireSource(source))) continue;
            if (retireSource is not null)
                await logInbox!.ForgetImportedSourceAsync(source.SourceId, cancellationToken);
            foreach (var key in runMetrics.Keys.Where(key =>
                         StringComparer.OrdinalIgnoreCase.Equals(
                             key.Source, source.SourceId)).ToArray())
            {
                retainedMetrics.Add(runMetrics[key]);
                runMetrics.Remove(key);
            }
            if (retainedMetrics.Count > 100)
                retainedMetrics.RemoveRange(0, retainedMetrics.Count - 100);
            foreach (var key in operations.Keys.Where(key =>
                         StringComparer.OrdinalIgnoreCase.Equals(
                             key.Source, source.SourceId)).ToArray())
                operations.Remove(key);
            cursors.Remove(source.SourceId);
            initialReadFailures.Remove(source.SourceId);
            catalog.Remove(source.SourceId);
            lastSourceHealth.Remove(source.SourceId);
            dismissedOperations.TryRemove(workflow.OperationId, out _);
        }
    }

    private void RemoveSourceState(string sourceId)
    {
        foreach (var key in operations.Keys.Where(key =>
                     StringComparer.OrdinalIgnoreCase.Equals(key.Source, sourceId)).ToArray())
            operations.Remove(key);
        foreach (var key in runMetrics.Keys.Where(key =>
                     StringComparer.OrdinalIgnoreCase.Equals(key.Source, sourceId)).ToArray())
            runMetrics.Remove(key);
    }

    private void PruneSourceRuns(
        string sourceId,
        IReadOnlySet<long> retainedRuns,
        long? currentRun)
    {
        foreach (var key in operations.Keys.Where(key =>
                     StringComparer.OrdinalIgnoreCase.Equals(key.Source, sourceId)
                     && key.Run != currentRun
                     && !retainedRuns.Contains(key.Run)).ToArray())
            operations.Remove(key);
        foreach (var key in runMetrics.Keys.Where(key =>
                     StringComparer.OrdinalIgnoreCase.Equals(key.Source, sourceId)
                     && key.Run != currentRun
                     && !retainedRuns.Contains(key.Run)).ToArray())
            runMetrics.Remove(key);
    }

    private static TelemetrySourceView Health(
        TelemetrySourceRegistration source,
        Guid? instance,
        TelemetryHealth health,
        DateTimeOffset? lastEvent,
        string? message,
        Exception? exception = null) => new(
            source.SourceId, source.Component, source.Identity, instance,
            health, lastEvent, message)
        {
            ErrorPayloadJson = exception is null ? null : FailureTelemetry.FromException(
                "telemetry-read-failed", exception, phase: "telemetry-read", path: source.DatabasePath),
        };

    private sealed record SourceCursor(Guid InstanceId, long EventId,
        DateTimeOffset? LastEventUtc, long MinimumEventId);

    private sealed class OperationAccumulator(
        string operationId,
        string kind,
        string producer,
        long runIndex)
    {
        private OperationStatus status = OperationStatus.Waiting;
        private string? phase;
        private long completedItems;
        private long? totalItems;
        private long completedBytes;
        private long completedBackupBytes;
        private long? totalBytes;
        private DateTimeOffset? completedUtc;
        public string? CurrentFile { get; private set; }

        public bool IsUnfinished => status is OperationStatus.Waiting or OperationStatus.Running;
        public DateTimeOffset LastEventUtc { get; private set; }
        public bool IsMaintenance { get; } = IsMaintenanceProducer(producer);
        private bool planned, shownRunning;
        private DateTimeOffset startedUtc;

        /// <summary>
        /// Background cleanup gets a card only while it is visibly working: at once when it announced
        /// real work, otherwise after it has run long enough to matter. A finished run keeps the card it
        /// already had; one that was never shown appears only if it needs attention.
        /// </summary>
        public bool ShowMaintenance(DateTimeOffset now)
        {
            if (status == OperationStatus.Running)
                return shownRunning |= planned || now - startedUtc >= TimeSpan.FromSeconds(2);
            return status != OperationStatus.Waiting
                && (shownRunning || status is OperationStatus.Failed or OperationStatus.Degraded);
        }

        public void Apply(NormalizedTelemetryEvent item)
        {
            LastEventUtc = item.OccurredUtc;
            if (IsMaintenance && item.Name.EndsWith(".started", StringComparison.Ordinal))
            {
                startedUtc = item.OccurredUtc;
                planned |= IsPlannedMaintenance(item.Payload);
            }
            if (item.Name == "file.capture.started" && item.Payload is JsonElement started
                && started.TryGetProperty("path", out var path)
                && path.ValueKind == JsonValueKind.String)
                CurrentFile = path.GetString();
            else if (item.Name == "file.capture.completed") CurrentFile = null;
            status = StatusFromEvent(item, status);
            if (status is OperationStatus.Succeeded or OperationStatus.NoChange
                or OperationStatus.Failed or OperationStatus.Cancelled
                or OperationStatus.Degraded or OperationStatus.Busy)
                completedUtc = item.OccurredUtc;
            if (item.Name.EndsWith(".started", StringComparison.Ordinal)
                && !item.Name.StartsWith("file.", StringComparison.Ordinal)
                && item.Name != "run.started")
                phase = item.Name[..^".started".Length];
            if (item.Name == "workload.discovered" && item.Payload is JsonElement workload)
            {
                // 명시적인 단계별 작업량은 해당 단계의 카운터로 시작합니다.
                // 단계가 없는 기존 백업 telemetry의 누적 의미는 유지합니다.
                if (workload.TryGetProperty("phase", out var phaseValue)
                    && phaseValue.ValueKind == JsonValueKind.String)
                {
                    phase = phaseValue.GetString();
                    completedItems = 0;
                    completedBytes = 0;
                    completedBackupBytes = 0;
                }
                totalItems = ReadInt64(workload, "totalItems");
                totalBytes = ReadInt64(workload, "totalBytes");
            }
            if (item.Name == "progress.snapshot" && item.Payload is JsonElement snapshot)
            {
                phase = snapshot.TryGetProperty("phase", out var phaseValue)
                    && phaseValue.ValueKind == JsonValueKind.String
                    ? phaseValue.GetString() : phase;
                completedItems = ReadInt64(snapshot, "completedItems") ?? completedItems;
                totalItems = ReadInt64(snapshot, "totalItems", totalItems);
                completedBytes = ReadInt64(snapshot, "completedBytes") ?? completedBytes;
                totalBytes = ReadInt64(snapshot, "totalBytes", totalBytes);
            }
            if (IsCompletedFileEvent(item.Name))
            {
                completedItems++;
                var fileBytes = item.Payload is JsonElement payload
                    ? ReadInt64(payload, "bytes") ?? 0 : 0;
                if (item.Name == "file.capture.completed")
                {
                    completedBackupBytes += fileBytes;
                    completedBytes = completedBackupBytes;
                    if (phase is "copy" or "copy.retry") phase = "capture";
                }
                else
                {
                    completedBytes += fileBytes;
                }
            }
        }

        public OperationView ToView(
            string sourceId,
            OperationStatus? authoritativeStatus,
            TelemetryHealth health,
            DateTimeOffset? authoritativeCompletedUtc) => new(
                sourceId, operationId, kind, producer, runIndex,
                authoritativeStatus ?? status, phase,
                completedItems, totalItems, completedBytes, totalBytes, health,
                health is TelemetryHealth.Healthy ? null : "progress-unavailable",
                authoritativeCompletedUtc ?? completedUtc);
    }

    private sealed class RunMetricAccumulator(string producer, long runIndex)
    {
        private readonly Dictionary<string, long> phaseStarts = new(StringComparer.Ordinal);
        private readonly Dictionary<string, TimeSpan> phaseDurations = new(StringComparer.Ordinal);
        private readonly Dictionary<string, long> phaseBytes = new(StringComparer.Ordinal);
        private long? firstTicks;
        private long? lastTicks;

        public string Producer { get; } = producer;
        public long RunIndex { get; } = runIndex;
        public OperationStatus Status { get; private set; } = OperationStatus.Waiting;
        public long Bytes { get; private set; }
        public double ElapsedSeconds => firstTicks is null || lastTicks is null
            ? 0 : Math.Max(0, lastTicks.Value - firstTicks.Value) / (double)Stopwatch.Frequency;
        public IReadOnlyDictionary<string, TimeSpan> PhaseDurations => phaseDurations;

        public void Apply(NormalizedTelemetryEvent item)
        {
            firstTicks ??= item.ElapsedTicks;
            lastTicks = item.ElapsedTicks;
            Status = StatusFromEvent(item, Status);
            if (IsCompletedFileEvent(item.Name) && item.Payload is JsonElement payload)
                Bytes += ReadInt64(payload, "bytes") ?? 0;
            if (item.Name == "progress.snapshot" && item.Payload is JsonElement snapshot)
            {
                var phase = snapshot.TryGetProperty("phase", out var phaseValue)
                    && phaseValue.ValueKind == JsonValueKind.String ? phaseValue.GetString() ?? "" : "";
                var completed = ReadInt64(snapshot, "completedBytes") ?? 0;
                phaseBytes.TryGetValue(phase, out var previous);
                Bytes += Math.Max(0, completed - previous);
                phaseBytes[phase] = completed;
            }
            if (item.Name.EndsWith(".started", StringComparison.Ordinal))
                phaseStarts[item.Name[..^".started".Length]] = item.ElapsedTicks;
            if (item.Name.EndsWith(".completed", StringComparison.Ordinal))
            {
                var name = item.Name[..^".completed".Length];
                if (phaseStarts.Remove(name, out var start))
                    phaseDurations[name] = TimeSpan.FromSeconds(
                        Math.Max(0, item.ElapsedTicks - start) / (double)Stopwatch.Frequency);
            }
        }
    }

    private static bool IsOutcomeCompletion(string name) =>
        name is "tick.completed" or "collector.completed" or "reactor.completed"
            or "state-runner.completed" or "runner.completed" or "backup.completed"
        || name.StartsWith("maintenance.", StringComparison.Ordinal)
            && name.EndsWith(".completed", StringComparison.Ordinal);

    private static OperationStatus StatusFromEvent(NormalizedTelemetryEvent item, OperationStatus current)
    {
        if (IsOutcomeCompletion(item.Name) && item.Payload is { ValueKind: JsonValueKind.Object } payload
            && LogDiagnostics.ReadOutcome(payload) is { } outcome)
            return outcome switch
            {
                "Succeeded" => OperationStatus.Succeeded,
                "NoChange" or "Skipped" => OperationStatus.NoChange,
                "Failed" or "Abandoned" => OperationStatus.Failed,
                "Cancelled" => OperationStatus.Cancelled,
                "Busy" => OperationStatus.Busy,
                "Degraded" => OperationStatus.Degraded,
                _ => current,
            };
        return item.Name switch
        {
            "run.started" => OperationStatus.Running,
            "run.committed" => OperationStatus.Succeeded,
            "run.no_changes" => OperationStatus.NoChange,
            "run.failed" => OperationStatus.Failed,
            "run.cancelled" => OperationStatus.Cancelled,
            "run.busy" => OperationStatus.Busy,
            // Did not start, like work that found other work running; the card names what was missing.
            "run.unavailable" => OperationStatus.Busy,
            // Interrupted-operation recovery reports inside a cleanup run; it is a log entry, not that run's state.
            _ when item.Name.StartsWith("maintenance.", StringComparison.Ordinal)
                && !item.Name.StartsWith("maintenance.recovery.", StringComparison.Ordinal) =>
                item.Name.EndsWith(".started", StringComparison.Ordinal) ? OperationStatus.Running
                : item.Name.EndsWith(".failed", StringComparison.Ordinal) ? OperationStatus.Failed
                : item.Name.EndsWith(".cancelled", StringComparison.Ordinal) ? OperationStatus.Cancelled
                : item.Name.EndsWith(".completed", StringComparison.Ordinal) && current == OperationStatus.Waiting
                    ? OperationStatus.Succeeded : current,
            _ when item.Name.EndsWith(".completed", StringComparison.Ordinal)
                && current == OperationStatus.Waiting => OperationStatus.Succeeded,
            _ => current,
        };
    }

    private static bool IsCompletedFileEvent(string name) =>
        name.StartsWith("file.", StringComparison.Ordinal)
        && name.EndsWith(".completed", StringComparison.Ordinal);

    private static long? ReadInt64(JsonElement element, string name, long? missingValue = null)
    {
        // A missing field preserves earlier metadata; explicit null means unknown.
        // TryGetInt64 throws on JSON null, so check the type before reading it.
        if (!element.TryGetProperty(name, out var value)
            && !element.TryGetProperty(char.ToUpperInvariant(name[0]) + name[1..], out value))
            return missingValue;
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var result)
            ? result : null;
    }

    private sealed record NormalizedTelemetryEvent(
        long EventId,
        long RunIndex,
        string Name,
        DateTimeOffset OccurredUtc,
        long ElapsedTicks,
        JsonElement? Payload);

    private sealed record TelemetryReadPage(
        Guid InstanceId,
        long LastEventId,
        DateTimeOffset? LastEventUtc,
        long MinimumEventId,
        bool Reset,
        bool HasMore,
        IReadOnlySet<long>? RetainedRunIndexes,
        IReadOnlyList<NormalizedTelemetryEvent> Events);

    private sealed class UnsupportedTelemetrySchemaException(string message)
        : Exception(message);

    private sealed class TelemetryNotReadyException()
        : IOException("Telemetry metadata is not initialized yet.");

    private static class TelemetryDatabaseReader
    {
        public static async Task<TelemetryReadPage> ReadAsync(
            TelemetrySourceRegistration source,
            SourceCursor? cursor,
            int maximumEvents,
            CancellationToken cancellationToken,
            int timeoutSeconds)
        {
            var connectionString = new SqliteConnectionStringBuilder
            {
                DataSource = source.DatabasePath,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false,
                DefaultTimeout = timeoutSeconds > 0 ? timeoutSeconds
                    : throw new ArgumentOutOfRangeException(nameof(timeoutSeconds)),
            }.ToString();
            await using var connection = new SqliteConnection(connectionString);
            await connection.OpenAsync(cancellationToken);
            // Microsoft.Data.Sqlite retries BUSY independently of PRAGMA busy_timeout.
            // Bound the provider's timeout so one unavailable source cannot hold the
            // entire progress projection for its default thirty seconds.
            try
            {
                return source.DatabaseKind == TelemetryDatabaseKind.Backup
                    ? await ReadBackupAsync(connection, cursor, maximumEvents, cancellationToken)
                    : await ReadProcessAsync(connection, cursor, maximumEvents, cancellationToken);
            }
            catch (Exception exception) when (exception is JsonException or FormatException or InvalidCastException)
            {
                throw new InvalidDataException("Telemetry contains an invalid metadata or event value.", exception);
            }
        }

        private static async Task<TelemetryReadPage> ReadBackupAsync(
            SqliteConnection connection, SourceCursor? cursor, int maximumEvents, CancellationToken token)
        {
            var (schema, instance) = await ReadMetadataAsync(
                connection,
                "SELECT schema_version,telemetry_instance_id FROM telemetry_info WHERE singleton=1;",
                token);
            if (schema != 2) throw new UnsupportedTelemetrySchemaException($"backup:{schema}");
            return await ReadEventsAsync(
                connection, instance, cursor,
                "SELECT COALESCE((SELECT MIN(event_id) FROM telemetry_events),0),COALESCE((SELECT MAX(event_id) FROM telemetry_events),0);",
                "SELECT event_id,run_index,name,timestamp_utc,elapsed_ticks,payload_json "
                + "FROM telemetry_events WHERE event_id>$after ORDER BY event_id LIMIT $limit;",
                maximumEvents, token);
        }

        private static async Task<TelemetryReadPage> ReadProcessAsync(
            SqliteConnection connection, SourceCursor? cursor, int maximumEvents, CancellationToken token)
        {
            var (schema, instance) = await ReadMetadataAsync(
                connection,
                "SELECT schema_version,telemetry_instance_id FROM process_telemetry_info WHERE singleton=1;",
                token);
            if (schema != 3) throw new UnsupportedTelemetrySchemaException($"process:{schema}");
            return await ReadEventsAsync(
                connection, instance, cursor,
                "SELECT COALESCE((SELECT MIN(event_id) FROM telemetry_events),0),COALESCE((SELECT MAX(event_id) FROM telemetry_events),0);",
                "SELECT event_id,run_index,event_name,occurred_utc,elapsed_ticks,payload_json "
                + "FROM telemetry_events WHERE event_id>$after ORDER BY event_id LIMIT $limit;",
                maximumEvents, token);
        }

        private static async Task<(int Schema, Guid Instance)> ReadMetadataAsync(
            SqliteConnection connection, string sql, CancellationToken token)
        {
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            await using var reader = await command.ExecuteReaderAsync(token);
            if (!await reader.ReadAsync(token) || reader.IsDBNull(1))
                throw new TelemetryNotReadyException();
            return (reader.GetInt32(0), Guid.Parse(reader.GetString(1)));
        }

        private static async Task<TelemetryReadPage> ReadEventsAsync(
            SqliteConnection connection,
            Guid instance,
            SourceCursor? cursor,
            string boundsSql,
            string eventsSql,
            int maximumEvents,
            CancellationToken token)
        {
            await using var bounds = connection.CreateCommand();
            bounds.CommandText = boundsSql;
            await using var boundReader = await bounds.ExecuteReaderAsync(token);
            await boundReader.ReadAsync(token);
            var minimum = boundReader.GetInt64(0);
            var maximum = boundReader.GetInt64(1);
            var reset = cursor is not null
                && (cursor.InstanceId != instance
                    || cursor.EventId > maximum
                    || (minimum > 0 && cursor.EventId < minimum - 1));
            var after = reset || cursor is null ? Math.Max(0, minimum - 1) : cursor.EventId;
            await boundReader.DisposeAsync();
            await using var events = connection.CreateCommand();
            events.CommandText = eventsSql;
            events.Parameters.AddWithValue("$after", after);
            events.Parameters.AddWithValue("$limit", maximumEvents);
            await using var reader = await events.ExecuteReaderAsync(token);
            var result = new List<NormalizedTelemetryEvent>();
            while (await reader.ReadAsync(token))
            {
                JsonElement? payload = null;
                if (!reader.IsDBNull(5))
                {
                    using var document = JsonDocument.Parse(reader.GetString(5));
                    if (document.RootElement.ValueKind is not (JsonValueKind.Object or JsonValueKind.Null))
                        throw new InvalidDataException($"Telemetry event {reader.GetInt64(0)} payload must be an object.");
                    if (document.RootElement.ValueKind == JsonValueKind.Object)
                        payload = document.RootElement.Clone();
                }
                result.Add(new NormalizedTelemetryEvent(
                    reader.GetInt64(0), reader.GetInt64(1), reader.GetString(2),
                    DateTimeOffset.Parse(reader.GetString(3), CultureInfo.InvariantCulture),
                    reader.GetInt64(4), payload));
            }
            await reader.DisposeAsync();
            HashSet<long>? runIndexes = null;
            if (cursor is null || reset || cursor.MinimumEventId != minimum)
            {
                await using var retainedRuns = connection.CreateCommand();
                retainedRuns.CommandText = "SELECT DISTINCT run_index FROM telemetry_events;";
                await using var retainedReader = await retainedRuns.ExecuteReaderAsync(token);
                runIndexes = [];
                while (await retainedReader.ReadAsync(token))
                    runIndexes.Add(retainedReader.GetInt64(0));
            }
            var lastEventId = result.Count == 0 ? after : result[^1].EventId;
            var lastEventUtc = result.Count == 0
                ? (reset ? null : cursor?.LastEventUtc)
                : result[^1].OccurredUtc;
            return new TelemetryReadPage(
                instance,
                lastEventId,
                lastEventUtc,
                minimum,
                reset,
                lastEventId < maximum,
                runIndexes,
                result);
        }
    }
}
