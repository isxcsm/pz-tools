using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.State;

namespace PzTools.Scheduling;

/// <summary>Periodic checks reuse the scheduler process, while preserving durable batches/outbox and collection exclusion.</summary>
public sealed class StateCheckPipeline
{
    private readonly StateCollector collector = new();
    private readonly StateReactor reactor = new();

    public async Task<WorkerInvocation> RunAsync(StateDatabase database, string savesRoot, long runIndex,
        CancellationToken cancellationToken = default)
    {
        if (runIndex <= 0) throw new ArgumentOutOfRangeException(nameof(runIndex));
        var scope = NamedMutexRunner.CreateName("StateCollection", Path.GetFullPath(database.DatabasePath));
        var result = await NamedMutexRunner.TryRunAsync(scope, async token =>
        {
            var producer = "state-reactor";
            try
            {
                // Read live settings each cycle, just as fresh Reactor processes did.
                var configuration = ComponentConfiguration.Load(database.DatabasePath, "state-reactor", null,
                    Path.Combine(PzToolsPathLayout.CreateDefault().DataRoot, "settings.toml"));
                var options = new StateReactorOptions(configuration.GetBoolean("state", "backup_on_death", false));
                if (await database.HasPendingBatchesAsync(token))
                    await reactor.RunAsync(database, options, token);
                producer = "state-collector";
                await collector.RunAsync(database, savesRoot, runIndex, token);
                await BestEffortProcessTelemetry.TryRecordAsync(database.DatabasePath, producer, runIndex, "collector.completed");
                producer = "state-reactor";
                await reactor.RunAsync(database, options, token);
                await BestEffortProcessTelemetry.TryRecordAsync(database.DatabasePath, producer, runIndex, "reactor.completed");
                await BestEffortProcessTelemetry.TryRecordAsync(database.DatabasePath, "state-runner", runIndex, "state-runner.completed");
                return new WorkerInvocation(true, ProcessOutcome.Succeeded);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception exception)
            {
                await BestEffortProcessTelemetry.TryRecordAsync(database.DatabasePath, producer, runIndex,
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
