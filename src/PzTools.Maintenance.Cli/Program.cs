using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

var started = DateTimeOffset.UtcNow;
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
            values["--saves-root"]!, values.GetValueOrDefault("--control-db"), configurationPath, options);
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<MaintenanceLaneResult>.Success(
                "maintenance-lane-worker", Math.Max(1, orphanRun.RunIndex), orphanRun.Outcome,
                started, orphanRun.Result)));
        return ProcessExitCodes.FromOutcome(orphanRun.Outcome);
    }
    runIndex = givenRunIndex;
    if (lane is not null)
    {
        var laneRun = await MaintenanceLanePipeline.RunLaneAsync(
            repository, sourceId, lane, options,
            values.GetValueOrDefault("--control-db"), configurationPath);
        var laneIndex = Math.Max(1, laneRun.RunIndex);
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<MaintenanceLaneResult>.Success(
                "maintenance-lane-worker", laneIndex, laneRun.Outcome,
                started, laneRun.Result)));
        return ProcessExitCodes.FromOutcome(laneRun.Outcome);
    }
    if (values.ContainsKey("--dispatch-lanes"))
    {
        var dispatched = await MaintenanceLanePipeline.DispatchAsync(
            repository, sourceId, runIndex, options,
            values.GetValueOrDefault("--control-db"), configurationPath);
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
            .AllocateAsync();
        ownedWorkflowRepository = await RepositoryDatabase.OpenExistingAsync(repository);
        await ownedWorkflowRepository.ReserveWorkflowAsync(
            "maintenance", sourceId, "maintenance-worker", null, runIndex);
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
        ObserveLaneAsync);
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
catch (Exception exception)
{
    await TryFailOwnedWorkflowAsync(ownedWorkflowRepository, runIndex);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "maintenance-worker", Math.Max(1, runIndex), ProcessOutcome.Failed,
            started, "maintenance-failed", exception.Message)));
    return ProcessExitCodes.Failure;
}

static async Task TryFailOwnedWorkflowAsync(
    RepositoryDatabase? repository,
    long runIndex)
{
    if (repository is null || runIndex <= 0) return;
    try
    {
        var workflow = await repository.ReadWorkflowAsync(runIndex);
        if (workflow.Status == WorkflowStatus.Running)
            await repository.CompleteWorkflowAsync(
                runIndex, "maintenance-worker", WorkflowStatus.Failed,
                "maintenance-failed");
    }
    catch
    {
        // Keeps the original failure. The next recovery cleans up the orphaned workflow.
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
