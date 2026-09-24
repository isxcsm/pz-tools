using System.Text.Json;
using System.Xml.Linq;
using Microsoft.Data.Sqlite;
using PzTools.Process.Telemetry;
using PzTools.Projections;
using PzTools.Backup.Engine;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;

namespace PzTools.Backup.Tests;

public sealed class ProgressAuditRegressionTests
{
    [Fact]
    public void TechnicalDetailsUsesContentExpanderNotSettingsCardItemStyling()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "PzTools.sln"))) root = root.Parent;
        Assert.NotNull(root);
        var xaml = XDocument.Load(Path.Combine(root.FullName, "src", "PzTools.App", "LogsPage.xaml"));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        var expander = Assert.Single(xaml.Descendants(), e => (string?)e.Attribute(x + "Name") == "TechnicalDetailsExpander");
        Assert.Equal("{http://schemas.microsoft.com/winfx/2006/xaml/presentation}Expander", expander.Name.ToString());
        Assert.Single(expander.Elements());
    }

    [Fact]
    public void LogSummaryWrapsAcrossTheFullCardBelowHeaderActions()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "PzTools.sln"))) root = root.Parent;
        Assert.NotNull(root);
        var xaml = XDocument.Load(Path.Combine(root.FullName, "src", "PzTools.App", "LogsPage.xaml"));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        var summary = Assert.Single(xaml.Descendants(), e => (string?)e.Attribute(x + "Name") == "DetailSummaryTime");
        Assert.Equal("Wrap", (string?)summary.Attribute("TextWrapping"));
        Assert.Equal("1", (string?)summary.Attribute("Grid.Row"));
        Assert.Equal("2", (string?)summary.Attribute("Grid.ColumnSpan"));
        Assert.Equal("Grid", summary.Parent!.Name.LocalName);
        Assert.Equal(2, summary.Parent.Elements().Single(e => e.Name.LocalName == "Grid.RowDefinitions").Elements().Count());
    }

    [Fact]
    public async Task WriteRetriesReplaceSamplesButKeepPhaseAndTerminalBoundaries()
    {
        using var temp = new TempDirectory();
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, "archive-worker");
        await using (var session = await ProcessTelemetrySession.StartAsync(temp.Path, "archive-worker", 1,
            interval: TimeSpan.FromMilliseconds(20)))
        {
            await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                { DataSource = store.DatabasePath, Pooling = false }.ToString());
            await connection.OpenAsync();
            using var command = connection.CreateCommand();
            // A persistent failure avoids relying on a race with a short-lived DB lock.
            command.CommandText = "ALTER TABLE telemetry_events RENAME TO unavailable_events;";
            await command.ExecuteNonQueryAsync();
            session.RecordEvent("run.started");
            for (var i = 1; i <= 6; i++)
            {
                session.SetProgress("scan", i, 6, i, 6, null);
                await Task.Delay(80);
            }
            session.SetProgress("import", 1, 1, 10, 10, null);
            session.RecordEvent("run.committed");
            await Task.Delay(80);
            command.CommandText = "ALTER TABLE unavailable_events RENAME TO telemetry_events;";
            await command.ExecuteNonQueryAsync();
        }
        var events = await store.ReadEventsAfterAsync(0);
        Assert.Equal(new[] { "run.started", "progress.snapshot", "progress.snapshot", "run.committed" },
            events.Select(e => e.EventName));
        using var lastScan = JsonDocument.Parse(events[1].PayloadJson!);
        Assert.Equal(6, lastScan.RootElement.GetProperty("completedItems").GetInt64());
    }

    [Fact]
    public void SidebarCardTextWrapsWithinThePane()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !File.Exists(Path.Combine(root.FullName, "PzTools.sln"))) root = root.Parent;
        Assert.NotNull(root);
        var xaml = XDocument.Load(Path.Combine(root.FullName, "src", "PzTools.App", "MainWindowShell.xaml"));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        foreach (var name in new[] { "ProjectorStatusTitle", "ProjectorStatusMessage", "BackupProgressTitle",
                     "BackupProgressMessage", "ExportProgressTitle", "ExportProgressMessage" })
        {
            var text = Assert.Single(xaml.Descendants(), e => (string?)e.Attribute(x + "Name") == name);
            Assert.Equal("Wrap", (string?)text.Attribute("TextWrapping"));
        }
    }

    [Theory]
    [InlineData("scan")]
    [InlineData("hash")]
    [InlineData("capture")]
    [InlineData("restore")]
    public async Task UnknownProgressTotalsDoNotBlockCompletionOrLeaveARunningCard(string phase)
    {
        using var temp = new TempDirectory();
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, "backup-worker");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("backup-worker", "backup-worker", temp.Path, store.DatabasePath, TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var projector = new TelemetryProjectionHost(catalog, views, logInbox: inbox);
        await store.RecordAsync("backup-worker", 1, "run.started");
        await store.RecordAsync("backup-worker", 1, "workload.discovered", "{\"totalItems\":10,\"totalBytes\":100}");
        await projector.ProjectOnceAsync();
        await store.RecordAsync("backup-worker", 1, "progress.snapshot", JsonSerializer.Serialize(new
        {
            phase, completedItems = 1, totalItems = (long?)null,
            completedBytes = (long?)null, totalBytes = (long?)null,
        }));
        await projector.ProjectOnceAsync();
        var unknown = Assert.Single(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal(OperationStatus.Running, unknown.Status);
        Assert.Null(unknown.TotalItems);
        Assert.Null(unknown.TotalBytes);
        Assert.True(PzTools.App.Core.OperationProgressDisplay.From(unknown).IsIndeterminate);
        await store.RecordAsync("backup-worker", 1, "run.committed", "{\"revision\":1}");
        await projector.ProjectOnceAsync();
        var completed = Assert.Single(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal(OperationStatus.Succeeded, completed.Status);
        Assert.False(PzTools.App.Core.OperationProgressDisplay.From(completed).IsVisible);
        Assert.Contains((await inbox.ReadViewAsync(new(LogLevel.Information, 100))).Entries,
            log => log.EventName == "run.committed");
        await projector.ProjectOnceAsync(DateTimeOffset.UtcNow.AddMinutes(1));
        Assert.Empty(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
    }

    [Fact]
    public async Task LockedSourceCannotHoldHealthyProgressUntilItsLockIsReleased()
    {
        using var temp = new TempDirectory();
        var locked = await ProcessTelemetryStore.CreateForIdentityAsync(temp.GetPath("locked"), "archive-worker");
        var healthy = await ProcessTelemetryStore.CreateForIdentityAsync(temp.GetPath("healthy"), "archive-worker");
        await locked.RecordAsync("archive-worker", 1, "run.started");
        await healthy.RecordAsync("archive-worker", 2, "run.started");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("a", "archive-worker", temp.GetPath("locked"), locked.DatabasePath, TelemetryDatabaseKind.Process, true));
        catalog.Register(new("b", "archive-worker", temp.GetPath("healthy"), healthy.DatabasePath, TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = locked.DatabasePath, Pooling = false }.ToString());
        await connection.OpenAsync();
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;";
        await command.ExecuteNonQueryAsync();
        var projection = Task.Run(() => projector.ProjectOnceAsync());
        try
        {
            await projection.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Contains(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations,
                operation => operation.SourceId == "b" && operation.Status == OperationStatus.Running);
        }
        finally
        {
            command.CommandText = "ROLLBACK;";
            await command.ExecuteNonQueryAsync();
            await projection;
        }
    }

    [Theory]
    [InlineData("state-scheduler", "Busy", false, LogLevel.Trace)]
    [InlineData("state-scheduler", "Failed", false, LogLevel.Error)]
    [InlineData("state-scheduler", "Degraded", true, LogLevel.Warning)]
    [InlineData("backup-scheduler", "Busy", false, LogLevel.Warning)]
    public async Task OnlyDuplicateStateChecksAreQuiet(string component, string outcome, bool started, LogLevel level)
    {
        using var temp = new TempDirectory();
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(temp.Path, component);
        await store.RecordAsync(component, 1, "tick.completed", JsonSerializer.Serialize(new { outcome, Started = started }));
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new("test", component, temp.Path, store.DatabasePath, TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);
        projector.ConfigureLogs(new LogProjectionOptions(LogLevel.Trace, 100));
        await projector.ProjectOnceAsync();
        Assert.Equal(level, Assert.Single(views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries).Level);
    }

    [Fact]
    public async Task CaptureReportsCompressionSeparatelyFromSourceCopy()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("large.bin");
        var bytes = new byte[2 * 1024 * 1024];
        new Random(42).NextBytes(bytes);
        await File.WriteAllBytesAsync(path, bytes);
        await using var writer = await PackWriter.CreateAsync(temp.GetPath("repository"), 1);
        var samples = new List<FileCopyProgress>();
        await new StableFileCapturer(new WindowsFileMetadataReader()).CaptureAsync(path, writer,
            ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli,
            progress: value => { samples.Add(value); return ValueTask.CompletedTask; });
        Assert.Contains(samples, p => p.Phase == "copy" && p.CopiedBytes == bytes.Length);
        Assert.Contains(samples, p => p.Phase == "capture" && p.CopiedBytes > 0 && p.CopiedBytes < bytes.Length);
        Assert.Equal("capture", samples[^1].Phase);
        Assert.Equal(bytes.Length, samples[^1].CopiedBytes);
    }
}
