using Microsoft.Data.Sqlite;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Projections;
using PzTools.Zomboid.State;
using PzTools.Backup.Storage.Telemetry;
using PzTools.SaveBridge;
using PzTools.Zomboid.Backup;
using System.Text.Json;

namespace PzTools.Backup.Tests;

public sealed class OneShotBackupServiceTests
{
    [Fact]
    public async Task Preparation_IsAwaitedBeforeInitialAndIncrementalCaptureAndBoundary()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var options = CreateOptions(temp.GetPath("repository"), sourcePath) with
        {
            AlwaysIncludePaths = ["players.db"],
            Telemetry = new(TelemetryMode.Phase, 16, 10, 100, 32),
        };
        var journal = new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0));
        var calls = 0;
        var service = new OneShotBackupService(journal, async (path, token) =>
        {
            Assert.Equal(sourcePath, path);
            // The repository lease must already be held before the game is asked to save.
            Assert.Throws<RepositoryBusyException>(() => RepositoryWriterLease.Acquire(options.RepositoryPath));
            await Task.Yield();
            await File.WriteAllTextAsync(Path.Combine(path, "players.db"), $"saved-{++calls}", token);
            journal.State = journal.State with { NextUsn = 100 + calls * 50 };
            return new("saved");
        });
        for (var revision = 1; revision <= 2; revision++)
        {
            var result = await service.RunAsync(options, "main");
            Assert.Equal(revision, result.Revision);
            Assert.Equal(revision, calls);
            Assert.Equal(100 + revision * 50, result.Checkpoint!.NextUsn);
            var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
            var source = await repository.GetSourceAsync("main");
            var restore = temp.GetPath($"restored-{revision}");
            await new RevisionRestorer().RestoreAsync(repository, source!.SourceId, revision, restore);
            Assert.Equal($"saved-{revision}", await File.ReadAllTextAsync(Path.Combine(restore, "players.db")));
            var events = await (await TelemetryStore.CreateOrOpenAsync(options.RepositoryPath)).ReadEventsAsync(result.RunIndex);
            Assert.True(events.Single(e => e.Name == "source.prepare.completed").Sequence
                < events.Single(e => e.Name == (revision == 1 ? "scan.started" : "planning.started")).Sequence);
        }
    }

    [Theory]
    [InlineData(false, "save-failed")]
    [InlineData(true, "completion-unknown")]
    public async Task PreparationFailure_CreatesNoRevisionAndKeepsCheckpoint(bool incremental, string code)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "players.db"), "old");
        var options = CreateOptions(temp.GetPath("repository"), sourcePath) with
        {
            Telemetry = new(TelemetryMode.Phase, 16, 10, 100, 32),
        };
        var journal = new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0));
        if (incremental) await new OneShotBackupService(journal).RunAsync(options, "main");
        const string failureDiagnostics = "captureStatsV1=10,5,2; bridgeAdmissionStatsV1=1,20";
        var service = new OneShotBackupService(journal, (_, _) =>
            throw new GameSaveException(code, "Cannot confirm save", failureDiagnostics));
        journal.State = journal.State with { NextUsn = 200 };
        await Assert.ThrowsAsync<GameSaveException>(() => service.RunAsync(options, "main"));
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        var source = await repository.GetSourceAsync("main");
        var state = await repository.GetSourceStateAsync(source!.SourceId);
        Assert.Equal(incremental ? 1 : 0, state.CurrentRevision);
        if (!incremental) Assert.Null(state.Checkpoint);
        else Assert.Equal(100, state.Checkpoint!.NextUsn);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(options.RepositoryPath);
        var runIndex = incremental ? 2 : 1;
        Assert.Equal("Failed", (await telemetry.ReadRunAsync(runIndex))!.Status);
        var events = await telemetry.ReadEventsAsync(runIndex);
        Assert.DoesNotContain(events, item => item.Name is "scan.started" or "planning.started" or "run.committed");
        using var payload = JsonDocument.Parse(Assert.Single(events, item => item.Name == "run.failed").PayloadJson!);
        Assert.Equal("source.prepare", payload.RootElement.GetProperty("phase").GetString());
        Assert.Contains(code, payload.RootElement.GetProperty("message").GetString());
        Assert.Equal(failureDiagnostics, payload.RootElement.GetProperty("diagnostics").GetString());
    }

    [Theory]
    [InlineData(false, "queue-timeout")]
    [InlineData(true, "queue-timeout")]
    [InlineData(false, "runtime-deferred")]
    [InlineData(true, "runtime-deferred")]
    public async Task PreparationDeferred_PreservesBoundedDiagnosticsInCancelledWorkerAndAppLogs(bool incremental, string code)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "players.db"), "old");
        var options = CreateOptions(temp.GetPath("repository"), sourcePath) with
        {
            Telemetry = new(TelemetryMode.Phase, 16, 10, 100, 32),
        };
        var journal = new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0));
        if (incremental) await new OneShotBackupService(journal).RunAsync(options, "main");
        var original = new GameSaveException(code, "Preparation deferred",
            sourcePath + "\nbridgeAdmissionStatsV1=3,900; " + new string('x', 7000));
        var service = new OneShotBackupService(journal, (_, _) =>
            throw new BackupPreparationDeferredException(original.Message, original.Diagnostics));
        journal.State = journal.State with { NextUsn = 200 };
        var deferred = await Assert.ThrowsAsync<BackupPreparationDeferredException>(() => service.RunAsync(options, "main"));
        Assert.Equal(original.Diagnostics, deferred.Diagnostics);
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        var source = await repository.GetSourceAsync("main");
        var state = await repository.GetSourceStateAsync(source!.SourceId);
        Assert.Equal(incremental ? 1 : 0, state.CurrentRevision);
        if (!incremental) Assert.Null(state.Checkpoint);
        else Assert.Equal(100, state.Checkpoint!.NextUsn);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(options.RepositoryPath);
        var runIndex = incremental ? 2 : 1;
        Assert.Equal("Cancelled", (await telemetry.ReadRunAsync(runIndex))!.Status);
        var events = await telemetry.ReadEventsAsync(runIndex);
        Assert.DoesNotContain(events, item => item.Name is "scan.started" or "planning.started" or "run.committed" or "run.failed");
        var cancelled = Assert.Single(events, item => item.Name == "run.cancelled");
        using var payload = JsonDocument.Parse(cancelled.PayloadJson!);
        Assert.Equal("source-deferred", payload.RootElement.GetProperty("code").GetString());
        Assert.Equal("source.prepare", payload.RootElement.GetProperty("phase").GetString());
        var detail = payload.RootElement.GetProperty("diagnostics").GetString()!;
        Assert.StartsWith("<save> bridgeAdmissionStatsV1=3,900; ", detail);
        Assert.DoesNotContain(sourcePath, detail);
        Assert.DoesNotContain('\n', detail);
        Assert.Equal(6145, detail.Length); // Shared limit plus the truncation marker.
        Assert.EndsWith("…", detail);

        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration("backup-worker", "backup-worker",
            options.RepositoryPath, telemetry.DatabasePath, TelemetryDatabaseKind.Backup, true));
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views, logInbox: inbox);
        projector.ConfigureRecordingLevel(LogLevel.Warning);
        await projector.ProjectOnceAsync();
        var logged = Assert.Single((await inbox.ReadPageAsync(
            new LogPageQuery(LogLevel.Warning, "All", "", 0))).Entries,
            item => item.RunIndex == runIndex && item.EventName == "run.cancelled");
        Assert.Equal(LogLevel.Warning, logged.Level);
        Assert.Equal(cancelled.PayloadJson, logged.PayloadJson);
    }

    [Fact]
    public async Task Run_PerformsExactlyOneAttemptAndReturns()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "file.txt"), "content");
        var options = CreateOptions(temp.GetPath("repository"), sourcePath);
        var journal = new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0));
        var service = new OneShotBackupService(journal);

        var first = await service.RunAsync(options, "main");
        journal.State = journal.State with { NextUsn = 150 };
        var second = await service.RunAsync(options, "main");

        Assert.Equal(1, first.RunIndex);
        Assert.Equal(1, first.Revision);
        Assert.Equal("InitialFullScan", first.Mode);
        Assert.Equal(2, second.RunIndex);
        Assert.Null(second.Revision);
        Assert.Equal("Journal", second.Mode);
        Assert.Empty(first.Warnings);
        Assert.False(File.Exists(Path.Combine(options.RepositoryPath, "telemetry.db")));
    }

    [Fact]
    public async Task Run_AlwaysIncludeCreatesRevisionForUnchangedSelectedFile()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "players.db"), "content");
        var options = CreateOptions(temp.GetPath("repository"), sourcePath) with
        {
            AlwaysIncludePaths = ["players.db"],
        };
        var journal = new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0));
        var service = new OneShotBackupService(journal);

        var first = await service.RunAsync(options, "main");
        journal.State = journal.State with { NextUsn = 150 };
        var second = await service.RunAsync(options, "main");

        Assert.Equal(1, first.Revision);
        Assert.Equal(2, second.Revision);
        Assert.Equal(1, second.ChangedEntries);
    }

    [Fact]
    public async Task BackupProjector_ReadsCharacterAndDeathFromEachRevision()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var playersPath = Path.Combine(sourcePath, "players.db");
        await using (var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = playersPath, Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER, name TEXT, isDead INTEGER); "
                + "INSERT INTO localPlayers VALUES(1, 'First Character', 1);";
            await command.ExecuteNonQueryAsync();
        }

        var repositoryPath = temp.GetPath("repository");
        var options = CreateOptions(repositoryPath, sourcePath) with
        {
            AlwaysIncludePaths = ["players.db"],
        };
        var journal = new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0));
        var service = new OneShotBackupService(journal);
        Assert.Equal(1, (await service.RunAsync(options, "main")).Revision);

        await using (var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = playersPath, Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "UPDATE localPlayers SET name='Second Character', isDead=0;";
            await command.ExecuteNonQueryAsync();
        }
        journal.State = journal.State with { NextUsn = 150 };
        Assert.Equal(2, (await service.RunAsync(options, "main")).Revision);

        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var views = new RevisionedViewStore();
        await new PzTools.Zomboid.Backup.RevisionCharacterMetadataCollector().CollectOnceAsync(repository);
        await new BackupProjector(repository, views).ProjectOnceAsync();
        var revisions = Assert.Single(views.ReadIfChanged<BackupCatalogView>(
            ViewKey.BackupCatalog, 0).Snapshot!.Sources).Revisions;
        var first = Assert.Single(revisions, item => item.Revision == 1);
        var second = Assert.Single(revisions, item => item.Revision == 2);
        Assert.Equal("First Character", first.CharacterName);
        Assert.Equal(CharacterState.Dead, first.CharacterState);
        Assert.Equal("Second Character", second.CharacterName);
        Assert.Equal(CharacterState.Alive, second.CharacterState);
        Assert.All(revisions, revision => Assert.False(revision.SurvivalPending));

        repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var persisted = Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions;
        Assert.Equal("Dead", Assert.Single(persisted, item => item.Revision == 1).CharacterState);
        Assert.Equal("Alive", Assert.Single(persisted, item => item.Revision == 2).CharacterState);
    }

    [Fact]
    public async Task BackupProjector_ExposesPendingSurvivalUntilEachRevisionIsRead()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var playersPath = Path.Combine(sourcePath, "players.db");
        await using (var connection = new SqliteConnection(
            new SqliteConnectionStringBuilder { DataSource = playersPath, Pooling = false }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE localPlayers(id INTEGER, name TEXT, isDead INTEGER); "
                + "INSERT INTO localPlayers VALUES(1, 'Character 1', 0);";
            await command.ExecuteNonQueryAsync();
        }

        var repositoryPath = temp.GetPath("repository");
        var options = CreateOptions(repositoryPath, sourcePath) with
        {
            AlwaysIncludePaths = ["players.db"],
        };
        var journal = new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0));
        var service = new OneShotBackupService(journal);
        for (var revision = 1; revision <= 9; revision++)
        {
            if (revision > 1)
            {
                await using var connection = new SqliteConnection(
                    new SqliteConnectionStringBuilder { DataSource = playersPath, Pooling = false }.ToString());
                await connection.OpenAsync();
                await using var command = connection.CreateCommand();
                command.CommandText = "UPDATE localPlayers SET name=$name;";
                command.Parameters.AddWithValue("$name", $"Character {revision}");
                await command.ExecuteNonQueryAsync();
                journal.State = journal.State with { NextUsn = 100 + revision * 50 };
            }
            Assert.Equal(revision, (await service.RunAsync(options, "main")).Revision);
        }

        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var views = new RevisionedViewStore();
        var projector = new BackupProjector(repository, views);
        var collector = new PzTools.Zomboid.Backup.RevisionCharacterMetadataCollector();
        await collector.CollectOnceAsync(repository);
        await projector.ProjectOnceAsync();
        var revisions = Assert.Single(views.ReadIfChanged<BackupCatalogView>(
            ViewKey.BackupCatalog, 0).Snapshot!.Sources).Revisions;
        Assert.Equal(9, revisions.Count);
        Assert.Single(revisions, revision => revision.SurvivalPending);

        await collector.CollectOnceAsync(repository);
        await projector.ProjectOnceAsync();
        revisions = Assert.Single(views.ReadIfChanged<BackupCatalogView>(
            ViewKey.BackupCatalog, 0).Snapshot!.Sources).Revisions;
        Assert.All(revisions, revision => Assert.False(revision.SurvivalPending));
    }

    [RealZomboidSavesFact]
    public async Task BackupProjector_ReadsSurvivalDurationFromCapturedPlayerSnapshot()
    {
        var savesRoot = Environment.GetEnvironmentVariable("PZTOOLS_REAL_SAVES_ROOT")!;
        string? sample = null;
        foreach (var path in Directory.EnumerateFiles(
                     savesRoot, "players.db", SearchOption.AllDirectories))
        {
            if ((await new CharacterNameReader().ReadSnapshotAsync(path)).HoursSurvived is not > 0)
                continue;
            sample = path;
            break;
        }
        Assert.NotNull(sample);
        var expected = (await new CharacterNameReader().ReadSnapshotAsync(sample)).HoursSurvived;

        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        File.Copy(sample, Path.Combine(sourcePath, "players.db"));
        var repositoryPath = temp.GetPath("repository");
        var options = CreateOptions(repositoryPath, sourcePath);
        await new OneShotBackupService(
            new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0)))
            .RunAsync(options, "main");

        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var views = new RevisionedViewStore();
        await new PzTools.Zomboid.Backup.RevisionCharacterMetadataCollector().CollectOnceAsync(repository);
        await new BackupProjector(repository, views).ProjectOnceAsync();
        var revision = Assert.Single(Assert.Single(
            views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0)
                .Snapshot!.Sources).Revisions);
        Assert.Equal(expected, revision.HoursSurvived);
    }

    [Fact]
    public async Task Run_TelemetryDatabaseFailureIsReportedWithoutFailingBackup()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "file.txt"), "content");
        var repositoryPath = temp.GetPath("repository");
        var options = CreateOptions(repositoryPath, sourcePath) with
        {
            Telemetry = new TelemetryOptions(
                TelemetryMode.Raw,
                BatchSize: 16,
                FlushIntervalMilliseconds: 10,
                RetainRuns: 10,
                MaxDatabaseMib: 32),
        };
        Directory.CreateDirectory(repositoryPath);
        await File.WriteAllTextAsync(Path.Combine(repositoryPath, "telemetry.db"), "not sqlite");

        var result = await new OneShotBackupService(
            new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0)))
            .RunAsync(options, "main");

        Assert.Equal(1, result.Revision);
        Assert.Contains(result.Warnings, warning => warning.Code == "telemetry_unavailable");
    }

    [Fact]
    public async Task Run_WhenRepositoryIsBusyFailsBeforeAllocatingRunIndex()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var repositoryPath = temp.GetPath("repository");
        var options = CreateOptions(repositoryPath, sourcePath);
        await using (RepositoryWriterLease.Acquire(repositoryPath))
        {
            await Assert.ThrowsAsync<RepositoryBusyException>(
                () => new OneShotBackupService(
                    new FakeJournal(new UsnJournalState(1, 2, 0, 100, 0)))
                    .RunAsync(options, "main"));
        }

        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM runs;";
        Assert.Equal(0L, await command.ExecuteScalarAsync());
    }

    private static BackupOptions CreateOptions(string repositoryPath, string sourcePath) =>
        new(
            BackupConfiguration.CurrentFormatVersion,
            repositoryPath,
            [new BackupSourceOptions("main", sourcePath)],
            new StorageOptions(
                ChecksumAlgorithm.Sha256,
                CompressionAlgorithm.None,
                ContentDeduplication: false),
            new TelemetryOptions(
                TelemetryMode.Off,
                BatchSize: 16,
                FlushIntervalMilliseconds: 10,
                RetainRuns: 10,
                MaxDatabaseMib: 32));

    private sealed class FakeJournal(UsnJournalState state) : IUsnJournalSource
    {
        public UsnJournalState State { get; set; } = state;

        public UsnJournalState Query(string sourcePath) => State;

        public IEnumerable<UsnRecord> ReadRange(
            string sourcePath,
            UsnCheckpoint checkpoint,
            long upperUsnExclusive,
            CancellationToken cancellationToken = default) => [];
    }

    private sealed class RealZomboidSavesFactAttribute : FactAttribute
    {
        public RealZomboidSavesFactAttribute()
        {
            var root = Environment.GetEnvironmentVariable("PZTOOLS_REAL_SAVES_ROOT");
            if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
                Skip = "Set PZTOOLS_REAL_SAVES_ROOT to a Project Zomboid Saves root.";
        }
    }
}
