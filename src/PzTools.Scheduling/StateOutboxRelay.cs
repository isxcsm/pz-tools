using PzTools.Zomboid.State;

namespace PzTools.Scheduling;

public sealed class StateOutboxRelay
{
    public async Task RelayRuntimeAsync(StateDatabase state, SchedulerDatabase scheduler, string savesRoot, CancellationToken token = default)
    {
        foreach (var observation in await state.ReadRuntimeOutboxAsync(token))
        {
            var identity = observation.Snapshot is { } snapshot ? RuntimeSaveResolver.Resolve(snapshot, savesRoot) : null;
            var target = identity is null ? null : new BackupTarget(identity.SaveId, identity.SaveId, identity.SourcePath);
            await scheduler.ApplyRuntimeTransitionAsync(observation, target, token);
            await state.AcknowledgeRuntimeAsync(observation.StateRevision, token);
        }
    }

    public async Task<int> RelayAsync(
        StateDatabase stateDatabase,
        SchedulerDatabase schedulerDatabase,
        CancellationToken cancellationToken = default)
    {
        var count = 0;
        foreach (var message in await stateDatabase.ReadPendingOutboxAsync(cancellationToken))
        {
            var commandKind = message.Command switch
            {
                "ActivateTarget" => BackupTargetCommandKind.ActivateTarget,
                "FinalizeTarget" => BackupTargetCommandKind.FinalizeTarget,
                "ClearTarget" => BackupTargetCommandKind.ClearTarget,
                "RunOnceNow" => BackupTargetCommandKind.RunOnceNow,
                "SuspendAmbiguous" => BackupTargetCommandKind.SuspendAmbiguous,
                _ => throw new InvalidDataException($"Unknown scheduler command '{message.Command}'."),
            };
            var target = new BackupTarget(message.SaveId, message.SourceKey, message.SourcePath);
            await schedulerDatabase.EnqueueTargetCommandAsync(
                new BackupTargetCommand(
                    message.IdempotencyKey,
                    commandKind,
                    target,
                    message.TransitionId,
                    message.StateRunIndex),
                cancellationToken);
            await stateDatabase.AcknowledgeOutboxAsync(message.MessageId, cancellationToken);
            count++;
        }
        return count;
    }
}
