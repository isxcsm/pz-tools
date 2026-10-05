using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

var started = DateTimeOffset.UtcNow;
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    cancellation.Cancel();
};
// The maintenance runner passes its stop request on: the worker stops at its next safe point and closes its records
// as cancelled, instead of being ended outright with its workflow and stage left running.
using var stopRequest = ProcessStopSignal.Listen(cancellation);
long runIndex = 0;
RepositoryDatabase? ownedWorkflowRepository = null;
// Every option is read before any work, so a bad one is reported as such (exit 64), never as a failed cleanup.
Dictionary<string, string?> values;
string repository;
int? retainLatest, revisionBatch;
string? lane;
long sourceId, givenRunIndex = 0;
try
{
    values = Parse(args);
    givenRunIndex = OptionalLong(values, "--run-index", 0) ?? 0;
    repository = Required(values, "--repository");
    retainLatest = (int?)OptionalLong(values, "--retain-latest", 0, int.MaxValue);
    revisionBatch = (int?)OptionalLong(values, "--revision-batch", 1, int.MaxValue);
    lane = values.GetValueOrDefault("--lane");
    if (lane is not null && !MaintenanceLaneSignal.HeavyLanes.Contains(lane, StringComparer.Ordinal))
        throw new ArgumentException($"Unknown maintenance lane '{lane}'.");
    // The orphan lane covers every save; the others work on one.
    if (lane == "OrphanBackups") { _ = Required(values, "--saves-root"); sourceId = 0; }
    else sourceId = RequiredLong(values, "--source-id", 1);
    if (values.ContainsKey("--dispatch-lanes") && givenRunIndex == 0)
        throw new ArgumentException("--dispatch-lanes requires --run-index.");
}
catch (ArgumentException exception)
{
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "maintenance-worker", Math.Max(1, givenRunIndex), ProcessOutcome.Failed,
            started, "invalid-arguments", exception.Message)));
    return ProcessExitCodes.InvalidArguments;
}
try
{
    var configurationPath = values.GetValueOrDefault("--config");
    var configuration = ComponentConfiguration.Load(
        repository, "maintenance-worker", configurationPath,
        Path.Combine(PzToolsPathLayout.CreateDefault().DataRoot, "settings.toml"));
    var settings = MaintenanceWorkerOptions.Read(configuration);
    var options = new MaintenanceOptions(
        retainLatest ?? settings.RetainLatestRevisions,
        revisionBatch ?? settings.RevisionBatchSize,
        settings.WriterRetryDelayMs)
    {
        RevisionCompactionMaxDelayMinutes = settings.RevisionCompactionMaxDelayMinutes,
        Housekeeping = new RepositoryHousekeepingOptions(
            settings.HistoryRetentionDays, settings.HistoryMinimumRuns,
            settings.DatabaseCleanupBatchSize, settings.VacuumEnabled,
            settings.VacuumMinimumFreeMib, settings.VacuumMinimumFreePercent,
            settings.VacuumMaximumDatabaseMib),
        PackReclamation = new PackReclamationOptions(
            settings.PackReclamationEnabled, settings.PackReclamationSparsePercent,
            settings.PackReclamationMinimumMib, settings.PackReclamationMaximumCopyMib),
    };
    options.Validate();
    if (lane == "OrphanBackups")
    {
        var orphanRun = await OrphanBackupLane.RunAsync(repository,
            values["--saves-root"]!, values.GetValueOrDefault("--control-db"), configurationPath, options,
            cancellation.Token);
        Console.WriteLine(LaneResultJson(orphanRun.RunIndex, orphanRun.Outcome, started, orphanRun.Result));
        return ProcessExitCodes.FromOutcome(orphanRun.Outcome);
    }
    runIndex = givenRunIndex;
    if (lane is not null)
    {
        var laneRun = await MaintenanceLanePipeline.RunLaneAsync(
            repository, sourceId, lane, options,
            values.GetValueOrDefault("--control-db"), configurationPath, cancellation.Token);
        Console.WriteLine(LaneResultJson(laneRun.RunIndex, laneRun.Outcome, started, laneRun.Result));
        return ProcessExitCodes.FromOutcome(laneRun.Outcome);
    }
    if (values.ContainsKey("--dispatch-lanes"))
    {
        var dispatched = await MaintenanceLanePipeline.DispatchAsync(
            repository, sourceId, runIndex, options,
            values.GetValueOrDefault("--control-db"), configurationPath, cancellation.Token);
        var dispatchOutcome = dispatched.Lanes.Any(item => item.Status == "Failed")
            ? ProcessOutcome.Degraded : ProcessOutcome.Succeeded;
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<MaintenanceResult>.Success(
                "maintenance-worker", runIndex, dispatchOutcome, started, dispatched)));
        return ProcessExitCodes.FromOutcome(dispatchOutcome);
    }
    if (runIndex == 0)
    {
        runIndex = await new RunIndexAllocator(values.GetValueOrDefault("--control-db"))
            .AllocateAsync(cancellationToken: cancellation.Token);
        var reserving = await RepositoryDatabase.OpenExistingAsync(repository, cancellation.Token);
        await reserving.ReserveWorkflowAsync(
            "maintenance", sourceId, "maintenance-worker", null, runIndex, cancellation.Token);
        ownedWorkflowRepository = reserving;
    }
    async Task ObserveLaneAsync(MaintenanceLaneEvent lane, CancellationToken _)
    {
        await RecordTelemetryAsync(
            repository, lane.RunIndex,
            $"maintenance.{lane.Lane.ToLowerInvariant()}.{lane.Stage}",
            lane.Result is null ? null : System.Text.Json.JsonSerializer.Serialize(new
            {
                lane.Result.Status,
                lane.Result.AffectedItems,
                lane.Result.ElapsedMilliseconds,
                lane.Result.Detail,
            }),
            configurationPath);
    }
    var result = await new MaintenanceService().RunAsync(
        repository, sourceId, options, runIndex == 0 ? null : runIndex,
        ObserveLaneAsync, cancellation.Token);
    runIndex = result.RunIndex;
    var outcome = result.FilesThatCouldNotBeDeleted.Count == 0
        ? ProcessOutcome.Succeeded : ProcessOutcome.Degraded;
    await RecordTelemetryAsync(repository, runIndex, "maintenance.completed",
        System.Text.Json.JsonSerializer.Serialize(new { outcome, lanes = result.Lanes.Count }),
        configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<MaintenanceResult>.Success(
            "maintenance-worker", runIndex, outcome, started, result)));
    return ProcessExitCodes.FromOutcome(outcome);
}
catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
{
    // The stage that was running has been closed as cancelled where it ran; a workflow this worker reserved itself
    // is closed here. One reserved by a runner is the runner's to close.
    await TryCloseOwnedWorkflowAsync(ownedWorkflowRepository, runIndex, WorkflowStatus.Cancelled, "cancelled");
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "maintenance-worker", Math.Max(1, runIndex), ProcessOutcome.Cancelled,
            started, "cancelled", "The maintenance worker was asked to stop.")));
    return ProcessExitCodes.Cancelled;
}
catch (Exception exception)
{
    await TryCloseOwnedWorkflowAsync(ownedWorkflowRepository, runIndex, WorkflowStatus.Failed, "maintenance-failed");
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "maintenance-worker", Math.Max(1, runIndex), ProcessOutcome.Failed,
            started, "maintenance-failed", exception.Message)));
    return ProcessExitCodes.Failure;
}

