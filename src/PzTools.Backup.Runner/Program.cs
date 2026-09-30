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
    var started = DateTimeOffset.UtcNow;
    long? runIndex = null;
    RepositoryDatabase? repositoryDatabase = null;
    var ownsWorkflow = false;
    try
    {
        var repository = Value(arguments, "--repository", required: true)!;
        runIndex = ParseLong(Value(arguments, "--run-index", false));
        if (runIndex is <= 0) throw new ArgumentOutOfRangeException("--run-index");
        var runnerConfiguration = Value(arguments, "--config", false);
        var workerConfiguration = Value(arguments, "--worker-config", false);
        var workerDirectory = Value(arguments, "--worker-directory", false) ?? AppContext.BaseDirectory;
        var worker = Path.Combine(Path.GetFullPath(workerDirectory), "PzTools.Backup.Cli.exe");
        var forwarded = RemoveRunnerOptions(
            arguments, "--worker-directory", "--config", "--worker-config", "--control-db");

        if (runIndex is null)
        {
            repositoryDatabase = await RepositoryDatabase.CreateOrOpenAsync(repository);
            runIndex = await new RunIndexAllocator(
                Value(arguments, "--control-db", false)).AllocateAsync();
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
            runnerConfiguration);
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

static List<string> RemoveRunnerOptions(string[] arguments, params string[] optionNames)
{
    var names = new HashSet<string>(optionNames, StringComparer.Ordinal);
    var forwarded = new List<string>();
    for (var index = 0; index < arguments.Length; index++)
    {
        if (!names.Contains(arguments[index]))
        {
            forwarded.Add(arguments[index]);
            continue;
        }

        if (++index >= arguments.Length)
            throw new ArgumentException($"{arguments[index - 1]} requires a value.");
    }
    return forwarded;
}

static string? Value(string[] arguments, string name, bool required)
{
    var matches = arguments
        .Select((value, index) => (value, index))
        .Where(item => item.value == name)
        .Select(item => item.index)
        .ToArray();
    if (matches.Length > 1) throw new ArgumentException($"{name} may be specified only once.");
    if (matches.Length == 1 && matches[0] + 1 < arguments.Length)
        return arguments[matches[0] + 1];
    return required ? throw new ArgumentException($"{name} is required.") : null;
}

static long? ParseLong(string? value) => value is null
    ? null
    : long.Parse(value, System.Globalization.CultureInfo.InvariantCulture);
