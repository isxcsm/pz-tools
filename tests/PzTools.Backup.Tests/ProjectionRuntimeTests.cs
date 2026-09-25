using Microsoft.Data.Sqlite;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Process.Telemetry;
using PzTools.Projections;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class ProjectionRuntimeTests
{
    [Fact]
    public async Task ProjectionHost_StopCancelsRunningAndQueuedRefreshBeforeDisposal()
    {
        await using var host = new ProjectionHost();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        host.AddLoop("fixture", async token =>
        {
            entered.TrySetResult();
            try { await Task.Delay(Timeout.InfiniteTimeSpan, token); }
            finally { stopped.TrySetResult(); }
        }, TimeSpan.FromHours(1));
        host.Start();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var queued = host.ProjectNowAsync("fixture");

        host.RequestStop();

        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => queued);
        // A late refresh sees cancellation, not a disposed token source.
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => host.ProjectNowAsync("fixture"));
    }

    [Fact]
    public async Task ImmediateProjection_SerializesWithPeriodicProjection()
    {
        await using var host = new ProjectionHost();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var running = 0;
        var count = 0;
        var overlap = false;
        host.AddLoop("fixture", async token =>
        {
            if (Interlocked.Increment(ref running) != 1) overlap = true;
            try
            {
                if (Interlocked.Increment(ref count) == 1)
                {
                    entered.SetResult();
                    await release.Task.WaitAsync(token);
                }
            }
            finally { Interlocked.Decrement(ref running); }
        }, TimeSpan.FromHours(1));
        host.Start();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var immediate = host.ProjectNowAsync("fixture");
        Assert.False(immediate.IsCompleted);
        release.SetResult();
        await immediate.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(overlap);
        Assert.Equal(2, count);
        Assert.Equal(ProjectorHealth.Healthy, Assert.Single(host.Statuses).Health);
    }

    [Fact]
    public async Task ArchiveTelemetry_NormalizesLegacyTotalsAndResetsPhaseCounters()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("archive");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "archive-worker");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "archive", "archive-worker", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);
        OperationView Read() => Assert.Single(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);

        await store.RecordAsync("archive-worker", 1, "run.started");
        await store.RecordAsync("archive-worker", 1, "workload.discovered", "{\"TotalItems\":2,\"TotalBytes\":30}");
        await store.RecordAsync("archive-worker", 1, "file.export.completed", "{\"bytes\":10}");
        await projector.ProjectOnceAsync();
        Assert.Equal(2, Read().TotalItems);
        Assert.Equal(30, Read().TotalBytes);
        Assert.Equal(1, Read().CompletedItems);

        await store.RecordAsync("archive-worker", 1, "workload.discovered",
            "{\"phase\":\"archive.compress\",\"totalItems\":2,\"totalBytes\":30}");
        await projector.ProjectOnceAsync();
        Assert.Equal("archive.compress", Read().Phase);
        Assert.Equal(0, Read().CompletedItems);
        Assert.Equal(0, Read().CompletedBytes);
        await store.RecordAsync("archive-worker", 1, "file.export.completed", "{\"bytes\":20}");
        await projector.ProjectOnceAsync();
        await projector.ProjectOnceAsync();
        Assert.Equal(1, Read().CompletedItems);
        Assert.Equal(20, Read().CompletedBytes);

        await store.RecordAsync("archive-worker", 1, "workload.discovered",
            "{\"phase\":\"archive.finalize\",\"totalItems\":0,\"totalBytes\":0}");
        await projector.ProjectOnceAsync();
        Assert.Equal("archive.finalize", Read().Phase);
        Assert.Equal(0, Read().TotalItems);
        Assert.Equal(0, Read().CompletedItems);
    }

    [Fact]
    public async Task SaveList_ProvidesNewestPlayedFirstAndPreservesDeathStateInDetail()
    {
        using var temp = new TempDirectory();
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var now = DateTimeOffset.UtcNow;
        var observations = new[]
        {
            (Name: "A-older", Played: (DateTimeOffset?)now.AddHours(-1), Character: CharacterState.Alive),
            (Name: "B-unknown", Played: (DateTimeOffset?)null, Character: CharacterState.Alive),
            (Name: "Z-newest", Played: (DateTimeOffset?)now, Character: CharacterState.Dead),
        }.Select(item => new SaveObservation(
            Path.GetFullPath(temp.GetPath(item.Name)).ToUpperInvariant(),
            "Sandbox", item.Name, true, false, ActivityState.Inactive,
            item.Character, LaneStatus.Succeeded, LaneStatus.Succeeded,
            LastPlayedUtc: item.Played)).ToArray();
        await state.WritePendingBatchAsync(new CollectionBatch(
            Guid.NewGuid().ToString("D"), 1, now, now, 1, true, observations));
        await new StateReactor().RunAsync(state);
        var views = new RevisionedViewStore();
        await new StateProjector(state, views).ProjectOnceAsync();
        var composer = new SaveDetailComposer(views);
        await composer.ComposeOnceAsync();

        var list = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).Snapshot!;
        Assert.Equal(["Z-newest", "A-older", "B-unknown"], list.Saves.Select(item => item.Name));
        Assert.Null(views.ReadIfChanged<SaveDetailView>(
            ViewKey.SaveDetail(list.Saves[0].SaveId), 0).Snapshot);
        views.Publish(ViewKey.BackupCatalog, new BackupCatalogView(0, []));
        await composer.ComposeOnceAsync();
        var detail = views.ReadIfChanged<SaveDetailView>(
            ViewKey.SaveDetail(list.Saves[0].SaveId), 0).Snapshot!;
        Assert.Equal(CharacterState.Dead, detail.LiveSave!.CharacterState);
    }

    [Fact]
    public async Task SaveList_ThumbnailKeyDoesNotChangeWithLastPlayedTime()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var savePath = temp.GetPath("save");
        Directory.CreateDirectory(savePath);
        await File.WriteAllBytesAsync(Path.Combine(savePath, "thumb.png"), [1, 2, 3]);
        var now = DateTimeOffset.UtcNow;
        var views = new RevisionedViewStore();
        var projector = new StateProjector(database, views);

        async Task<string?> ProjectAsync(long run, DateTimeOffset played)
        {
            await database.WritePendingBatchAsync(new CollectionBatch(
                Guid.NewGuid().ToString("D"), run, now, now, 1, true,
                [new SaveObservation(
                    Path.GetFullPath(savePath).ToUpperInvariant(), "Sandbox", "Save",
                    true, false, ActivityState.Inactive, CharacterState.Alive,
                    LaneStatus.Succeeded, LaneStatus.Succeeded, LastPlayedUtc: played)]));
            await new StateReactor().RunAsync(database);
            await projector.ProjectOnceAsync();
            return Assert.Single(views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0)
                .Snapshot!.Saves).ThumbnailKey;
        }

        var first = await ProjectAsync(1, now);
        var second = await ProjectAsync(2, now.AddSeconds(10));
        Assert.Equal(first, second);
    }

    [Theory]
    [InlineData("players.db", "timestamp")]
    [InlineData("players.db", "length")]
    [InlineData("players.db", "created")]
    [InlineData("players.db", "deleted")]
    [InlineData("thumb.png", "timestamp")]
    [InlineData("thumb.png", "length")]
    [InlineData("thumb.png", "created")]
    [InlineData("thumb.png", "deleted")]
    public async Task LiveThumbnail_TracksFilesWithoutStateRevisionChange(string fileName, string change)
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var savePath = temp.GetPath("save");
        Directory.CreateDirectory(savePath);
        var path = Path.Combine(savePath, fileName);
        if (change != "created") await File.WriteAllBytesAsync(path, [1, 2, 3]);
        var now = DateTimeOffset.UtcNow;
        await database.WritePendingBatchAsync(new CollectionBatch(
            Guid.NewGuid().ToString("D"), 1, now, now, 1, true,
            [new SaveObservation(savePath, "Sandbox", "Save", true, false,
                ActivityState.Inactive, CharacterState.Alive,
                LaneStatus.Succeeded, LaneStatus.Succeeded)]));
        await new StateReactor().RunAsync(database);
        var views = new RevisionedViewStore();
        var projector = new StateProjector(database, views);
        var composer = new SaveDetailComposer(views);
        var history = new BackupRevisionView(1, now, 10, 1, "complete", "immutable-thumbnail");
        views.Publish(ViewKey.BackupCatalog, new BackupCatalogView(1,
            [new BackupSourceView(1, "Sandbox/Save", savePath, 1, [history])]));
        await projector.ProjectOnceAsync();
        await composer.ComposeOnceAsync();
        var before = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0);
        var detailBefore = views.ReadIfChanged<SaveDetailView>(ViewKey.SaveDetail("Sandbox/Save"), 0);

        var stamp = File.GetLastWriteTimeUtc(path);
        switch (change)
        {
            case "timestamp": File.SetLastWriteTimeUtc(path, stamp.AddSeconds(10)); break;
            case "length":
                await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);
                File.SetLastWriteTimeUtc(path, stamp);
                break;
            case "created": await File.WriteAllBytesAsync(path, [1, 2, 3]); break;
            case "deleted": File.Delete(path); break;
        }
        await projector.ProjectOnceAsync();
        await composer.ComposeOnceAsync();
        var after = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, before.ViewRevision);
        Assert.True(after.Modified);
        Assert.Equal(before.Snapshot!.StateRevision, after.Snapshot!.StateRevision);
        Assert.NotEqual(Assert.Single(before.Snapshot.Saves).ThumbnailKey,
            Assert.Single(after.Snapshot.Saves).ThumbnailKey);
        var detail = views.ReadIfChanged<SaveDetailView>(
            ViewKey.SaveDetail("Sandbox/Save"), detailBefore.ViewRevision);
        Assert.True(detail.Modified);
        Assert.Equal(Assert.Single(after.Snapshot.Saves).ThumbnailKey, detail.Snapshot!.LiveSave!.ThumbnailKey);
        Assert.Equal(history, Assert.Single(detail.Snapshot.BackupRevisions));

        await projector.ProjectOnceAsync();
        await composer.ComposeOnceAsync();
        Assert.False(views.ReadIfChanged<SaveListView>(ViewKey.SaveList, after.ViewRevision).Modified);
        Assert.False(views.ReadIfChanged<SaveDetailView>(
            ViewKey.SaveDetail("Sandbox/Save"), detail.ViewRevision).Modified);
    }

    [Fact]
    public async Task LiveThumbnail_PlayersDatabaseChangeInvalidatesCachedImage()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var savePath = temp.GetPath("save");
        Directory.CreateDirectory(savePath);
        var image = Path.Combine(savePath, "thumb.png");
        var players = Path.Combine(savePath, "players.db");
        byte[] before = [137, 80, 78, 71, 13, 10, 26, 10, 1];
        byte[] after = [137, 80, 78, 71, 13, 10, 26, 10, 2];
        await File.WriteAllBytesAsync(image, before);
        await File.WriteAllBytesAsync(players, [1]);
        var imageStamp = File.GetLastWriteTimeUtc(image);
        var playersStamp = File.GetLastWriteTimeUtc(players);
        var now = DateTimeOffset.UtcNow;
        await database.WritePendingBatchAsync(new CollectionBatch(
            Guid.NewGuid().ToString("D"), 1, now, now, 1, true,
            [new SaveObservation(savePath, "Sandbox", "Save", true, false,
                ActivityState.Inactive, CharacterState.Alive,
                LaneStatus.Succeeded, LaneStatus.Succeeded)]));
        await new StateReactor().RunAsync(database);
        var views = new RevisionedViewStore();
        var projector = new StateProjector(database, views);
        var cache = new ThumbnailCache();
        string Key() => Assert.Single(views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0)
            .Snapshot!.Saves).ThumbnailKey!;
        await projector.ProjectOnceAsync();
        var oldKey = Key();
        Assert.Equal(before, await cache.ReadLiveThumbnailAsync(oldKey, savePath));

        // Same PNG metadata: the players.db change must still invalidate the live cache.
        await File.WriteAllBytesAsync(image, after);
        File.SetLastWriteTimeUtc(image, imageStamp);
        File.SetLastWriteTimeUtc(players, playersStamp.AddSeconds(10));
        await projector.ProjectOnceAsync();
        Assert.NotEqual(oldKey, Key());
        Assert.Equal(after, await cache.ReadLiveThumbnailAsync(Key(), savePath));
    }

    [Fact]
    public void ViewStore_DoesNotAdvanceForEquivalentOrOlderSnapshots()
    {
        var store = new RevisionedViewStore();
        var key = new ViewKey("test");
        var first = store.Publish(key, "one", sourceVersion: 2);
        var same = store.Publish(key, "one", sourceVersion: 3);
        var stale = store.Publish(key, "stale", sourceVersion: 1);

        Assert.Equal(1, first.ViewRevision);
        Assert.Equal(first.ViewRevision, same.ViewRevision);
        Assert.Equal(first.ViewRevision, stale.ViewRevision);
        var read = store.ReadIfChanged<string>(key, 0);
        Assert.True(read.Modified);
        Assert.Equal("one", read.Snapshot);
        Assert.False(store.ReadIfChanged<string>(key, read.ViewRevision).Modified);
    }

    [Fact]
    public void Subscription_IsReleasedAndOnlyChangedViewsNotify()
    {
        var store = new RevisionedViewStore();
        var notifications = new List<(ViewKey Key, long Revision)>();
        using (store.Subscribe((key, revision) => notifications.Add((key, revision))))
        {
            store.Publish(ViewKey.SaveList, "one");
            store.Publish(ViewKey.SaveList, "one");
            store.Publish(ViewKey.SaveList, "two");
        }
        store.Publish(ViewKey.SaveList, "three");

        Assert.Equal([1L, 2L], notifications.Select(item => item.Revision));
    }

    [Fact]
    public async Task ProjectionHost_IsolatesFailureAndStopsAllLoops()
    {
        await using var host = new ProjectionHost();
        var healthyRuns = 0;
        host.AddLoop("healthy", _ =>
        {
            Interlocked.Increment(ref healthyRuns);
            return Task.CompletedTask;
        }, TimeSpan.FromMilliseconds(10));
        host.AddLoop("faulted", _ => throw new InvalidOperationException("fixture"),
            TimeSpan.FromMilliseconds(10));
        host.Start();
        // Observe completed work, not an assumed number of ticks in 80 ms.
        // The timeout bounds a real failure; it is not a performance threshold.
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (Volatile.Read(ref healthyRuns) <= 1
            || !host.Statuses.Any(item => item.Name == "healthy" && item.Health == ProjectorHealth.Healthy)
            || !host.Statuses.Any(item => item.Name == "faulted" && item.Health == ProjectorHealth.Faulted))
            await Task.Delay(10, deadline.Token);

        Assert.True(Volatile.Read(ref healthyRuns) > 1);
        Assert.Contains(host.Statuses, item =>
            item.Name == "healthy" && item.Health == ProjectorHealth.Healthy);
        Assert.Contains(host.Statuses, item =>
            item.Name == "faulted" && item.Health == ProjectorHealth.Faulted);
        host.RequestStop();
        while (host.Statuses.Any(item => item.Health != ProjectorHealth.Stopped))
            await Task.Delay(10, deadline.Token);
        Assert.All(host.Statuses, item => Assert.Equal(ProjectorHealth.Stopped, item.Health));
    }

    [Fact]
    public async Task AuthorityProjectors_RebuildViewsFromEmptyMemory()
    {
        using var temp = new TempDirectory();
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var path = Path.GetFullPath(temp.GetPath("save")).ToUpperInvariant();
        var lastPlayed = DateTimeOffset.UtcNow.AddMinutes(-3);
        var now = DateTimeOffset.UtcNow;
        await state.WritePendingBatchAsync(new CollectionBatch(
            Guid.NewGuid().ToString("D"), 1, now, now, 1, true,
            [new SaveObservation(
                path, "Sandbox", "Save", true, false, ActivityState.Inactive,
                CharacterState.Alive, LaneStatus.Succeeded, LaneStatus.Succeeded,
                LastPlayedUtc: lastPlayed)]));
        await new StateReactor().RunAsync(state);

        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            _ = await repository.AddOrGetSourceAsync(
                lease, "Sandbox/Save", path);
        }
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await scheduler.ConfigureBackupAsync(
            repositoryPath, true, TimeSpan.FromMinutes(5), now);
        var views = new RevisionedViewStore();

        await new StateProjector(state, views).ProjectOnceAsync();
        await new BackupProjector(repository, views).ProjectOnceAsync();
        await new SchedulerProjector(scheduler, views).ProjectOnceAsync();
        await new SaveDetailComposer(views).ComposeOnceAsync();

        var list = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).Snapshot!;
        Assert.Equal(lastPlayed, Assert.Single(list.Saves).LastPlayedUtc);
        var detail = views.ReadIfChanged<SaveDetailView>(
            ViewKey.SaveDetail("Sandbox/Save"), 0).Snapshot!;
        Assert.Equal("Sandbox/Save", detail.LiveSave!.SaveId);
        Assert.Empty(detail.BackupRevisions);
        Assert.True(views.ReadIfChanged<ScheduleStatusView>(
            ViewKey.ScheduleStatus, 0).Modified);
    }

    [Fact]
    public async Task TelemetryProjector_NormalizesProgressHealthAndMetrics()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "fixture");
        await store.RecordAsync("fixture", 7, "run.started");
        await store.RecordAsync(
            "fixture", 7, "workload.discovered",
            "{\"totalItems\":2,\"totalBytes\":30}");
        await store.RecordAsync(
            "fixture", 7, "file.capture.completed", "{\"bytes\":10}");
        await store.RecordAsync("fixture", 7, "run.committed");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "fixture-source", "fixture", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);

        await projector.ProjectOnceAsync();

        var operation = Assert.Single(
            views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal(OperationStatus.Succeeded, operation.Status);
        Assert.Equal(1, operation.CompletedItems);
        Assert.Equal(2, operation.TotalItems);
        Assert.Equal(10, operation.CompletedBytes);
        Assert.Equal(30, operation.TotalBytes);
        Assert.Equal(TelemetryHealth.Healthy, operation.TelemetryHealth);
        var metrics = Assert.Single(
            views.ReadIfChanged<MetricsView>(ViewKey.Metrics, 0).Snapshot!.Producers);
        Assert.Equal(10, metrics.BytesProcessed);
    }

    [Fact]
    public async Task TelemetryProjector_ShowsCopyProgressThenReturnsToBackupPhase()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "backup-worker");
        await store.RecordAsync("backup-worker", 7, "run.started");
        await store.RecordAsync("backup-worker", 7, "workload.discovered",
            "{\"totalItems\":2,\"totalBytes\":100}");
        await store.RecordAsync("backup-worker", 7, "progress.snapshot",
            "{\"phase\":\"copy\",\"completedItems\":0,\"totalItems\":2,\"completedBytes\":40,\"totalBytes\":100}");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "backup-source", "backup-worker", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);

        await projector.ProjectOnceAsync();
        var copying = Assert.Single(views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal("copy", copying.Phase);
        Assert.Equal(40, copying.CompletedBytes);

        await store.RecordAsync("backup-worker", 7, "file.capture.completed",
            "{\"bytes\":50}");
        await projector.ProjectOnceAsync();
        var backingUp = Assert.Single(views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal("capture", backingUp.Phase);
        Assert.Equal(1, backingUp.CompletedItems);
        Assert.Equal(50, backingUp.CompletedBytes);
    }

    [Fact]
    public async Task TelemetryProjector_DoesNotShowHistoricalProgressWhileReplayingPages()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "backup-worker");
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = store.DatabasePath,
            Pooling = false,
        }.ToString();
        await using (var connection = new SqliteConnection(connectionString))
        {
            await connection.OpenAsync();
            await using var filler = connection.CreateCommand();
            filler.CommandText =
                """
                WITH RECURSIVE events(n) AS (
                    SELECT 1 UNION ALL SELECT n+1 FROM events WHERE n<510
                )
                INSERT INTO telemetry_events(component,run_index,event_sequence,event_name,occurred_utc)
                SELECT 'backup-worker',1,n,'run.committed',$utc FROM events;
                """;
            filler.Parameters.AddWithValue("$utc", DateTimeOffset.UtcNow.ToString("O"));
            await filler.ExecuteNonQueryAsync();
        }
        await store.RecordAsync("backup-worker", 9, "run.started");
        await store.RecordAsync("backup-worker", 9, "workload.discovered",
            "{\"totalItems\":255}");
        await store.RecordAsync("backup-worker", 9, "run.committed");

        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "backup", "backup-worker", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views,
            maximumPagesPerProjection: 1);

        await projector.ProjectOnceAsync();
        Assert.Empty(views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations);

        await projector.ProjectOnceAsync();
        Assert.Contains(views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations,
            operation => operation.RunIndex == 9
                && operation.Status == OperationStatus.Succeeded);

        catalog.SetWorkflow("backup", new WorkflowOperation(
            "active", "backup", 9, OperationStatus.Running, DateTimeOffset.UtcNow));
        var activeViews = new RevisionedViewStore();
        await new TelemetryProjectionHost(catalog, activeViews,
            maximumPagesPerProjection: 1).ProjectOnceAsync();
        Assert.Contains(activeViews.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations,
            operation => operation.OperationId == "active"
                && operation.Status == OperationStatus.Running);
    }

    [Fact]
    public async Task TelemetryProjector_DoesNotShowStaleUnfinishedRunAfterReplay()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "backup-worker");
        await store.RecordAsync("backup-worker", 1, "run.started");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "backup", "backup-worker", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();

        await new TelemetryProjectionHost(catalog, views).ProjectOnceAsync(
            DateTimeOffset.UtcNow.AddMinutes(1));

        Assert.Empty(views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations);
    }

    [Fact]
    public async Task TelemetryProjector_UsesAbsoluteProgressSnapshotsWithoutLogNoise()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "archive-worker");
        await store.RecordAsync("archive-worker", 33, "run.started");
        await store.RecordAsync("archive-worker", 33, "progress.snapshot",
            "{\"phase\":\"scan\",\"completedItems\":5,\"totalItems\":5,\"completedBytes\":50,\"totalBytes\":50}");
        await store.RecordAsync("archive-worker", 33, "progress.snapshot",
            "{\"phase\":\"import\",\"completedItems\":2,\"totalItems\":5,\"completedBytes\":20,\"totalBytes\":50}");
        await store.RecordAsync("archive-worker", 33, "progress.snapshot",
            "{\"phase\":\"import\",\"completedItems\":5,\"totalItems\":5,\"completedBytes\":50,\"totalBytes\":50}");
        await store.RecordAsync("archive-worker", 33, "run.committed");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration("archive-source", "archive-worker",
            identity, store.DatabasePath, TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        await new TelemetryProjectionHost(catalog, views).ProjectOnceAsync();

        var operation = Assert.Single(
            views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal(OperationStatus.Succeeded, operation.Status);
        Assert.Equal("import", operation.Phase);
        Assert.Equal(5, operation.CompletedItems);
        Assert.Equal(50, operation.CompletedBytes);
        var metrics = Assert.Single(
            views.ReadIfChanged<MetricsView>(ViewKey.Metrics, 0).Snapshot!.Producers);
        Assert.Equal(100, metrics.BytesProcessed);
        Assert.DoesNotContain(views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries,
            item => item.EventName == "progress.snapshot");
    }

    [Fact]
    public async Task TelemetryProjector_ProjectsFilteredStructuredLogsWithoutFileNoise()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "fixture");
        await store.RecordAsync("fixture", 17, "run.started", "{\"kind\":\"fixture\"}");
        await store.RecordAsync("fixture", 17, "capture.started");
        await store.RecordAsync("fixture", 17, "file.capture.completed", "{\"bytes\":10}");
        await store.RecordAsync("fixture", 17, "operation.heartbeat");
        await store.RecordAsync("fixture", 17, "run.failed", "{\"reason\":\"fixture\"}");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "fixture-source", "fixture", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);
        projector.ConfigureLogs(new LogProjectionOptions(LogLevel.Warning, 100));

        await projector.ProjectOnceAsync();
        await projector.ProjectOnceAsync();

        var warningLogs = views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!;
        var failure = Assert.Single(warningLogs.Entries);
        Assert.Equal(LogLevel.Error, failure.Level);
        Assert.Equal("run.failed", failure.EventName);
        Assert.Equal(17, failure.RunIndex);
        Assert.Contains("reason", failure.PayloadJson);

        projector.ConfigureLogs(new LogProjectionOptions(LogLevel.Trace, 100));
        await projector.ProjectOnceAsync();

        var allLogs = views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!;
        Assert.Equal(3, allLogs.Entries.Count);
        Assert.Contains(allLogs.Entries, item => item.EventName == "run.started");
        Assert.Contains(allLogs.Entries, item => item.EventName == "capture.started");
        Assert.DoesNotContain(allLogs.Entries, item => item.EventName.StartsWith("file."));
        Assert.DoesNotContain(allLogs.Entries, item => item.EventName == "operation.heartbeat");
        Assert.Equal(allLogs.Entries.Count, allLogs.Entries.Select(item => item.EntryId).Distinct().Count());
    }

    [Fact]
    public async Task TelemetryProjector_RoutineChecksAreTraceButFailuresRemainVisible()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "state-scheduler");
        await store.RecordAsync("state-scheduler", 1, "tick.completed", "{\"Outcome\":\"Succeeded\"}");
        await store.RecordAsync("state-scheduler", 2, "tick.completed", "{\"outcome\":\"Failed\"}");
        await store.RecordAsync("state-scheduler", 3, "tick.completed", "{\"Outcome\":\"Degraded\"}");
        await store.RecordAsync("state-scheduler", 4, "tick.completed", "{\"Outcome\":\"Unknown\"}");
        await store.RecordAsync("state-scheduler", 5, "collector.completed");
        await store.RecordAsync("state-scheduler", 6, "reactor.completed");
        await store.RecordAsync("state-scheduler", 7, "state-runner.completed");
        await store.RecordAsync("state-scheduler", 8, "run.committed");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "fixture", "state-scheduler", identity, store.DatabasePath, TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);

        await projector.ProjectOnceAsync();
        var visible = views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries;
        Assert.Equal(3, visible.Count);
        Assert.Contains(visible, item => item.RunIndex == 2 && item.Level == LogLevel.Error);
        Assert.Contains(visible, item => item.RunIndex == 3 && item.Level == LogLevel.Warning);
        Assert.Contains(visible, item => item.RunIndex == 4 && item.Level == LogLevel.Warning);
        Assert.DoesNotContain(visible, item => item.EventName == "run.committed");

        projector.ConfigureLogs(new LogProjectionOptions(LogLevel.Trace, 100));
        await projector.ProjectOnceAsync();
        var all = views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries;
        Assert.Equal(8, all.Count);
        Assert.Equal(4, all.Count(item => item.Level == LogLevel.Trace));
    }

    [Fact]
    public async Task TelemetryProjector_KeepsRunnerAndMaintenanceFailuresVisibleAtWarningLevel()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "maintenance-worker");
        await store.RecordAsync("maintenance-worker", 1, "runner.completed",
            """{"outcome":"Failed","failureCode":"capture-failed"}""");
        await store.RecordAsync("maintenance-worker", 2, "maintenance.packcompaction.completed",
            """{"status":"Degraded","details":"failed-files=1"}""");
        await store.RecordAsync("maintenance-worker", 3, "runner.completed",
            """{"outcome":"Succeeded"}""");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "maintenance", "maintenance-worker", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        await new TelemetryProjectionHost(catalog, views).ProjectOnceAsync();

        var logs = views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries;
        Assert.Equal(2, logs.Count);
        Assert.Contains(logs, item => item.RunIndex == 1 && item.Level == LogLevel.Error);
        Assert.Contains(logs, item => item.RunIndex == 2 && item.Level == LogLevel.Warning);
    }

    [Fact]
    public async Task TelemetryProjector_DrainsMoreThanOnePageInSingleProjection()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "fixture");
        await store.RecordAsync("fixture", 7, "run.started");
        for (var index = 0; index < 600; index++)
        {
            await store.RecordAsync(
                "fixture", 7, "file.capture.completed", "{\"bytes\":1}");
        }
        await store.RecordAsync("fixture", 7, "run.committed");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "fixture-source", "fixture", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();

        await new TelemetryProjectionHost(catalog, views).ProjectOnceAsync();

        var operation = Assert.Single(
            views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal(600, operation.CompletedItems);
        Assert.Equal(600, operation.CompletedBytes);
        Assert.Equal(OperationStatus.Succeeded, operation.Status);
    }

    [Fact]
    public async Task TelemetryProjector_DropsRunsNoLongerRetainedByProducer()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "fixture");
        await store.RecordAsync("fixture", 1, "run.committed");
        await store.RecordAsync("fixture", 2, "run.committed");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "fixture-source", "fixture", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);
        await projector.ProjectOnceAsync();
        Assert.Equal(2, views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations.Count);

        await store.TrimAsync("fixture", retainRuns: 1, maxDatabaseMib: 64);
        await projector.ProjectOnceAsync();

        var remaining = Assert.Single(views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal(2, remaining.RunIndex);
    }

    [Fact]
    public async Task TelemetryProjector_ResetsCursorWhenInstanceChanges()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "fixture");
        await store.RecordAsync("fixture", 1, "run.started");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "source", "fixture", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);
        await projector.ProjectOnceAsync();

        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = store.DatabasePath,
            Pooling = false,
        }.ToString();
        await using (var connection = new SqliteConnection(connectionString))
        {
            await connection.OpenAsync();
            await using var replace = connection.CreateCommand();
            replace.CommandText =
                "UPDATE process_telemetry_info SET telemetry_instance_id=$instance; "
                + "DELETE FROM telemetry_events;";
            replace.Parameters.AddWithValue("$instance", Guid.NewGuid().ToString("D"));
            await replace.ExecuteNonQueryAsync();
        }
        await store.RecordAsync("fixture", 2, "run.started");

        await projector.ProjectOnceAsync();

        var operations = views.ReadIfChanged<OperationsView>(
            ViewKey.Operations, 0).Snapshot!.Operations;
        Assert.DoesNotContain(operations, item => item.RunIndex == 1);
        Assert.Contains(operations, item => item.RunIndex == 2);
    }

    [Fact]
    public async Task TelemetryProjector_KeepsRunningCardWhenTelemetryIsMissing()
    {
        using var temp = new TempDirectory();
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "missing", "backup", "identity", temp.GetPath("missing.db"),
            TelemetryDatabaseKind.Backup, true,
            new WorkflowOperation(
                "operation", "Backup", 9, OperationStatus.Running,
                DateTimeOffset.UtcNow)));
        var views = new RevisionedViewStore();

        await new TelemetryProjectionHost(catalog, views).ProjectOnceAsync();

        var operation = Assert.Single(
            views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations);
        Assert.Equal(OperationStatus.Running, operation.Status);
        Assert.Equal(TelemetryHealth.Waiting, operation.TelemetryHealth);
        Assert.Equal("running-progress-unavailable", operation.Message);
    }

    [Fact]
    public async Task TelemetryProjector_WaitsForNewDatabaseSchemaWithoutLoggingAnError()
    {
        using var temp = new TempDirectory();
        var now = DateTimeOffset.UtcNow;
        var identity = temp.GetPath("archive-export");
        var databasePath = Path.Combine(
            ComponentRuntimePaths.GetComponentDirectory(identity, "archive-worker"),
            "telemetry.db");
        Directory.CreateDirectory(Path.GetDirectoryName(databasePath)!);
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Pooling = false,
        }.ToString()))
            await connection.OpenAsync();

        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "archive-export", "archive-worker", identity, databasePath,
            TelemetryDatabaseKind.Process, true,
            new WorkflowOperation("export", "export", 1, OperationStatus.Running, now)));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);

        await projector.ProjectOnceAsync(now);
        Assert.Equal(TelemetryHealth.Waiting, Assert.Single(
            views.ReadIfChanged<TelemetrySourcesView>(ViewKey.TelemetrySources, 0)
                .Snapshot!.Sources).Health);
        Assert.DoesNotContain(
            views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries,
            item => item.EventName == "telemetry.source.unreadable");

        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "archive-worker");
        await store.RecordAsync("archive-worker", 1, "run.started");
        await projector.ProjectOnceAsync(now.AddMilliseconds(100));
        Assert.Equal(TelemetryHealth.Healthy, Assert.Single(
            views.ReadIfChanged<TelemetrySourcesView>(ViewKey.TelemetrySources, 0)
                .Snapshot!.Sources).Health);
        Assert.DoesNotContain(
            views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries,
            item => item.EventName == "telemetry.source.unreadable");
    }

    [Fact]
    public async Task TelemetryProjector_ReportsDatabaseThatNeverFinishesInitializing()
    {
        using var temp = new TempDirectory();
        var now = DateTimeOffset.UtcNow;
        var databasePath = temp.GetPath("unfinished.db");
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Pooling = false,
        }.ToString()))
            await connection.OpenAsync();
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "unfinished", "archive-worker", "unfinished", databasePath,
            TelemetryDatabaseKind.Process, true,
            new WorkflowOperation("export", "export", 1, OperationStatus.Running, now)));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);

        await projector.ProjectOnceAsync(now);
        await projector.ProjectOnceAsync(now.AddSeconds(3));

        Assert.Equal(TelemetryHealth.Unreadable, Assert.Single(
            views.ReadIfChanged<TelemetrySourcesView>(ViewKey.TelemetrySources, 0)
                .Snapshot!.Sources).Health);
        Assert.Contains(
            views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries,
            item => item.EventName == "telemetry.source.unreadable");
    }

    [Fact]
    public async Task TelemetryProjector_DistinguishesDisabledStaleUnreadableAndUnsupported()
    {
        using var temp = new TempDirectory();
        var now = DateTimeOffset.UtcNow;
        var invalidDatabase = temp.GetPath("invalid.db");
        await File.WriteAllTextAsync(invalidDatabase, "not sqlite");
        var futureIdentity = temp.GetPath("future");
        var future = await ProcessTelemetryStore.CreateForIdentityAsync(
            futureIdentity, "future");
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = future.DatabasePath,
            Pooling = false,
        }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText =
                "UPDATE process_telemetry_info SET schema_version=999 WHERE singleton=1;";
            await command.ExecuteNonQueryAsync();
        }

        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "disabled", "fixture", "disabled", temp.GetPath("disabled.db"),
            TelemetryDatabaseKind.Process, false));
        catalog.Register(new TelemetrySourceRegistration(
            "stale", "fixture", "stale", temp.GetPath("missing.db"),
            TelemetryDatabaseKind.Process, true,
            new WorkflowOperation(
                "stale-op", "backup", 1, OperationStatus.Running,
                now.AddMinutes(-1))));
        catalog.Register(new TelemetrySourceRegistration(
            "unreadable", "fixture", "unreadable", invalidDatabase,
            TelemetryDatabaseKind.Process, true));
        catalog.Register(new TelemetrySourceRegistration(
            "unsupported", "future", futureIdentity, future.DatabasePath,
            TelemetryDatabaseKind.Process, true));
        var views = new RevisionedViewStore();

        await new TelemetryProjectionHost(
            catalog, views, TimeSpan.FromSeconds(10)).ProjectOnceAsync(now);

        var sources = views.ReadIfChanged<TelemetrySourcesView>(
            ViewKey.TelemetrySources, 0).Snapshot!.Sources.ToDictionary(item => item.SourceId);
        Assert.Equal(TelemetryHealth.Disabled, sources["disabled"].Health);
        Assert.Equal(TelemetryHealth.Stale, sources["stale"].Health);
        Assert.Equal(TelemetryHealth.Unreadable, sources["unreadable"].Health);
        Assert.Equal(TelemetryHealth.UnsupportedSchema, sources["unsupported"].Health);
    }

    [Fact]
    public async Task TelemetryProjector_DoesNotMarkCompletedWorkflowStale()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "fixture");
        await store.RecordAsync("fixture", 8, "run.committed");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "source", "fixture", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true,
            new WorkflowOperation(
                "operation", "backup", 8, OperationStatus.Succeeded,
                DateTimeOffset.UtcNow.AddMinutes(-5))));
        var views = new RevisionedViewStore();

        await new TelemetryProjectionHost(
            catalog, views, TimeSpan.FromSeconds(1)).ProjectOnceAsync(
            DateTimeOffset.UtcNow.AddMinutes(5));

        var health = Assert.Single(views.ReadIfChanged<TelemetrySourcesView>(
            ViewKey.TelemetrySources, 0).Snapshot!.Sources);
        Assert.Equal(TelemetryHealth.Healthy, health.Health);
    }

    [Fact]
    public async Task TelemetryProjector_DoesNotUsePreviousRunHeartbeatForNewWorkflow()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "backup-worker");
        await store.RecordAsync("backup-worker", 1, "run.committed");
        var now = DateTimeOffset.UtcNow;
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = store.DatabasePath,
            Pooling = false,
        }.ToString()))
        {
            await connection.OpenAsync();
            await using var backdate = connection.CreateCommand();
            backdate.CommandText =
                "UPDATE telemetry_events SET occurred_utc=$old WHERE run_index=1;";
            backdate.Parameters.AddWithValue("$old", now.AddMinutes(-1).ToString("O"));
            await backdate.ExecuteNonQueryAsync();
        }

        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "backup", "backup-worker", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true,
            new WorkflowOperation("new-backup", "backup", 2,
                OperationStatus.Running, now.AddSeconds(-2))));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views,
            TimeSpan.FromSeconds(10));

        await projector.ProjectOnceAsync(now);
        Assert.Equal(TelemetryHealth.Waiting, Assert.Single(views.ReadIfChanged<TelemetrySourcesView>(
            ViewKey.TelemetrySources, 0).Snapshot!.Sources).Health);
        Assert.DoesNotContain(views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries,
            item => item.EventName == "telemetry.source.stale");

        await store.RecordAsync("backup-worker", 2, "run.started");
        await projector.ProjectOnceAsync(now.AddSeconds(1));
        Assert.Equal(TelemetryHealth.Healthy, Assert.Single(views.ReadIfChanged<TelemetrySourcesView>(
            ViewKey.TelemetrySources, 0).Snapshot!.Sources).Health);

        await projector.ProjectOnceAsync(now.AddSeconds(20));
        Assert.Equal(TelemetryHealth.Stale, Assert.Single(views.ReadIfChanged<TelemetrySourcesView>(
            ViewKey.TelemetrySources, 0).Snapshot!.Sources).Health);
    }

    [Fact]
    public async Task TelemetryProjector_DoesNotReportStaleWhileReplayingEarlierRuns()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "fixture");
        var now = DateTimeOffset.UtcNow;
        await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = store.DatabasePath,
            Pooling = false,
        }.ToString()))
        {
            await connection.OpenAsync();
            await using var history = connection.CreateCommand();
            history.CommandText =
                """
                WITH RECURSIVE events(n) AS (
                    SELECT 1 UNION ALL SELECT n+1 FROM events WHERE n<512
                )
                INSERT INTO telemetry_events(component,run_index,event_sequence,event_name,occurred_utc)
                SELECT 'fixture',1,n,'run.committed',$old FROM events;
                """;
            history.Parameters.AddWithValue("$old", now.AddMinutes(-1).ToString("O"));
            await history.ExecuteNonQueryAsync();
        }
        await store.RecordAsync("fixture", 2, "run.started");
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "fixture", "fixture", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true,
            new WorkflowOperation("new-run", "backup", 2,
                OperationStatus.Running, now.AddSeconds(-20))));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views,
            TimeSpan.FromSeconds(10), maximumPagesPerProjection: 1);

        await projector.ProjectOnceAsync(now);
        Assert.Equal(TelemetryHealth.Waiting, Assert.Single(views.ReadIfChanged<TelemetrySourcesView>(
            ViewKey.TelemetrySources, 0).Snapshot!.Sources).Health);
        Assert.DoesNotContain(views.ReadIfChanged<LogsView>(ViewKey.Logs, 0).Snapshot!.Entries,
            item => item.EventName == "telemetry.source.stale");

        await projector.ProjectOnceAsync(now);
        Assert.Equal(TelemetryHealth.Healthy, Assert.Single(views.ReadIfChanged<TelemetrySourcesView>(
            ViewKey.TelemetrySources, 0).Snapshot!.Sources).Health);
    }

    [Fact]
    public async Task TelemetryProjector_ExpiresSuccessAndFailedTransientWorkflows()
    {
        using var temp = new TempDirectory();
        var now = DateTimeOffset.UtcNow;
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "success", "archive-worker", temp.GetPath("success"),
            temp.GetPath("success.db"), TelemetryDatabaseKind.Process, true,
            new WorkflowOperation(
                "success-op", "export", 10, OperationStatus.Succeeded,
                now.AddSeconds(-10), now.AddSeconds(-6)),
            Transient: true));
        catalog.Register(new TelemetrySourceRegistration(
            "failure", "archive-worker", temp.GetPath("failure"),
            temp.GetPath("failure.db"), TelemetryDatabaseKind.Process, true,
            new WorkflowOperation(
                "failure-op", "import", 11, OperationStatus.Failed,
                now.AddSeconds(-10), now.AddSeconds(-6)),
            Transient: true));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);

        await projector.ProjectOnceAsync(now);

        var first = views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!;
        Assert.DoesNotContain(first.Operations, item => item.OperationId == "success-op");
        Assert.Contains(first.Operations, item => item.OperationId == "failure-op");

        await projector.ProjectOnceAsync(now.AddSeconds(5));

        var second = views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!;
        Assert.DoesNotContain(second.Operations, item => item.OperationId == "failure-op");
        Assert.Empty(catalog.Snapshot());
    }

    [Fact]
    public async Task TelemetryProjector_ExpiresFailedPersistentWorkflowAndShowsNextRun()
    {
        using var temp = new TempDirectory();
        var now = DateTimeOffset.UtcNow;
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "backup-worker", "backup-worker", temp.GetPath("backup"),
            temp.GetPath("backup.db"), TelemetryDatabaseKind.Backup, true,
            new WorkflowOperation("failed-op", "backup", 1, OperationStatus.Failed,
                now.AddSeconds(-2), now)));
        var views = new RevisionedViewStore();
        var projector = new TelemetryProjectionHost(catalog, views);

        await projector.ProjectOnceAsync(now.AddSeconds(9));
        Assert.Contains(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations,
            item => item.OperationId == "failed-op");

        await projector.ProjectOnceAsync(now.AddSeconds(11));
        Assert.DoesNotContain(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations,
            item => item.OperationId == "failed-op");
        Assert.Single(catalog.Snapshot());

        catalog.SetWorkflow("backup-worker", new WorkflowOperation(
            "next-op", "backup", 2, OperationStatus.Running, now.AddSeconds(12)));
        await projector.ProjectOnceAsync(now.AddSeconds(12));
        Assert.Contains(views.ReadIfChanged<OperationsView>(ViewKey.Operations, 0).Snapshot!.Operations,
            item => item.OperationId == "next-op" && item.Status == OperationStatus.Running);
    }
}
