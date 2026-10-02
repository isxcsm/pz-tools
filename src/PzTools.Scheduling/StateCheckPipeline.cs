using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.State;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Scheduling;

/// <summary>Periodic checks reuse the scheduler process, while preserving durable batches/outbox and collection exclusion.</summary>
public sealed class StateCheckPipeline(Func<RuntimeObservation?>? runtime = null)
{
    private readonly StateCollector collector = new(new SaveDiscoveryLane(), new GameActivityLane(runtime), new CharacterStateLane());
    private readonly StateReactor reactor = new();
    // The observations of the last check that changed nothing, and the database as that check left it.
    private (bool Complete, IReadOnlyList<SaveObservation> Saves, string Stamp)? settled;

    public Task<WorkerInvocation> RunAsync(StateDatabase database, string savesRoot, long runIndex,
        CancellationToken cancellationToken = default)
    {
        if (runIndex <= 0) throw new ArgumentOutOfRangeException(nameof(runIndex));
        return RunAsync(database, savesRoot, _ => Task.FromResult(runIndex), cancellationToken);
    }

    /// <param name="runIndex">Called only when the check records something: an unchanged check takes no number.</param>
    public async Task<WorkerInvocation> RunAsync(StateDatabase database, string savesRoot,
        Func<CancellationToken, Task<long>> runIndex, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(runIndex);
        long? allocated = null;
        async Task<long> RunIndexAsync(CancellationToken token) => allocated ??= await runIndex(token);
        var scope = NamedMutexRunner.CreateName("StateCollection", Path.GetFullPath(database.DatabasePath));
        var result = await NamedMutexRunner.TryRunAsync(scope, async token =>
        {
            var producer = "state-reactor";
            try
            {
                // Read once, under the collection lock that every other state writer takes as well.
                var (stamp, pendingBatches) = await database.ReadDecisionStampAsync(token);
                if (pendingBatches)
                {
                    settled = null;
                    await reactor.RunAsync(database, token);
                }
                producer = "state-collector";
                var seen = await collector.ObserveAsync(savesRoot, token);
                // The same observations as a check that changed nothing, with nobody else having changed
                // the state since, would again change nothing. Writing a batch only to delete it would be
                // all this check did, every few seconds while the app sits in the tray.
                if (settled is { } last && last.Stamp == stamp
                    && last.Complete == seen.DiscoveryComplete && last.Saves.SequenceEqual(seen.Saves))
                    return new WorkerInvocation(true, ProcessOutcome.Succeeded);
                settled = null;
                var run = await RunIndexAsync(token);
                await database.WritePendingBatchAsync(new CollectionBatch(Guid.NewGuid().ToString("D"), run,
                    seen.StartedUtc, DateTimeOffset.UtcNow, seen.ElapsedMilliseconds, seen.DiscoveryComplete, seen.Saves), token);
                await BestEffortProcessTelemetry.TryRecordAsync(database.DatabasePath, producer, run, "collector.completed");
                producer = "state-reactor";
                var reaction = await reactor.RunAsync(database, token);
                if (reaction.Settled)
                    settled = (seen.DiscoveryComplete, seen.Saves, (await database.ReadDecisionStampAsync(token)).Stamp);
                await BestEffortProcessTelemetry.TryRecordAsync(database.DatabasePath, producer, run, "reactor.completed");
                await BestEffortProcessTelemetry.TryRecordAsync(database.DatabasePath, "state-runner", run, "state-runner.completed");
                return new WorkerInvocation(true, ProcessOutcome.Succeeded);
            }
            catch (OperationCanceledException) { settled = null; throw; }
            catch (Exception exception)
            {
                settled = null;
                await BestEffortProcessTelemetry.TryRecordAsync(database.DatabasePath, producer, await RunIndexAsync(token),
                    producer == "state-collector" ? "collector.failed" : "reactor.failed",
                    FailureTelemetry.FromException("state-check-failed", exception, phase: "state-check", operation: "state-check"));
                // A child-process failure was an outcome, not a fatal scheduler exception.
                // Retain that isolation; durable pending batches are recovered on the next tick.
                return new WorkerInvocation(true, ProcessOutcome.Failed, "state-check-failed");
            }
        }, cancellationToken);
        return result.Acquired ? result.Value! : new WorkerInvocation(false, ProcessOutcome.Busy, "state-collection-busy");
    }
}
