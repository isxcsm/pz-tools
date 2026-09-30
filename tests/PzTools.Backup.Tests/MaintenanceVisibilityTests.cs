using PzTools.Process.Telemetry;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class MaintenanceVisibilityTests
{
    private const string Lane = "maintenance-lane-RevisionReclamation";

    [Fact]
    public async Task AnnouncedCleanup_IsShownFromStartToFinish_AndLoggedAsInformation()
    {
        using var temp = new TempDirectory();
        var fixture = await Fixture.CreateAsync(temp, Lane);
        await fixture.Store.RecordAsync(Lane, 5, "maintenance.revisionreclamation.started",
            """{"lane":"RevisionReclamation","planned":true}""");
        await fixture.Store.RecordAsync(Lane, 5, "operation.heartbeat");

        var running = Assert.Single(await fixture.ProjectAsync());
        Assert.Equal(OperationStatus.Running, running.Status);
        Assert.Equal("maintenance.revisionreclamation", running.Phase);

        await fixture.Store.RecordAsync(Lane, 5, "maintenance.revisionreclamation.completed",
            """{"outcome":"Succeeded","planned":true,"AffectedItems":12}""");
        Assert.Equal(OperationStatus.Succeeded, Assert.Single(await fixture.ProjectAsync()).Status);

        var logs = fixture.Logs();
        Assert.Equal(2, logs.Count);
        Assert.All(logs, item => Assert.Equal(LogLevel.Information, item.Level));
    }

    [Fact]
    public async Task RoutineCheckWithNothingToDo_HasNoCardAndNoInformationLog()
    {
        using var temp = new TempDirectory();
        var fixture = await Fixture.CreateAsync(temp, "maintenance-lane-ArtifactCleanup");
        await fixture.Store.RecordAsync("maintenance-lane-ArtifactCleanup", 6, "maintenance.artifactcleanup.started",
            """{"lane":"ArtifactCleanup","planned":false}""");
        Assert.Empty(await fixture.ProjectAsync()); // Not running long enough to matter yet.
        await fixture.Store.RecordAsync("maintenance-lane-ArtifactCleanup", 6, "maintenance.artifactcleanup.completed",
            """{"outcome":"Succeeded","planned":false,"AffectedItems":0}""");

        Assert.Empty(await fixture.ProjectAsync());
        Assert.Empty(fixture.Logs());
    }

    [Fact]
    public async Task UnannouncedCleanupThatDidWork_IsLoggedWithoutAPopUpCard()
    {
        using var temp = new TempDirectory();
        var fixture = await Fixture.CreateAsync(temp, "maintenance-lane-ArtifactCleanup");
        await fixture.Store.RecordAsync("maintenance-lane-ArtifactCleanup", 7, "maintenance.artifactcleanup.completed",
            """{"outcome":"Succeeded","planned":false,"AffectedItems":3}""");

        Assert.Empty(await fixture.ProjectAsync());
        Assert.Equal(LogLevel.Information, Assert.Single(fixture.Logs()).Level);
    }

    [Fact]
    public async Task CleanupThatYields_IsPostponedNotFailed()
    {
        using var temp = new TempDirectory();
        var fixture = await Fixture.CreateAsync(temp, Lane);
        await fixture.Store.RecordAsync(Lane, 8, "maintenance.revisionreclamation.started", """{"planned":true}""");
        Assert.Single(await fixture.ProjectAsync());
        await fixture.Store.RecordAsync(Lane, 8, "maintenance.revisionreclamation.cancelled", """{"status":"Cancelled"}""");

        Assert.Equal(OperationStatus.Cancelled, Assert.Single(await fixture.ProjectAsync()).Status);
        Assert.All(fixture.Logs(), item => Assert.Equal(LogLevel.Information, item.Level));
    }

    [Fact]
    public async Task FailedCleanup_IsShownEvenIfItWasNeverVisiblyRunning()
    {
        using var temp = new TempDirectory();
        var fixture = await Fixture.CreateAsync(temp, Lane);
        await fixture.Store.RecordAsync(Lane, 9, "maintenance.revisionreclamation.failed", """{"failureCode":"IOException"}""");

        Assert.Equal(OperationStatus.Failed, Assert.Single(await fixture.ProjectAsync()).Status);
        Assert.Equal(LogLevel.Error, Assert.Single(fixture.Logs()).Level);
    }

    [Fact]
    public async Task ProgressNotesWithoutAStart_NeverAppearAsAWaitingCard()
    {
        using var temp = new TempDirectory();
        var fixture = await Fixture.CreateAsync(temp, "maintenance-lane-OrphanBackups");
        await fixture.Store.RecordAsync("maintenance-lane-OrphanBackups", 10, "maintenance.recovery.failed", """{"Problems":[]}""");
        await fixture.Store.RecordAsync("maintenance-lane-OrphanBackups", 10, "maintenance.database.completed",
            """{"outcome":"Succeeded","AffectedItems":4}""");

        Assert.Empty(await fixture.ProjectAsync());
    }

    private sealed class Fixture(ProcessTelemetryStore store, TelemetryProjectionHost host, RevisionedViewStore views)
    {
        public ProcessTelemetryStore Store => store;

        public static async Task<Fixture> CreateAsync(TempDirectory temp, string component)
        {
            var identity = temp.GetPath("identity");
            var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, component);
            var catalog = new TelemetrySourceCatalog();
            catalog.Register(new TelemetrySourceRegistration(
                component, component, identity, store.DatabasePath, TelemetryDatabaseKind.Process, true));
            var views = new RevisionedViewStore();
            var host = new TelemetryProjectionHost(catalog, views);
            // The app's defaults: record and show Information, drop Trace.
            host.ConfigureRecordingLevel(LogLevel.Information);
            host.ConfigureLogs(new LogProjectionOptions(LogLevel.Information, 100));
            return new(store, host, views);
        }

        public async Task<IReadOnlyList<OperationView>> ProjectAsync()
        {
            await host.ProjectOnceAsync();
            return views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations;
        }

        public IReadOnlyList<LogEntryView> Logs() => views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries;
    }
}
