using System.Text.Json;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Telemetry;

namespace PzTools.Process.Hosting;

public sealed record RunnerExecutionResult(bool WorkerStarted, int? WorkerExitCode,
    string WorkerOutput, string WorkerError, bool AbandonedMutex);

public sealed class OneShotRunnerCoordinator(ChildProcessHost processHost)
{
    public OneShotRunnerCoordinator() : this(new ChildProcessHost()) { }

    public async Task<ProcessResultEnvelope<RunnerExecutionResult>> RunAsync(
        string component, string mutexScope, string identity, long runIndex,
        string workerExecutable, IReadOnlyList<string> workerArguments, string expectedWorkerComponent,
        string? telemetryConfigurationPath = null, CancellationToken cancellationToken = default)
    {
        if (runIndex <= 0) throw new ArgumentOutOfRangeException(nameof(runIndex));
        var started = DateTimeOffset.UtcNow;
        await BestEffortProcessTelemetry.TryRecordAsync(identity, component, runIndex, "runner.started",
            configurationPath: telemetryConfigurationPath);
        var mutex = await NamedMutexRunner.TryRunAsync(
            NamedMutexRunner.CreateName(mutexScope, Path.GetFullPath(identity)),
            token => processHost.RunAsync(workerExecutable, workerArguments, token), cancellationToken);
        if (!mutex.Acquired)
        {
            await BestEffortProcessTelemetry.TryRecordAsync(identity, component, runIndex, "runner.busy",
                configurationPath: telemetryConfigurationPath);
            return ProcessResultEnvelope<RunnerExecutionResult>.Success(component, runIndex,
                ProcessOutcome.Busy, started, new(false, null, "", "", false));
        }
        var child = mutex.Value!;
        var outcome = ProcessOutcome.Failed;
        var disposition = ScheduleDisposition.Default;
        var error = child.FailureCode;
        var message = child.StandardError;
        if (child.Started)
        {
            try
            {
                var envelope = ProcessResultValidator.Read<JsonElement>(child.StandardOutput,
                    expectedWorkerComponent, runIndex, child.ExitCode, child.StandardError);
                outcome = envelope.Outcome;
                disposition = envelope.ScheduleDisposition;
                error = envelope.Error?.Code;
                message = envelope.Error?.Message;
            }
            catch (ProcessResultValidationException exception)
            {
                error = exception.Code;
                message = exception.Message;
            }
        }
        await BestEffortProcessTelemetry.TryRecordAsync(identity, component, runIndex, "runner.completed",
            JsonSerializer.Serialize(new { outcome = outcome.ToString(), child.ExitCode,
                mutex.WasAbandoned, failureCode = error, failureMessage = message }), telemetryConfigurationPath);
        var result = outcome is ProcessOutcome.Failed or ProcessOutcome.Cancelled
            ? ProcessResultEnvelope<RunnerExecutionResult>.Failure(component, runIndex, outcome, started,
                error ?? "worker-failed", message ?? "Worker process failed.")
            : ProcessResultEnvelope<RunnerExecutionResult>.Success(component, runIndex, outcome, started,
                new(child.Started, child.ExitCode, child.StandardOutput, child.StandardError, mutex.WasAbandoned));
        return result with { ScheduleDisposition = disposition };
    }
}
