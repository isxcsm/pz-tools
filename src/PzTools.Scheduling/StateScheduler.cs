using PzTools.Process.Contracts;
using PzTools.Process.Telemetry;

namespace PzTools.Scheduling;

public sealed class StateScheduler(
    SchedulerDatabase database,
    TimeSpan interval,
    Func<CancellationToken, Task<long>> allocateRunIndex,
    Func<long, CancellationToken, Task<WorkerInvocation>> stateRunner,
    string? telemetryConfigurationPath = null)
{
    public async Task<StateTickResult> TickAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default,
        bool force = false)
    {
        var due = await database.PrepareStateTickAsync(interval, now, cancellationToken);
        if (!due && !force)
        {
            return new StateTickResult(false, null, null);
        }

        var runIndex = await allocateRunIndex(cancellationToken);
        WorkerInvocation result;
        try
        {
            result = await stateRunner(runIndex, cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            await BestEffortProcessTelemetry.TryRecordAsync(
                database.DatabasePath,
                "state-scheduler",
                runIndex,
                "tick.failed",
                FailureTelemetry.FromException(
                    "state-scheduler-failed", exception,
                    phase: "state-check",
                    operation: "state-schedule"),
                telemetryConfigurationPath);
            throw;
        }
        if (due)
            await database.AdvanceStateDueAsync(interval, now, CancellationToken.None);
        await BestEffortProcessTelemetry.TryRecordAsync(
            database.DatabasePath,
            "state-scheduler",
            runIndex,
            "tick.completed",
            System.Text.Json.JsonSerializer.Serialize(new
            {
                outcome = result.Outcome.ToString(),
                result.Started,
                result.FailureCode,
                failureOrigin = result.Outcome == ProcessOutcome.Failed
                    ? "state-runner" : null,
            }),
            telemetryConfigurationPath);
        return new StateTickResult(true, runIndex, result);
    }
}
