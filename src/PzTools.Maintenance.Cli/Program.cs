using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Telemetry;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

var started = DateTimeOffset.UtcNow;
long runIndex = 0;
RepositoryDatabase? ownedWorkflowRepository = null;
try
{
    var values = Parse(args);
    var repository = Required(values, "--repository");
    var configurationPath = values.GetValueOrDefault("--config");
    var configuration = ComponentConfiguration.Load(
        repository, "maintenance-worker", configurationPath,
        Path.Combine(PzToolsPathLayout.CreateDefault().DataRoot, "settings.toml"));
    var settings = MaintenanceWorkerOptions.Read(configuration);
    var options = new MaintenanceOptions(
        checked((int)(OptionalLong(values, "--retain-latest")
            ?? settings.RetainLatestRevisions)),
        checked((int)(OptionalLong(values, "--revision-batch")
            ?? settings.RevisionBatchSize)),
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
    if (values.GetValueOrDefault("--lane") == "OrphanBackups")
    {
        var orphanRun = await OrphanBackupLane.RunAsync(repository,
            Required(values, "--saves-root"), values.GetValueOrDefault("--control-db"), configurationPath, options);
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<MaintenanceLaneResult>.Success(
                "maintenance-lane-worker", Math.Max(1, orphanRun.RunIndex), orphanRun.Outcome,
                started, orphanRun.Result)));
        return ProcessExitCodes.FromOutcome(orphanRun.Outcome);
    }
    var sourceId = RequiredLong(values, "--source-id");
    runIndex = OptionalLong(values, "--run-index") ?? 0;
    if (sourceId <= 0) throw new ArgumentOutOfRangeException("--source-id");
    if (runIndex < 0) throw new ArgumentOutOfRangeException("--run-index");
    if (values.TryGetValue("--lane", out var lane) && lane is not null)
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
        if (runIndex == 0)
            throw new ArgumentException("--dispatch-lanes requires --run-index.");
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
        // 원래 실패 결과를 보존합니다. 다음 복구가 고아 workflow를 정리합니다.
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

static Dictionary<string, string?> Parse(string[] arguments)
{
    var allowed = new HashSet<string>(StringComparer.Ordinal)
    {
        "--repository", "--source-id", "--run-index", "--retain-latest",
        "--revision-batch", "--config", "--control-db", "--dispatch-lanes", "--lane", "--saves-root",
    };
    var values = new Dictionary<string, string?>(StringComparer.Ordinal);
    for (var index = 0; index < arguments.Length; index++)
    {
        var name = arguments[index];
        if (!allowed.Contains(name)) throw new ArgumentException($"Unknown option '{name}'.");
        if (!name.StartsWith("--", StringComparison.Ordinal) || ++index >= arguments.Length)
            throw new ArgumentException($"Option '{name}' requires a value.");
        values.Add(name, arguments[index]);
    }
    return values;
}
static string Required(Dictionary<string, string?> values, string name) =>
    values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
        ? value : throw new ArgumentException($"{name} is required.");
static long RequiredLong(Dictionary<string, string?> values, string name) =>
    long.Parse(Required(values, name), System.Globalization.CultureInfo.InvariantCulture);
static long? OptionalLong(Dictionary<string, string?> values, string name) =>
    values.TryGetValue(name, out var value) && value is not null
        ? long.Parse(value, System.Globalization.CultureInfo.InvariantCulture) : null;
