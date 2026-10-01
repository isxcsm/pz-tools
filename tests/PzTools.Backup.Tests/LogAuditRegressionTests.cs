using Microsoft.Data.Sqlite;
using PzTools.Process.Telemetry;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class LogAuditRegressionTests
{
    [Fact]
    public async Task RunnerFailure_IsVisibleAsBackupErrorWithoutDuplicateProgressCard()
    {
        using var temp = new TempDirectory();
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, "backup-runner");
        await store.RecordAsync("backup-runner", 42, "runner.completed",
            """{"outcome":"Failed","failureCode":"invalid-arguments","failureMessage":"Invalid configuration"}""");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("backup-runner", "backup-runner", temp.Path, store.DatabasePath,
            TelemetryDatabaseKind.Process, true, LogsOnly: true));
        var views = new RevisionedViewStore();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        using var projector = new TelemetryProjectionHost(catalog, views, logInbox: inbox);
        await projector.ProjectOnceAsync(DateTimeOffset.UtcNow);
        var page = await inbox.ReadPageAsync(new(LogLevel.Warning, "Backup", "42", 0));
        var failure = Assert.Single(page.Entries);
        Assert.Equal(LogLevel.Error, failure.Level);
        Assert.Equal("Invalid configuration", LogDiagnostics.Parse(failure.PayloadJson)?.Message);
        Assert.Empty(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(true, true)]
    public async Task MissingInitialMetadataWaitsBrieflyButPersistentFailureIsReported(bool insertEmptyRow, bool hasWorkflow)
    {
        using var temp = new TempDirectory();
        var now = DateTimeOffset.UtcNow;
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, "archive-worker");
        await ExecuteAsync(store.DatabasePath, insertEmptyRow
            ? "UPDATE process_telemetry_info SET telemetry_instance_id=NULL;"
            : "DELETE FROM process_telemetry_info;");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("source", "archive-worker", temp.Path, store.DatabasePath,
            TelemetryDatabaseKind.Process, true,
            hasWorkflow ? new WorkflowOperation("export", "export", 1, OperationStatus.Running, now) : null));
        var views = new RevisionedViewStore();
        using var projector = new TelemetryProjectionHost(catalog, views, initialReadGrace: TimeSpan.FromSeconds(2));
        await projector.ProjectOnceAsync(now);
        Assert.Equal(TelemetryHealth.Waiting, Health(views));
        Assert.Empty(Logs(views));

        await projector.ProjectOnceAsync(now.AddSeconds(3));
        Assert.Equal(TelemetryHealth.Unreadable, Health(views));
        var failure = Assert.Single(Logs(views));
        var details = LogDiagnostics.Parse(failure.PayloadJson);
        Assert.Equal("telemetry-read-failed", details?.FailureCode);
        Assert.Equal("telemetry-read", details?.Phase);
        Assert.Equal(store.DatabasePath, details?.Path);
        Assert.Contains("not initialized", details!.Message);
        await projector.ProjectOnceAsync(now.AddSeconds(4));
        Assert.Single(Logs(views));
    }

    [Fact]
    public async Task MetadataThatFinishesInitializingDoesNotLeaveAnError()
    {
        using var temp = new TempDirectory();
        var now = DateTimeOffset.UtcNow;
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, "restore-worker");
        await ExecuteAsync(store.DatabasePath, "UPDATE process_telemetry_info SET telemetry_instance_id=NULL;");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("source", "restore-worker", temp.Path, store.DatabasePath,
            TelemetryDatabaseKind.Process, true,
            new WorkflowOperation("restore", "restore", 1, OperationStatus.Running, now)));
        var views = new RevisionedViewStore();
        using var projector = new TelemetryProjectionHost(catalog, views);
        await projector.ProjectOnceAsync(now);
        Assert.Equal(TelemetryHealth.Waiting, Health(views));
        store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, "restore-worker");
        await store.RecordAsync("restore-worker", 1, "run.started");
        await projector.ProjectOnceAsync(now.AddMilliseconds(100));
        Assert.Equal(TelemetryHealth.Healthy, Health(views));
        Assert.Empty(Logs(views));
    }

    [Theory]
    [InlineData("UPDATE process_telemetry_info SET telemetry_instance_id='not-a-guid';")]
    [InlineData("UPDATE telemetry_events SET payload_json='{';")]
    [InlineData("UPDATE telemetry_events SET payload_json='[]';")]
    [InlineData("UPDATE telemetry_events SET occurred_utc='invalid-date';")]
    public async Task InvalidSourceDoesNotStopHealthySourcesAndIncludesDiagnosticDetails(string corruption)
    {
        using var temp = new TempDirectory();
        var bad = await ProcessTelemetryStore.CreateForIdentityAsync(temp.GetPath("bad"), "fixture");
        var good = await ProcessTelemetryStore.CreateForIdentityAsync(temp.GetPath("good"), "fixture");
        await bad.RecordAsync("fixture", 1, "run.failed");
        await good.RecordAsync("fixture", 2, "run.failed", "{\"failureCode\":\"fixture-failure\"}");
        await ExecuteAsync(bad.DatabasePath, corruption);
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("a-bad", "fixture", temp.GetPath("bad"), bad.DatabasePath, TelemetryDatabaseKind.Process, true));
        catalog.Register(new("z-good", "fixture", temp.GetPath("good"), good.DatabasePath, TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        using var projector = new TelemetryProjectionHost(catalog, views);
        await projector.ProjectOnceAsync();
        var health = views.ReadIfChanged<TelemetrySourcesView>(ViewKey.TelemetrySources, 0).Snapshot!.Sources;
        Assert.Equal(TelemetryHealth.Unreadable, health.Single(x => x.SourceId == "a-bad").Health);
        Assert.Equal(TelemetryHealth.Healthy, health.Single(x => x.SourceId == "z-good").Health);
        Assert.Contains(Logs(views), item => item.SourceId == "z-good" && item.EventName == "run.failed");
        var error = Assert.Single(Logs(views), item => item.SourceId == "a-bad");
        Assert.Equal("telemetry-read-failed", LogDiagnostics.Parse(error.PayloadJson)?.FailureCode);
        Assert.Equal(bad.DatabasePath, LogDiagnostics.Parse(error.PayloadJson)?.Path);
    }

    [Fact]
    public async Task MetadataLostAfterSuccessfulReadIsAnImmediateError()
    {
        using var temp = new TempDirectory();
        var now = DateTimeOffset.UtcNow;
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, "fixture");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("source", "fixture", temp.Path, store.DatabasePath, TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        using var projector = new TelemetryProjectionHost(catalog, views);
        await projector.ProjectOnceAsync(now);
        Assert.Equal(TelemetryHealth.Healthy, Health(views));
        await ExecuteAsync(store.DatabasePath, "DELETE FROM process_telemetry_info;");
        await projector.ProjectOnceAsync(now.AddMilliseconds(100));
        Assert.Equal(TelemetryHealth.Unreadable, Health(views));
        Assert.Equal(LogLevel.Error, Assert.Single(Logs(views)).Level);
    }

    [Theory]
    [InlineData("tick.completed", "{\"outcome\":\"Failed\"}", LogLevel.Error, OperationStatus.Failed)]
    [InlineData("tick.completed", "{\"outcome\":\"Degraded\"}", LogLevel.Warning, OperationStatus.Degraded)]
    [InlineData("runner.completed", "{\"outcome\":\"Cancelled\"}", LogLevel.Warning, OperationStatus.Cancelled)]
    [InlineData("collector.completed", "{\"outcome\":\"Busy\"}", LogLevel.Warning, OperationStatus.Busy)]
    [InlineData("maintenance.completed", "{\"status\":2}", LogLevel.Error, OperationStatus.Failed)]
    [InlineData("maintenance.completed", "{\"status\":4}", LogLevel.Error, OperationStatus.Failed)]
    [InlineData("maintenance.completed", "{\"status\":\"Succeeded\",\"outcome\":\"Failed\"}", LogLevel.Error, OperationStatus.Failed)]
    public async Task CompletionOutcomeIsConsistentAcrossLogsAndOperationCards(
        string eventName, string payload, LogLevel level, OperationStatus status)
    {
        using var temp = new TempDirectory();
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, "fixture");
        await store.RecordAsync("fixture", 1, eventName, payload);
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("source", "fixture", temp.Path, store.DatabasePath, TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        await new TelemetryProjectionHost(catalog, views).ProjectOnceThenCloseAsync();
        Assert.Equal(level, Assert.Single(Logs(views)).Level);
        Assert.Equal(status, Assert.Single(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations).Status);
    }

    private static TelemetryHealth Health(RevisionedViewStore views) =>
        Assert.Single(views.ReadIfChanged<TelemetrySourcesView>(ViewKey.TelemetrySources, 0).Snapshot!.Sources).Health;

    private static IReadOnlyList<LogEntryView> Logs(RevisionedViewStore views) =>
        views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries;

    private static async Task ExecuteAsync(string path, string sql)
    {
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = path, Pooling = false }.ToString());
        await connection.OpenAsync();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync();
    }
}
