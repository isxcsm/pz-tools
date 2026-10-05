using System.Globalization;
using System.Text.Json;
using PzTools.GameExtensions;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Projections;

namespace PzTools.App.Core;

/// <summary>
/// Non-authoritative, durable runtime transitions. Heartbeat age and changing diagnostic samples
/// are context, not event identities; a newer sample in an unchanged state is written at most once
/// every <see cref="SampleInterval"/>. Call Observe from Publish; no disk I/O runs on that caller.
/// </summary>
public sealed class ExtensionRuntimeDiagnostics(string runtimeRoot, Func<LogInboxStore?>? inbox = null,
    TimeProvider? timeProvider = null)
{
    /// <summary>The least time between two entries that only carry a newer diagnostics sample.</summary>
    public static readonly TimeSpan SampleInterval = TimeSpan.FromSeconds(10);
    /// <summary>The event of an entry written because the extension's state changed.</summary>
    public const string ChangedEvent = "extension.runtime.changed";
    /// <summary>The event of an entry written only for a newer diagnostics sample, in an unchanged state.</summary>
    public const string SampleEvent = "extension.runtime.sample";

    private sealed record Identity(RuntimeExtensionState State, string ProcessSession, string? WorldSession,
        string? Generation, long AppliedRevision, long RequestedRevision, string? Reason);
    /// <summary>What the last entry for a module said, and when it was written.</summary>
    private sealed record Written(Identity? Identity, string? Diagnostics, DateTimeOffset At);

    private readonly object gate = new();
    private readonly Guid instance = Guid.NewGuid();
    private readonly TimeProvider time = timeProvider ?? TimeProvider.System;
    // Each module has its own history of transitions; one module changing state is not news about another.
    private readonly Dictionary<string, Written> previous = new(StringComparer.Ordinal);
    private long sequence;
    private Task pending = Task.CompletedTask;
    private LogInboxStore? fallbackInbox;

    /// <summary>
    /// Queues only identity transitions. Supply the AppHost's existing inbox to share its configured
    /// recording level, retention and view cache; standalone callers use runtimeRoot/logs.db.
    /// </summary>
    public void Observe(RuntimeExtensionStatus? status) => Observe(ExtensionIds.VehicleDrivetrain, status);

    public void Observe(string extensionId, RuntimeExtensionStatus? status)
    {
        try
        {
            var identity = status is null ? null : new Identity(status.State, status.ProcessSession,
                status.WorldSession, status.Generation, status.AppliedRevision, status.RequestedRevision, status.Reason);
            lock (gate)
            {
                // No runtime data at startup is not a failure. Losing known data is informational.
                bool observed = previous.TryGetValue(extensionId, out var last);
                if (!observed && status is null) return;
                var occurred = time.GetUtcNow();
                bool changed = !observed || last!.Identity != identity;
                // With diagnostics on, every status carries the game's latest driving sample, but steady driving
                // changes no state. A sample entry now and then shows it on the Logs page without flooding it.
                var reading = SampleKey(status?.Diagnostics);
                bool sample = !changed && reading is { Length: > 0 }
                    && reading != last!.Diagnostics && occurred - last.At >= SampleInterval;
                if (!changed && !sample) return;
                previous[extensionId] = new(identity, reading, occurred);
                var eventId = ++sequence;
                var before = pending;
                pending = Task.Run(async () =>
                {
                    try
                    {
                        await before.ConfigureAwait(false);
                        await WriteAsync(extensionId, status, eventId, occurred, sample).ConfigureAwait(false);
                    }
                    catch (Exception)
                    {
                        // Do not retry every heartbeat or recursively log a failed logging operation.
                        // A later state transition may try the sink again; runtime/UI state is untouched.
                    }
                });
            }
        }
        catch (Exception)
        {
            // Diagnostics cannot invalidate a committed preference or prevent publishing its status.
        }
    }

    // The sample without its age, which grows while the sample stays the same: a vehicle standing still, or left, keeps
    // its last sample, and only a sample that changed is news.
    private static string? SampleKey(string? diagnostics) => diagnostics is null ? null
        : System.Text.RegularExpressions.Regex.Replace(diagnostics, @"(^|;)sample_age_ms=[^;]*", "");

    /// <summary>Waits for transitions already observed; failures never propagate to UI or shutdown.</summary>
    public Task FlushAsync()
    {
        lock (gate) return pending;
    }

    private async Task WriteAsync(string extensionId, RuntimeExtensionStatus? status, long eventId, DateTimeOffset occurred,
        bool sample)
    {
        var sink = inbox?.Invoke();
        if (sink is null)
        {
            // A supplied but not-yet-ready AppHost inbox must not create a second cache/policy owner.
            if (inbox is not null) return;
            sink = fallbackInbox ??= await LogInboxStore.CreateOrOpenAsync(
                Path.Combine(runtimeRoot, "logs.db")).ConfigureAwait(false);
        }
        // A sample repeats a state already recorded at its own level; a warning every ten seconds would only bury it.
        var level = sample ? LogLevel.Information : Severity(status);
        var state = status?.State.ToString() ?? "Unavailable";
        var reason = status?.Reason ?? (status is null ? "runtime-status-unavailable" : null);
        var payload = JsonSerializer.Serialize(new
        {
            extensionId,
            state,
            reason,
            failureCode = level >= LogLevel.Warning ? reason ?? state : null,
            phase = "extension-runtime",
            message = sample ? $"{extensionId} diagnostics sample while {state}." : $"{extensionId} runtime changed to {state}.",
            processSession = status?.ProcessSession,
            worldSession = status?.WorldSession,
            generation = status?.Generation,
            appliedRevision = status?.AppliedRevision ?? -1,
            requestedRevision = status?.RequestedRevision ?? -1,
            controlReady = status?.ControlReady ?? false,
            moduleVersion = status?.ModuleVersion,
            moduleHash = status?.ModuleHash,
            appliedVehicleOptions = status?.AppliedVehicleOptions is { } options ? new
            {
                torqueEnabled = options.TorqueEnabled,
                reverseEnabled = options.ReverseEnabled,
                steeringEnabled = options.SteeringEnabled,
                areaLightEnabled = options.AreaLightEnabled,
            } : null,
            diagnostics = status?.Diagnostics,
        });
        await sink.AppendAsync([new LogEntryView(
            $"extension-runtime:{instance:N}:{eventId.ToString(CultureInfo.InvariantCulture)}",
            "game-extensions:" + (extensionId.StartsWith("pztools.", StringComparison.Ordinal) ? extensionId["pztools.".Length..] : extensionId), instance, eventId, occurred, level,
            "game-extensions", 0, sample ? SampleEvent : ChangedEvent, payload)]).ConfigureAwait(false);
    }

    private static LogLevel Severity(RuntimeExtensionStatus? status)
    {
        if (status is null) return LogLevel.Information;
        // Leaving the world, loading another, closing the app or the game: the extension steps aside
        // and comes back by itself. Nothing is wrong, and nothing for the user to look at.
        if (status.State is RuntimeExtensionState.Disabled or RuntimeExtensionState.Pending
            && status.Reason is "world-unavailable" or "world-changed" or "connection-ended" or "lease-expired"
                or "waiting-for-local-world" or "observer-disconnected" or "control-session-changed" or "host-retired")
            return LogLevel.Information;
        if (status.State == RuntimeExtensionState.Unsupported) return LogLevel.Warning;
        // Waiting for the game's restart after an update of the app is not a failure: the sidebar's card says what to
        // do, and the extension comes back with the game. A restart forced by a failure in the game still is one.
        if (status is { State: RuntimeExtensionState.RestartRequired, Reason: "bootstrap-update" }) return LogLevel.Information;
        if (status.State is RuntimeExtensionState.FaultedPassThrough or RuntimeExtensionState.RestartRequired)
            return LogLevel.Error;
        // A rejected update may leave the previous generation Active, so state alone is insufficient.
        if (status.State == RuntimeExtensionState.Active && !string.IsNullOrEmpty(status.Reason)) return LogLevel.Warning;
        if (status.Reason is { } reason && (reason.Contains("rejected", StringComparison.OrdinalIgnoreCase)
            || reason.Contains("failed", StringComparison.OrdinalIgnoreCase)
            || reason.Contains("invalid", StringComparison.OrdinalIgnoreCase)
            || reason.Contains("conflict", StringComparison.OrdinalIgnoreCase)
            || reason.Contains("unsupported", StringComparison.OrdinalIgnoreCase)
            || reason.Contains("not-accepted", StringComparison.OrdinalIgnoreCase)
            || reason.Contains("unavailable", StringComparison.OrdinalIgnoreCase)
            || reason.Equals("process-changed", StringComparison.OrdinalIgnoreCase)
            || reason.Contains("mismatch", StringComparison.OrdinalIgnoreCase))) return LogLevel.Warning;
        return LogLevel.Information;
    }
}
