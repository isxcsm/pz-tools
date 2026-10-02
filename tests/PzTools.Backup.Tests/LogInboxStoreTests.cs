using Microsoft.Data.Sqlite;
using PzTools.Projections;
using PzTools.Process.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class LogInboxStoreTests
{
    [Fact]
    public async Task ReplayAndAcknowledgmentKeepOneStableIndexAndDerivedBadgeCount()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("logs.db");
        var inbox = await LogInboxStore.CreateOrOpenAsync(path);
        var first = Entry("first", 101, LogLevel.Error, 1);
        var duplicateCause = Entry("summary", 101, LogLevel.Error, 2);
        var other = Entry("other", 102, LogLevel.Warning, 3);
        var information = Entry("info", 103, LogLevel.Information, 4);
        await inbox.AppendAsync([first, duplicateCause, other, information]);

        var initial = await inbox.ReadViewAsync(new LogProjectionOptions(LogLevel.Information, 100));
        Assert.Equal(2, initial.UnreadIssues);
        Assert.Equal([4L, 3L, 2L, 1L], initial.Entries.Select(item => item.LogIndex));
        Assert.Equal("run:101", initial.Entries.Single(item => item.EntryId == "first").IncidentKey);

        await inbox.AcknowledgeIssueAsync("run:101", long.MaxValue);
        var acknowledgedAt = DateTimeOffset.UtcNow;
        var acknowledged = await inbox.ReadViewAsync(new LogProjectionOptions(LogLevel.Error, 100));
        Assert.Equal(1, acknowledged.UnreadIssues);
        Assert.All(acknowledged.Entries.Where(item => item.RunIndex == 101),
            item => Assert.True(item.IsAcknowledged));

        var reopened = await LogInboxStore.CreateOrOpenAsync(path);
        await reopened.AppendAsync([first, duplicateCause, other, information]);
        var afterReplay = await reopened.ReadViewAsync(new LogProjectionOptions(LogLevel.Critical, 100));
        Assert.Empty(afterReplay.Entries);
        Assert.Equal(1, afterReplay.UnreadIssues); // Badge is independent of the visible filter.

        await reopened.AppendAsync([Entry("late-history", 101, LogLevel.Error, 5) with
        {
            OccurredUtc = acknowledgedAt.AddMinutes(-1),
        }]);
        var lateHistory = await reopened.ReadViewAsync(new LogProjectionOptions(LogLevel.Warning, 100));
        Assert.Equal(1, lateHistory.UnreadIssues);
        Assert.True(lateHistory.Entries.Single(item => item.EntryId == "late-history").IsAcknowledged);

        await reopened.AppendAsync([Entry("new-failure", 101, LogLevel.Error, 6) with
        {
            OccurredUtc = acknowledgedAt.AddMinutes(1),
        }]);
        var newFailure = await reopened.ReadViewAsync(new LogProjectionOptions(LogLevel.Warning, 100));
        Assert.Equal(2, newFailure.UnreadIssues);
        Assert.Equal(6, newFailure.Entries.Single(item => item.EntryId == "new-failure").LogIndex);
        Assert.False(newFailure.Entries.Single(item => item.EntryId == "new-failure").IsAcknowledged);

        await reopened.AcknowledgeAllAsync();
        var allAcknowledged = await reopened.ReadViewAsync(new LogProjectionOptions(LogLevel.Warning, 100));
        Assert.Equal(0, allAcknowledged.UnreadIssues);
        Assert.All(allAcknowledged.Entries, item => Assert.True(item.IsAcknowledged));
    }

    [Fact]
    public async Task MinimumLevelIncludesHigherSeveritiesAcrossPages()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        await inbox.AppendAsync([
            Entry("error", 1, LogLevel.Error, 1),
            Entry("warning", 2, LogLevel.Warning, 2),
            Entry("information-1", 3, LogLevel.Information, 3),
            Entry("information-2", 4, LogLevel.Information, 4),
        ]);

        var first = await inbox.ReadPageAsync(
            new LogPageQuery(LogLevel.Information, "All", "", 0, 2));
        Assert.Equal(4, first.TotalGroups);
        Assert.Equal(["information-2", "information-1"],
            first.Entries.Select(item => item.EntryId));

        var second = await inbox.ReadPageAsync(new LogPageQuery(
            LogLevel.Information, "All", "", 1, 2, first.SnapshotMaxLogIndex));
        Assert.Equal(["warning", "error"], second.Entries.Select(item => item.EntryId));

        var warningsAndAbove = await inbox.ReadPageAsync(
            new LogPageQuery(LogLevel.Warning, "All", "", 0, 2));
        Assert.Equal(["warning", "error"],
            warningsAndAbove.Entries.Select(item => item.EntryId));
    }

    [Fact]
    public async Task PagesUseStableLogNumberOrderWhenOlderEventsArriveLater()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        await inbox.AppendAsync([Entry("information-earlier", 1, LogLevel.Information, 4)]);
        await inbox.AppendAsync([Entry("error-backfilled", 2, LogLevel.Error, 1)]);
        await inbox.AppendAsync([Entry("information-latest", 3, LogLevel.Information, 5)]);

        var first = await inbox.ReadPageAsync(
            new LogPageQuery(LogLevel.Information, "All", "", 0, 2));
        Assert.Equal(["information-latest", "error-backfilled"],
            LogDisplayGrouping.Group(first.Entries).Select(item => item.Primary.EntryId));
        Assert.Equal([3L, 2L], first.Entries.Select(item => item.LogIndex));

        var second = await inbox.ReadPageAsync(new LogPageQuery(
            LogLevel.Information, "All", "", 1, 2, first.SnapshotMaxLogIndex));
        Assert.Equal("information-earlier", Assert.Single(second.Entries).EntryId);
    }

    [Fact]
    public async Task PagesFilterWholeHistoryAndKeepIncidentEntriesTogether()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        await inbox.AppendAsync([
            Entry("run-1-cause", 1, LogLevel.Error, 1),
            Entry("run-1-summary", 1, LogLevel.Error, 2),
            Entry("run-2", 2, LogLevel.Error, 3),
            Entry("run-3", 3, LogLevel.Error, 4),
            Entry("run-4", 4, LogLevel.Error, 5),
        ]);

        var first = await inbox.ReadPageAsync(new LogPageQuery(LogLevel.Error, "All", "", 0, 2));
        Assert.Equal(4, first.TotalGroups);
        Assert.Equal(["run-4", "run-3"], first.Entries.Select(item => item.EntryId));
        var second = await inbox.ReadPageAsync(new LogPageQuery(LogLevel.Error, "All", "", 1, 2,
            first.SnapshotMaxLogIndex));
        Assert.Equal(4, second.TotalGroups);
        Assert.Equal(["run-2", "run-1-summary", "run-1-cause"],
            second.Entries.Select(item => item.EntryId));

        await inbox.AcknowledgeIssueAsync("run:1", long.MaxValue);
        var acknowledgedPage = await inbox.ReadPageAsync(new LogPageQuery(
            LogLevel.Error, "All", "", 1, 2, first.SnapshotMaxLogIndex));
        Assert.All(acknowledgedPage.Entries.Where(item => item.RunIndex == 1),
            item => Assert.True(item.IsAcknowledged));

        await inbox.AppendAsync([Entry("run-5", 5, LogLevel.Error, 6)]);
        var stable = await inbox.ReadPageAsync(new LogPageQuery(LogLevel.Error, "All", "", 1, 2,
            first.SnapshotMaxLogIndex));
        Assert.Equal(second.Entries.Select(item => item.EntryId),
            stable.Entries.Select(item => item.EntryId));
        var filtered = await inbox.ReadPageAsync(new LogPageQuery(LogLevel.Error, "Backup", "3", 0, 2));
        Assert.Equal(1, filtered.TotalGroups);
        Assert.Equal("run-3", Assert.Single(filtered.Entries).EntryId);
    }

    [Fact]
    public async Task RecordingLevelAffectsNewEntriesAndCountTrimsOldestHistory()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("logs.db");
        var inbox = await LogInboxStore.CreateOrOpenAsync(path);
        await inbox.AppendAsync([
            Entry("trace", 1, LogLevel.Trace, 1),
            Entry("information", 2, LogLevel.Information, 2),
            Entry("error", 3, LogLevel.Error, 3),
        ]);
        Assert.Equal(["error", "information"],
            (await inbox.ReadPageAsync(new LogPageQuery(LogLevel.Trace, "All", "", 0))).Entries
            .Select(item => item.EntryId).OrderBy(item => item));

        await inbox.ConfigureStorageAsync(LogLevel.Warning, 10000);
        var warningOnly = await inbox.ReadPageAsync(new LogPageQuery(LogLevel.Trace, "All", "", 0));
        Assert.Equal(2, warningOnly.Entries.Count); // Existing information is not destroyed.
        await inbox.AcknowledgeIssueAsync("run:3", long.MaxValue);
        await inbox.AppendAsync([Entry("new-info", 4, LogLevel.Information, 4)]);
        Assert.Equal(2, (await inbox.ReadPageAsync(new LogPageQuery(LogLevel.Trace, "All", "", 0)))
            .TotalGroups);

        await using (var connection = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            await connection.OpenAsync();
            await using var insert = connection.CreateCommand();
            insert.CommandText = """
                WITH RECURSIVE numbers(value) AS (
                    SELECT 1 UNION ALL SELECT value+1 FROM numbers WHERE value<10050)
                INSERT INTO log_entries(entry_key,source_id,telemetry_instance_id,event_id,
                    occurred_utc,level,component,run_index,event_name)
                SELECT 'bulk:'||value,'source','00000000-0000-0000-0000-000000000000',value,
                       printf('2026-09-24T01:%02d:%02d.%07d+00:00',
                           value/60%60,value%60,value),3,'backup-worker',value,'run.failed'
                FROM numbers;
                """;
            await insert.ExecuteNonQueryAsync();
        }
        await inbox.ConfigureStorageAsync(LogLevel.Warning, 10000);
        var page = await inbox.ReadPageAsync(new LogPageQuery(LogLevel.Warning, "All", "", 0));
        Assert.InRange(page.TotalGroups, 1, 10000);
        await using var check = new SqliteConnection($"Data Source={path};Pooling=False");
        await check.OpenAsync();
        await using var count = check.CreateCommand();
        count.CommandText = "SELECT COUNT(*) FROM log_entries;";
        Assert.Equal(10000L, (long)(await count.ExecuteScalarAsync())!);
        count.CommandText = "SELECT COUNT(*) FROM log_acknowledgments;";
        Assert.Equal(0L, (long)(await count.ExecuteScalarAsync())!);
    }

    [Fact]
    public async Task HistoricalTransientTelemetryIsIndexedOnceAndVisibleAfterRestart()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("archive-operation");
        var telemetry = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "archive-worker");
        await telemetry.RecordAsync("archive-worker", 42, "run.started");
        await telemetry.RecordAsync("archive-worker", 42, "file.capture.started",
            "{\"path\":\"map_meta.bin\"}");
        await telemetry.RecordAsync("archive-worker", 42, "run.failed", "{\"failureCode\":\"failed\"}");
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var catalog = new TelemetrySourceCatalog();
        var completed = DateTimeOffset.MinValue;
        catalog.Register(new TelemetrySourceRegistration(
            "archive-export-old", "archive-worker", identity, telemetry.DatabasePath,
            TelemetryDatabaseKind.Process, true,
            new WorkflowOperation("history", "archive", 0,
                OperationStatus.Succeeded, completed, completed),
            Transient: true, LogsOnly: true));
        var views = new RevisionedViewStore();
        using var projector = new TelemetryProjectionHost(catalog, views, logInbox: inbox);
        projector.ConfigureLogs(new LogProjectionOptions(LogLevel.Information, 100));
        await projector.ProjectOnceAsync();

        var original = views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!;
        Assert.Equal(1, original.UnreadIssues);
        Assert.Equal(2, original.Entries.Count);
        Assert.Empty(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Empty(catalog.Snapshot());
        Assert.Contains("archive-export-old", await inbox.ReadImportedSourcesAsync());

        var restartedViews = new RevisionedViewStore();
        using var restartedProjector = new TelemetryProjectionHost(new TelemetrySourceCatalog(), restartedViews,
            logInbox: await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db")));
        restartedProjector.ConfigureLogs(new LogProjectionOptions(LogLevel.Information, 100));
        await restartedProjector.ProjectOnceAsync();
        var restarted = restartedViews.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!;
        Assert.Equal(original.Entries.Select(item => item.LogIndex),
            restarted.Entries.Select(item => item.LogIndex));
        Assert.Equal(1, restarted.UnreadIssues);
    }

    [Fact]
    public async Task ReplayAddsMissingFailurePathWithoutChangingLogNumber()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var oldFailure = Entry("old-failure", 44, LogLevel.Error, 1) with
        {
            PayloadJson = """{"status":2,"failureCode":"UnstableFileException"}""",
        };
        await inbox.AppendAsync([oldFailure]);
        var original = await inbox.ReadViewAsync(new LogProjectionOptions());

        await inbox.AppendAsync([oldFailure with
        {
            PayloadJson = """{"status":2,"failureCode":"UnstableFileException","phase":"capture","path":"map_meta.bin"}""",
        }]);

        var enriched = await inbox.ReadViewAsync(new LogProjectionOptions());
        Assert.Single(enriched.Entries);
        Assert.Equal(original.Entries[0].LogIndex, enriched.Entries[0].LogIndex);
        Assert.Equal("map_meta.bin", LogDiagnostics.Parse(enriched.Entries[0].PayloadJson)?.Path);
    }

    [Fact]
    public async Task FailedCaptureIncludesLastStartedFileWhenLegacyPayloadHasNoPath()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("source");
        var telemetry = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "backup-worker");
        await telemetry.RecordAsync("backup-worker", 52, "file.capture.started",
            "{\"path\":\"map_meta.bin\"}");
        await telemetry.RecordAsync("backup-worker", 52, "run.failed",
            "{\"status\":2,\"failureCode\":\"UnstableFileException\"}");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "backup-worker", "backup-worker", identity, telemetry.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var views = new RevisionedViewStore();

        using var projector = new TelemetryProjectionHost(catalog, views, logInbox: inbox);
        projector.ConfigureRecordingLevel(LogLevel.Information);
        await projector.ProjectOnceAsync();

        var failed = Assert.Single(views.ReadIfChanged<LogsView>(ViewKey.Logs, 0)
            .Snapshot!.Entries, item => item.EventName == "run.failed");
        var diagnostics = LogDiagnostics.Parse(failed.PayloadJson);
        Assert.Equal("map_meta.bin", diagnostics?.Path);
        Assert.Equal("capture", diagnostics?.Phase);
        Assert.Equal("run.failed", Assert.Single((await inbox.ReadPageAsync(
            new LogPageQuery(LogLevel.Trace, "All", "", 0))).Entries).EventName);
    }

    [Fact]
    public async Task ExistingAcknowledgmentsAreMigratedWithTheirOriginalEventTime()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("logs.db");
        var inbox = await LogInboxStore.CreateOrOpenAsync(path);
        await inbox.AppendAsync([Entry("original", 77, LogLevel.Error, 1)]);
        await using (var connection = new SqliteConnection($"Data Source={path};Pooling=False"))
        {
            await connection.OpenAsync();
            await using var legacy = connection.CreateCommand();
            legacy.CommandText =
                """
                DROP TABLE log_acknowledgments;
                CREATE TABLE log_acknowledgments(
                    incident_key TEXT PRIMARY KEY,
                    acknowledged_through INTEGER NOT NULL
                ) STRICT;
                INSERT INTO log_acknowledgments VALUES('run:77',1);
                """;
            await legacy.ExecuteNonQueryAsync();
        }

        var migrated = await LogInboxStore.CreateOrOpenAsync(path);
        await migrated.AppendAsync([Entry("late", 77, LogLevel.Error, 2) with
        {
            OccurredUtc = Entry("original", 77, LogLevel.Error, 1)
                .OccurredUtc.AddMilliseconds(-1),
        }]);

        var view = await migrated.ReadViewAsync(new LogProjectionOptions());
        Assert.Equal(0, view.UnreadIssues);
        Assert.All(view.Entries, item => Assert.True(item.IsAcknowledged));
    }

    [Fact]
    public async Task LateImportedHistoryKeepsItsNumberButDisplaysByOccurrenceTime()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var newer = Entry("newer", 1, LogLevel.Error, 1) with
        {
            OccurredUtc = new DateTimeOffset(2026, 9, 24, 5, 17, 0, TimeSpan.Zero),
        };
        var importedLater = Entry("older", 2, LogLevel.Error, 2) with
        {
            OccurredUtc = new DateTimeOffset(2026, 9, 24, 4, 47, 0, TimeSpan.Zero),
        };
        await inbox.AppendAsync([newer]);
        await inbox.AppendAsync([importedLater]);

        var view = await inbox.ReadViewAsync(new LogProjectionOptions());

        Assert.Equal(["newer", "older"], view.Entries.Select(item => item.EntryId));
        Assert.Equal([1L, 2L], view.Entries.Select(item => item.LogIndex));
    }

    [Fact]
    public void WarningAndErrorRowsFromOneRunBecomeOneChronologicalIssue()
    {
        var first = Entry("cause", 101, LogLevel.Error, 1) with
        {
            PayloadJson = """{"failureCode":"UnstableFileException","path":"map_meta.bin"}""",
            IsAcknowledged = false,
            IncidentKey = "run:101",
        };
        var summary = Entry("summary", 101, LogLevel.Error, 2) with
        {
            EventName = "tick.completed",
            PayloadJson = """{"outcome":"Failed"}""",
            IsAcknowledged = false,
            IncidentKey = "run:101",
        };
        var laterRun = Entry("later-run", 102, LogLevel.Warning, 3) with
        {
            IsAcknowledged = false,
            IncidentKey = "run:102",
        };

        var groups = LogDisplayGrouping.Group([first, summary, laterRun]);

        Assert.Equal(2, groups.Count);
        Assert.Equal("later-run", groups[0].Primary.EntryId);
        Assert.Equal("cause", groups[1].Primary.EntryId);
        Assert.Equal(2, groups[1].Entries.Count);
        Assert.All(groups, group => Assert.True(group.IsUnread));
    }

    [Fact]
    public void ActivityContext_IdentifiesOldArchiveRowsAndBackupDetails()
    {
        var exportStarted = Entry("export-start", 1, LogLevel.Information, 1) with
        {
            Component = "archive-worker",
            SourceId = "archive-export-a1b2",
            EventName = "run.started",
        };
        var importFinished = exportStarted with
        {
            SourceId = "archive-import-c3d4",
            EventName = "run.committed",
            PayloadJson = """{"operation":"import"}""",
        };
        var backupFinished = exportStarted with
        {
            Component = "backup-worker",
            SourceId = "backup-worker",
            PayloadJson = """{"revision":83}""",
        };
        var changes = backupFinished with
        {
            EventName = "changes.planned",
            PayloadJson = """{"count":442,"mode":"Journal"}""",
        };

        Assert.Equal(LogActivityKind.ArchiveExport, LogActivityContext.From(exportStarted).Kind);
        Assert.Equal(LogActivityKind.ArchiveImport, LogActivityContext.From(importFinished).Kind);
        Assert.Equal(83, LogActivityContext.From(backupFinished).Revision);
        Assert.Equal(442, LogActivityContext.From(changes).ChangeCount);
        Assert.Equal(LogActivityKind.Restore, LogActivityContext.From(
            exportStarted with { Component = "restore-worker" }).Kind);
    }

    private static LogEntryView Entry(string id, long runIndex, LogLevel level, int second) =>
        new(id, "source", Guid.Empty, second,
            new DateTimeOffset(2026, 9, 24, 0, 0, second, TimeSpan.Zero),
            level, "backup-worker", runIndex, "run.failed", null);
}
