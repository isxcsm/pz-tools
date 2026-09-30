using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;

namespace PzTools.Scheduling;

public sealed record RuntimeAdmissionSelection(bool Enabled, BackupTickAdmission? Admission);

/// <summary>Single scheduler-process owner of the active clock. Persists only checkpoints and boundaries.</summary>
public sealed class RuntimeScheduleController(SchedulerDatabase database, RuntimeSnapshotStore runtime,
    TimeProvider? timeProvider = null, TimeSpan? linkGrace = null)
{
    /// <summary>How long the game may be unobservable before backups stop waiting for it.</summary>
    public static readonly TimeSpan DefaultLinkGrace = TimeSpan.FromSeconds(90);
    private const string FallbackPrefix = "runtime-fallback:";
    private readonly TimeProvider time = timeProvider ?? TimeProvider.System;
    private readonly TimeSpan grace = linkGrace ?? DefaultLinkGrace;
    private ActiveTimeScheduleState? state;
    private long lastPersist;
    private string? lastBoundary;
    private bool recovering;
    private long? unusableSince;
    public RuntimeObservation Observation => runtime.Read();
    /// <summary>A backup admitted without the game's cooperation: wall-clock timing, files as they are on disk.</summary>
    public static bool IsFallback(BackupTickAdmission admission) =>
        admission.AdmissionId.StartsWith(FallbackPrefix, StringComparison.Ordinal);

    public async Task<RuntimeAdmissionSelection> PrepareAsync(DateTimeOffset now, TimeSpan lead, CancellationToken token)
    {
        var storage = await database.ReadRuntimeScheduleAsync(token);

        // Apply/discard pending file-derived commands before reading the current generation.
        var oneShot = await database.PrepareBackupTickAsync(now, token, lead);
        var control = await database.ReadBackupStateIfChangedAsync(-1, token);
        var observation = CommittedObservation(storage);
        if (oneShot?.RuntimeTicket is { IsDeath: true } death)
        {
            bool valid = observation.IsFresh && observation.Snapshot is { } live && death.MatchesDeath(live)
                && StringComparer.OrdinalIgnoreCase.Equals(live.SavePath, oneShot.Target.SourcePath);
            return new(true, valid ? oneShot : null);
        }
        if (!storage.Enabled) { state = null; return new(false, null); }
        if (state is null)
        {
            recovering = storage.Checkpoint?.AttemptId is not null;
            // A fallback deadline belongs to the scheduler run that observed the outage.
            state = storage.Checkpoint is { } saved ? saved with { Anchored = false, FallbackDueUtc = null }
                : new(control.Generation, (long)control.Interval.TotalMilliseconds, (long)control.Interval.TotalMilliseconds);
        }
        if (recovering && observation.IsFresh && observation.Snapshot is { } recovered)
        {
            string identity = $"{observation.StreamEpoch}/{recovered.ProcessSession}/{recovered.ObserverEpoch}/{recovered.WorldSession}/{recovered.ClockEpoch}";
            if (state.Generation == control.Generation && state.AttemptId is not null
                && (state.ClockIdentity != identity || state.EligibilityEpoch != recovered.EligibilityEpoch
                    || !recovered.IsWorldReady || recovered.Pause != GamePause.Running))
                state = ActiveTimeSchedulePolicy.Complete(state, ScheduleDisposition.CompletionUnknown);
            recovering = false;
        }
        state = ActiveTimeSchedulePolicy.Advance(state, observation, control.AutomaticEnabled,
            control.Generation, (long)control.Interval.TotalMilliseconds);
        state = ApplyLinkFallback(state, observation, control, now);
        if (oneShot is not null)
        {
            bool valid = observation.IsFresh && observation.Snapshot?.IsWorldReady == true
                && StringComparer.OrdinalIgnoreCase.Equals(observation.Snapshot.SavePath, oneShot.Target.SourcePath);
            return new(true, valid ? oneShot : null); // Death-triggered policy remains separate from the periodic clock.
        }
        BackupTickAdmission? admission = null;
        if (state.Hold == ScheduleHold.None && control.CurrentTarget is not null
            && state.RemainingMilliseconds <= lead.TotalMilliseconds && observation.Snapshot is { } sample
            && StringComparer.OrdinalIgnoreCase.Equals(sample.SavePath, control.CurrentTarget.SourcePath))
        {
            state = state with { AttemptId = state.AttemptId ?? Guid.NewGuid().ToString("N") };
            var ticket = new RuntimeSaveTicket(sample.ProcessSession, sample.ObserverEpoch, sample.WorldSession,
                sample.ClockEpoch, sample.EligibilityEpoch,
                checked(sample.ActiveMilliseconds + Math.Max(0, state.RemainingMilliseconds)), 1, state.AttemptId);
            admission = new($"runtime:{control.Generation}:{state.Slot}:{state.AttemptId}", BackupAdmissionKind.Periodic,
                control.CurrentTarget, control.RepositoryPath, now.AddMilliseconds(Math.Max(0, state.RemainingMilliseconds)),
                control.Generation, null, ticket);
        }
        if (state.FallbackDueUtc is { } fallbackDue && fallbackDue <= now + lead
            && await database.ReadFileDerivedTargetAsync(token) is { } fallbackTarget)
            admission = new($"{FallbackPrefix}{control.Generation}:{state.Slot}", BackupAdmissionKind.Periodic,
                fallbackTarget, control.RepositoryPath, fallbackDue, control.Generation, null);
        string boundary = $"{state.Generation}/{state.WorldSession}/{state.ClockIdentity}/{state.EligibilityEpoch}/{state.Hold}/{state.AttemptId}/{state.FallbackDueUtc:O}";
        if (boundary != lastBoundary || time.GetElapsedTime(lastPersist).TotalSeconds >= 10)
        {
            await database.WriteRuntimeCheckpointAsync(state, token);
            lastPersist = time.GetTimestamp(); lastBoundary = boundary;
        }
        return new(true, admission);
    }

    // Waiting for a game that cannot be observed would stop backups for good (a game update, a
    // blocked helper). After a grace period they follow the wall clock instead, and return to
    // game time as soon as the game can be read again.
    private ActiveTimeScheduleState ApplyLinkFallback(ActiveTimeScheduleState current, RuntimeObservation observation,
        BackupSchedulerState control, DateTimeOffset now)
    {
        long interval = (long)control.Interval.TotalMilliseconds;
        if (!observation.IsLinkUnusable || !control.AutomaticEnabled)
        {
            if (!observation.IsLinkUnusable) unusableSince = null;
            return current.FallbackDueUtc is not { } due ? current : current with { FallbackDueUtc = null, Anchored = false,
                RemainingMilliseconds = Math.Clamp((long)(due - now).TotalMilliseconds, 0, interval) };
        }
        unusableSince ??= time.GetTimestamp();
        if (current.FallbackDueUtc is not null || time.GetElapsedTime(unusableSince.Value) < grace) return current;
        return current with { FallbackDueUtc = now.AddMilliseconds(Math.Clamp(current.RemainingMilliseconds, 0, interval)) };
    }

    /// <summary>Moves a wall-clock fallback backup to its next slot; a busy repository keeps it due.</summary>
    public async Task FinishFallbackAsync(BackupTickAdmission admission, bool workerStarted,
        PzTools.Process.Contracts.ProcessOutcome outcome, DateTimeOffset now, CancellationToken token = default)
    {
        if (state?.FallbackDueUtc is null || admission.AdmissionId != $"{FallbackPrefix}{state.Generation}:{state.Slot}") return;
        if (!workerStarted && outcome == PzTools.Process.Contracts.ProcessOutcome.Busy) return;
        state = state with { Slot = state.Slot + 1, FallbackDueUtc = BackupScheduleTiming.NextDue(
            admission.ScheduledUtc, TimeSpan.FromMilliseconds(state.IntervalMilliseconds), now) };
        await database.WriteRuntimeCheckpointAsync(state, token);
        lastPersist = time.GetTimestamp(); lastBoundary = null;
    }

    private RuntimeObservation CommittedObservation(RuntimeScheduleStorage storage)
    {
        var observation = runtime.Read();
        if (storage.Facts is null || storage.Facts.AuthorityEpoch != observation.AuthorityEpoch
            || storage.Facts.StateRevision < observation.StateRevision
            || storage.Facts.SemanticKey != observation.SemanticKey)
            return RuntimeObservation.Unknown("state-transition-pending");
        return observation;
    }

    public async Task FinishAsync(BackupTickAdmission admission, WorkerInvocation? worker,
        ScheduleDisposition recoveredDisposition = ScheduleDisposition.Default, CancellationToken token = default)
    {
        if (admission.RuntimeTicket is null || admission.RuntimeTicket.IsDeath || state is null) return;
        var control = await database.ReadBackupStateIfChangedAsync(-1, token);
        if (control.Generation != admission.Generation || state.AttemptId != admission.RuntimeTicket.RequestId) return;
        var storage = await database.ReadRuntimeScheduleAsync(token);
        if (!storage.Enabled) return;
        state = ActiveTimeSchedulePolicy.Advance(state, CommittedObservation(storage), control.AutomaticEnabled,
            control.Generation, (long)control.Interval.TotalMilliseconds);
        var disposition = worker?.ScheduleDisposition ?? recoveredDisposition;
        // No valid worker result is not evidence of a completed or unstarted save.
        // Busy is explicitly pre-work; a failed/cancelled/malformed result must hold.
        if (disposition == ScheduleDisposition.Default)
            disposition = worker?.Outcome switch
            {
                PzTools.Process.Contracts.ProcessOutcome.Succeeded or PzTools.Process.Contracts.ProcessOutcome.NoChange
                    => ScheduleDisposition.Consume,
                // Busy and Skipped both mean no work was done.
                PzTools.Process.Contracts.ProcessOutcome.Busy or PzTools.Process.Contracts.ProcessOutcome.Skipped
                    => ScheduleDisposition.Preserve,
                _ => ScheduleDisposition.CompletionUnknown,
            };
        state = ActiveTimeSchedulePolicy.Complete(state, disposition);
        await database.WriteRuntimeCheckpointAsync(state, token);
        lastPersist = time.GetTimestamp(); lastBoundary = null;
    }
}