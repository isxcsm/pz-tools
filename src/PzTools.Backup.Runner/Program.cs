using System.Text.Json;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

return await RunAsync(args);

static async Task<int> RunAsync(string[] arguments)
{
    using var cancellation = new CancellationTokenSource();
    Console.CancelKeyPress += (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        cancellation.Cancel();
    };
    // Cancelling a backup asks this runner to stop, and the runner asks its worker in turn: the worker records the
    // cancellation and the reserved workflow is closed as cancelled, instead of both being ended outright.
    using var stopRequest = ProcessStopSignal.Listen(cancellation);
    var started = DateTimeOffset.UtcNow;
    long? runIndex = null;
    RepositoryDatabase? repositoryDatabase = null;
    var ownsWorkflow = false;
    try
    {
        var repository = CommandLine.Required(arguments, "--repository");
        runIndex = CommandLine.OptionalInt64(CommandLine.Optional(arguments, "--run-index"), "--run-index");
        var runnerConfiguration = CommandLine.Optional(arguments, "--config");
        var workerConfiguration = CommandLine.Optional(arguments, "--worker-config");
        var workerDirectory = CommandLine.Optional(arguments, "--worker-directory") ?? AppContext.BaseDirectory;
        var worker = Path.Combine(Path.GetFullPath(workerDirectory), "PzTools.Backup.Cli.exe");
        var forwarded = CommandLine.Without(
            arguments, "--worker-directory", "--config", "--worker-config", "--control-db");

        if (runIndex is null)
        {
            repositoryDatabase = await RepositoryDatabase.CreateOrOpenAsync(repository);
            runIndex = await new RunIndexAllocator(
                CommandLine.Optional(arguments, "--control-db")).AllocateAsync();
            var workflow = await repositoryDatabase.ReserveWorkflowAsync(
                "backup", sourceId: null, "backup-worker", null, runIndex.Value);
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

        forwarded.Insert(0, "backup");
        var envelope = await new OneShotRunnerCoordinator().RunAsync(
            "backup-runner",
            "RepositoryAccess",
            repository,
            runIndex.Value,
            worker,
            forwarded,
            "backup-worker",
            runnerConfiguration,
            cancellation.Token);
        if (ownsWorkflow)
        {
            await CompleteReservedWorkflowAsync(
                repositoryDatabase!, runIndex.Value, "backup-worker", envelope);
        }

        Console.WriteLine(ProcessResultJson.Serialize(envelope));
        return ProcessExitCodes.FromOutcome(envelope.Outcome);
    }
    catch (Exception exception) when (
        exception is ArgumentException or FormatException or OverflowException)
    {
        if (ownsWorkflow && repositoryDatabase is not null && runIndex is not null)
        {
            await TryFailReservedWorkflowAsync(
                repositoryDatabase, runIndex.Value, "backup-worker", "invalid-arguments");
        }
        Console.Error.WriteLine(exception.Message);
        return ProcessExitCodes.InvalidArguments;
    }
    catch (Exception exception)
    {
        if (ownsWorkflow && repositoryDatabase is not null && runIndex is not null)
        {
            await TryFailReservedWorkflowAsync(
                repositoryDatabase, runIndex.Value, "backup-worker", "backup-runner-failed");
            Console.WriteLine(ProcessResultJson.Serialize(
                ProcessResultEnvelope<object>.Failure(
                    "backup-runner", runIndex.Value, ProcessOutcome.Failed, started,
                    "backup-runner-failed", exception.Message)));
        }
        else
        {
            Console.Error.WriteLine(JsonSerializer.Serialize(new
            {
                version = 1,
                component = "backup-runner",
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
    string owner,
    ProcessResultEnvelope<RunnerExecutionResult> envelope)
{
    var workflow = await repository.ReadWorkflowAsync(runIndex);
    if (workflow.Status != WorkflowStatus.Running) return;
    var status = ToWorkflowStatus(envelope.Outcome);
    var stages = await repository.ReadWorkflowStagesAsync(runIndex);
    var runningStage = stages.SingleOrDefault(stage =>
        stage.Producer == "backup-worker" && stage.Status == WorkflowStatus.Running);
    if (runningStage is not null)
    {
        await repository.CompleteWorkflowStageAsync(
            runIndex, runningStage.Producer, status, envelope.Error?.Code);
    }
    await repository.CompleteWorkflowAsync(
        runIndex, owner, status, envelope.Error?.Code);
}

static async Task TryFailReservedWorkflowAsync(
    RepositoryDatabase repository,
    long runIndex,
    string owner,
    string code)
{
    try
    {
        var envelope = ProcessResultEnvelope<RunnerExecutionResult>.Failure(
            owner, runIndex, ProcessOutcome.Failed, DateTimeOffset.UtcNow, code, code);
        await CompleteReservedWorkflowAsync(repository, runIndex, owner, envelope);
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
