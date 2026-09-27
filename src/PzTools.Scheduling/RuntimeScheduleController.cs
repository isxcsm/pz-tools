using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;

namespace PzTools.Scheduling;

public sealed record RuntimeAdmissionSelection(bool Enabled, BackupTickAdmission? Admission);

/// <summary>Single scheduler-process owner of the active clock. Persists only checkpoints and boundaries.</summary>
public sealed class RuntimeScheduleController(SchedulerDatabase database, RuntimeSnapshotStore runtime,
    TimeProvider? timeProvider = null)
{
    private readonly TimeProvider time = timeProvider ?? TimeProvider.System;
    private ActiveTimeScheduleState? state;
    private long lastPersist;
    private string? lastBoundary;
    private bool recovering;
    public RuntimeObservation Observation => runtime.Read();

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
            state = storage.Checkpoint is { } saved ? saved with { Anchored = false }
                : new(control.Generation, (long)control.Interval.TotalMilliseconds, (long)control.Interval.TotalMilliseconds);
        }
        if (recovering && observation.IsFresh && observation.Snapshot is { } recovered)
        {
            string identity = $"{observation.StreamEpoch}/{recovered.ProcessSession}/{recovered.ObserverEpoch}/{recovered.WorldSession}/{recovered.ClockEpoch}";
            if (state.Generation == control.Generation && state.AttemptId is not null
                && (state.ClockIdentity != identity || state.EligibilityEpoch != recovered.EligibilityEpoch
                    || !recovered.IsWorldReady || recovered.Pause != GamePause.Running))
                state = state with { CompletionUncertain = true };
            recovering = false;
        }
        state = ActiveTimeSchedulePolicy.Advance(state, observation, control.AutomaticEnabled,
            control.Generation, (long)control.Interval.TotalMilliseconds);
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
        string boundary = $"{state.Generation}/{state.WorldSession}/{state.ClockIdentity}/{state.EligibilityEpoch}/{state.Hold}/{state.AttemptId}";
        if (boundary != lastBoundary || time.GetElapsedTime(lastPersist).TotalSeconds >= 10)
        {
            await database.WriteRuntimeCheckpointAsync(state, token);
            lastPersist = time.GetTimestamp(); lastBoundary = boundary;
        }
        return new(true, admission);
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
                PzTools.Process.Contracts.ProcessOutcome.Busy => ScheduleDisposition.Preserve,
                _ => ScheduleDisposition.CompletionUnknown,
            };
        state = ActiveTimeSchedulePolicy.Complete(state, disposition);
        await database.WriteRuntimeCheckpointAsync(state, token);
        lastPersist = time.GetTimestamp(); lastBoundary = null;
    }
}