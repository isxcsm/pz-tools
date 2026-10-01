using System.Text.Json;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

try
{
    var repository = Path.GetFullPath(CommandLine.Required(args, "--repository"));
    var mutexName = NamedMutexRunner.CreateName("MaintenanceDispatch", repository);
    var result = await NamedMutexRunner.TryRunAsync(
        mutexName, token => RunCoreAsync(args, token));
    if (result.Acquired) return result.Value;
    var runIndex = CommandLine.OptionalInt64(CommandLine.Optional(args, "--run-index"), "--run-index") ?? 1;
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Success(
            "maintenance-runner", Math.Max(1, runIndex), ProcessOutcome.Busy,
            DateTimeOffset.UtcNow, new { reason = "maintenance-dispatch-already-running" })));
    return ProcessExitCodes.FromOutcome(ProcessOutcome.Busy);
}
catch (Exception exception) when (exception is ArgumentException or FormatException or OverflowException)
{
    Console.Error.WriteLine(exception.Message);
    return ProcessExitCodes.InvalidArguments;
}

static async Task<int> RunCoreAsync(string[] args, CancellationToken cancellationToken)
{
var started = DateTimeOffset.UtcNow;
long? runIndex = null;
RepositoryDatabase? repositoryDatabase = null;
var ownsWorkflow = false;
try
{
    var repository = CommandLine.Required(args, "--repository");
    var sourceId = CommandLine.Int64(CommandLine.Required(args, "--source-id"), "--source-id");
    runIndex = CommandLine.OptionalInt64(CommandLine.Optional(args, "--run-index"), "--run-index");
    var runnerConfiguration = CommandLine.Optional(args, "--config");
    var workerConfiguration = CommandLine.Optional(args, "--worker-config");
    var workerDirectory = CommandLine.Optional(args, "--worker-directory") ?? AppContext.BaseDirectory;
    var worker = Path.Combine(Path.GetFullPath(workerDirectory), "PzTools.Maintenance.Cli.exe");
    var forwarded = CommandLine.Without(
        args, "--worker-directory", "--config", "--worker-config");
    if (!forwarded.Contains("--dispatch-lanes", StringComparer.Ordinal))
    {
        forwarded.Add("--dispatch-lanes");
        forwarded.Add("true");
    }

    if (runIndex is null)
    {
        repositoryDatabase = await RepositoryDatabase.OpenExistingAsync(repository);
        await repositoryDatabase.RecoverAbandonedWorkflowsAsync("maintenance-worker", sourceId);
        runIndex = await new RunIndexAllocator(
            CommandLine.Optional(args, "--control-db")).AllocateAsync();
        var workflow = await repositoryDatabase.ReserveWorkflowAsync(
            "maintenance", sourceId, "maintenance-worker", null, runIndex.Value);
        runIndex = workflow.RunIndex;
        ownsWorkflow = true;
        forwarded.Add("--run-index");
        forwarded.Add(runIndex.Value.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    if (workerConfiguration is not null)
    {
        forwarded.Add("--config");
        forwarded.Add(workerConfiguration);
    }

    var envelope = await new OneShotRunnerCoordinator().RunAsync(
        "maintenance-runner",
        "RepositoryAccess",
        repository,
        runIndex.Value,
        worker,
        forwarded,
        "maintenance-worker",
        runnerConfiguration,
        cancellationToken);
    if (ownsWorkflow)
    {
        await CompleteReservedWorkflowAsync(repositoryDatabase!, runIndex.Value, envelope);
    }
    Console.WriteLine(ProcessResultJson.Serialize(envelope));
    return ProcessExitCodes.FromOutcome(envelope.Outcome);
}
catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
{
    if (ownsWorkflow && repositoryDatabase is not null && runIndex is not null)
    {
        try
        {
            var cancelled = ProcessResultEnvelope<RunnerExecutionResult>.Failure(
                "maintenance-runner", runIndex.Value, ProcessOutcome.Cancelled,
                started, "backup-priority", "Maintenance yielded to a due backup.");
            await CompleteReservedWorkflowAsync(repositoryDatabase, runIndex.Value, cancelled);
        }
        catch { /* 원래 취소 결과를 보존합니다. 다음 실행에서 고아 workflow를 복구합니다. */ }
    }
    return ProcessExitCodes.FromOutcome(ProcessOutcome.Cancelled);
}
catch (Exception exception) when (
    exception is ArgumentException or FormatException or OverflowException)
{
    if (ownsWorkflow && repositoryDatabase is not null && runIndex is not null)
        await TryFailReservedWorkflowAsync(repositoryDatabase, runIndex.Value, "invalid-arguments");
    Console.Error.WriteLine(exception.Message);
    return ProcessExitCodes.InvalidArguments;
}
catch (Exception exception)
{
    if (ownsWorkflow && repositoryDatabase is not null && runIndex is not null)
    {
        await TryFailReservedWorkflowAsync(repositoryDatabase, runIndex.Value, "maintenance-runner-failed");
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Failure(
                "maintenance-runner", runIndex.Value, ProcessOutcome.Failed, started,
                "maintenance-runner-failed", exception.Message)));
    }
    else
    {
        Console.Error.WriteLine(JsonSerializer.Serialize(new
        {
            version = 1,
            component = "maintenance-runner",
            outcome = "BootstrapFailed",
            code = "run-allocation-failed",
            message = exception.Message,
        }));
    }
    return ProcessExitCodes.Failure;
}
}

static async Task CompleteReservedWorkflowAsync(
    RepositoryDatabase repository,
    long runIndex,
    ProcessResultEnvelope<RunnerExecutionResult> envelope)
{
    var workflow = await repository.ReadWorkflowAsync(runIndex);
    if (workflow.Status != WorkflowStatus.Running) return;
    var status = ToWorkflowStatus(envelope.Outcome);
    var stages = await repository.ReadWorkflowStagesAsync(runIndex);
    var runningStage = stages.SingleOrDefault(stage =>
        stage.Producer == "maintenance-worker" && stage.Status == WorkflowStatus.Running);
    if (runningStage is not null)
    {
        await repository.CompleteWorkflowStageAsync(
            runIndex, runningStage.Producer, status, envelope.Error?.Code);
    }
    await repository.CompleteWorkflowAsync(
        runIndex, "maintenance-worker", status, envelope.Error?.Code);
}

static async Task TryFailReservedWorkflowAsync(
    RepositoryDatabase repository,
    long runIndex,
    string code)
{
    try
    {
        var envelope = ProcessResultEnvelope<RunnerExecutionResult>.Failure(
            "maintenance-worker", runIndex, ProcessOutcome.Failed,
            DateTimeOffset.UtcNow, code, code);
        await CompleteReservedWorkflowAsync(repository, runIndex, envelope);
    }
    catch (Exception)
    {
    }
}

static WorkflowStatus ToWorkflowStatus(ProcessOutcome outcome) => outcome switch
{
    ProcessOutcome.Succeeded => WorkflowStatus.Succeeded,
    ProcessOutcome.NoChange => WorkflowStatus.NoChange,
    ProcessOutcome.Skipped => WorkflowStatus.Skipped,
    ProcessOutcome.Busy => WorkflowStatus.Busy,
    ProcessOutcome.Degraded => WorkflowStatus.Degraded,
    ProcessOutcome.Cancelled => WorkflowStatus.Cancelled,
    _ => WorkflowStatus.Failed,
};
