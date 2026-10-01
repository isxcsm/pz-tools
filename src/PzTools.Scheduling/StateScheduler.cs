using PzTools.Process.Contracts;
using PzTools.Process.Telemetry;

namespace PzTools.Scheduling;

/// <param name="stateRunner">
/// Gets the run number lazily: a check that finds nothing changed takes no number, and then the tick
/// records nothing either.
/// </param>
public sealed class StateScheduler(
    SchedulerDatabase database,
    TimeSpan interval,
    Func<CancellationToken, Task<long>> allocateRunIndex,
    Func<Func<CancellationToken, Task<long>>, CancellationToken, Task<WorkerInvocation>> stateRunner,
    string? telemetryConfigurationPath = null)
{
    // Read from the database once; after that the due time lives here. Writing it every few seconds
    // bought nothing: the first checks after a start are forced anyway.
    private DateTimeOffset? nextDue;

    public async Task<StateTickResult> TickAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken = default,
        bool force = false)
    {
        bool due;
        if (nextDue is { } known)
            // Further ahead than one interval means the clock was set back: check now.
            due = known <= now || known > now.Add(interval);
        else
            due = await database.PrepareStateTickAsync(interval, now, cancellationToken);
        if (!due && !force)
        {
            return new StateTickResult(false, null, null);
        }

        long? runIndex = null;
        async Task<long> RunIndexAsync(CancellationToken token) => runIndex ??= await allocateRunIndex(token);
        WorkerInvocation result;
        try
        {
            result = await stateRunner(RunIndexAsync, cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            await BestEffortProcessTelemetry.TryRecordAsync(
                database.DatabasePath,
                "state-scheduler",
                await RunIndexAsync(cancellationToken),
                "tick.failed",
                FailureTelemetry.FromException(
                    "state-scheduler-failed", exception,
                    phase: "state-check",
                    operation: "state-schedule"),
                telemetryConfigurationPath);
            throw;
        }
        // A forced check does not move the periodic one.
        if (due) nextDue = now.Add(interval);
        // Nothing was recorded for an unchanged check, so there is nothing to report about it.
        if (runIndex is null && result.Outcome == ProcessOutcome.Succeeded)
            return new StateTickResult(true, null, result);
        var run = await RunIndexAsync(cancellationToken);
        await BestEffortProcessTelemetry.TryRecordAsync(
            database.DatabasePath,
            "state-scheduler",
            run,
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
        return new StateTickResult(true, run, result);
    }
}