// A lane that failed or was cancelled says so with an error, as the result contract requires of those outcomes; a
// success envelope carrying them is refused by every reader.
static string LaneResultJson(long run, ProcessOutcome outcome, DateTimeOffset started, MaintenanceLaneResult? result)
{
    const string component = "maintenance-lane-worker";
    var index = Math.Max(1, run);
    if (outcome is not (ProcessOutcome.Failed or ProcessOutcome.Cancelled))
        return ProcessResultJson.Serialize(
            ProcessResultEnvelope<MaintenanceLaneResult>.Success(component, index, outcome, started, result));
    var cancelled = outcome == ProcessOutcome.Cancelled;
    return ProcessResultJson.Serialize(ProcessResultEnvelope<MaintenanceLaneResult>.Failure(
        component, index, outcome, started, cancelled ? "cancelled" : "maintenance-lane-failed",
        result?.Detail is { Length: > 0 } detail ? detail
            : cancelled ? "The maintenance lane was cancelled." : "The maintenance lane failed."));
}

static async Task TryCloseOwnedWorkflowAsync(
    RepositoryDatabase? repository,
    long runIndex,
    WorkflowStatus status,
    string code)
{
    if (repository is null || runIndex <= 0) return;
    try
    {
        var workflow = await repository.ReadWorkflowAsync(runIndex);
        if (workflow.Status == WorkflowStatus.Running)
            await repository.CompleteWorkflowAsync(runIndex, "maintenance-worker", status, code);
    }
    catch
    {
        // Keeps the original outcome. The next recovery cleans up the orphaned workflow.
    }
}

static async Task RecordTelemetryAsync(
    string identity,
    long run,
    string eventName,
    string? payload,
    string? configurationPath)
{
    await BestEffortProcessTelemetry.TryRecordAsync(
        identity, "maintenance-worker", Math.Max(1, run), eventName, payload,
        configurationPath);
}

// --dispatch-lanes takes a value ("true") for compatibility with the runners that pass it.
static Dictionary<string, string?> Parse(string[] arguments) => CommandLine.Parse(arguments,
    ["--repository", "--source-id", "--run-index", "--retain-latest",
        "--revision-batch", "--config", "--control-db", "--dispatch-lanes", "--lane", "--saves-root"]);
static string Required(Dictionary<string, string?> values, string name) => CommandLine.Required(values, name);
static long RequiredLong(Dictionary<string, string?> values, string name, long minimum) =>
    CommandLine.Int64(Required(values, name), name, minimum);
static long? OptionalLong(Dictionary<string, string?> values, string name, long minimum,
    long maximum = long.MaxValue) =>
    CommandLine.OptionalInt64(values.GetValueOrDefault(name), name, minimum, maximum);
