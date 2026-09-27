using Microsoft.Data.Sqlite;
using PzTools.App.Core;
using PzTools.Projections;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class SaveListStartupLoadingTests
{
    [Fact]
    public void BeforeHostPublishesAnyView_ShowsLoading_NotEmpty() =>
        Assert.Equal(SaveListPlaceholder.Loading, SaveListPresentation.Resolve(null));

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ColdStart_WaitsForAppliedDiscoveryBeforeShowingEmptyOrExistingSaves(bool hasSave)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("Saves");
        Directory.CreateDirectory(root);
        if (hasSave) await CreateSaveAsync(root);
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var views = new RevisionedViewStore();
        var projector = new StateProjector(database, views, DateTimeOffset.UtcNow);
        await projector.ProjectOnceAsync();
        var initial = Read(views);
        Assert.False((await database.ReadCurrentStateIfChangedAsync(-1)).Initialized);
        Assert.Equal(SaveListLoadState.Loading, initial.LoadState);
        Assert.Equal(SaveListPlaceholder.Loading, SaveListPresentation.Resolve(initial));
        Assert.Empty(initial.Saves);

        // The on-disk save already exists, but a pending batch isn't visible state yet.
        var collected = await new StateCollector().RunAsync(database, root, 1);
        Assert.True(collected.Batch.DiscoveryComplete);
        Assert.Equal(hasSave ? 1 : 0, collected.Batch.Saves.Count);
        Assert.True(await database.HasPendingBatchesAsync());
        await projector.ProjectOnceAsync();
        Assert.Equal(SaveListPlaceholder.Loading, SaveListPresentation.Resolve(Read(views)));

        await new StateReactor().RunAsync(database);
        await projector.ProjectOnceAsync();
        var loaded = Read(views);
        Assert.True((await database.ReadCurrentStateIfChangedAsync(-1)).Initialized);
        Assert.Equal(SaveListLoadState.Ready, loaded.LoadState);
        Assert.Equal(hasSave ? 1 : 0, loaded.Saves.Count);
        Assert.Equal(hasSave ? SaveListPlaceholder.None : SaveListPlaceholder.Empty,
            SaveListPresentation.Resolve(loaded));
        Assert.False(Directory.Exists(temp.GetPath("repository"))); // No backup is required.

        var revision = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).ViewRevision;
        for (var i = 0; i < 3; i++) await projector.ProjectOnceAsync();
        Assert.False(views.ReadIfChanged<SaveListView>(ViewKey.SaveList, revision).Modified);
        Assert.Equal(loaded.LoadState, Read(views).LoadState); // Normal polling doesn't flash a spinner.
    }

    [Fact]
    public async Task ReopeningUninitializedDatabase_DoesNotInventACompletedDiscovery()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        database = await StateDatabase.CreateOrOpenAsync(database.DatabasePath);
        var views = new RevisionedViewStore();
        await new StateProjector(database, views).ProjectOnceAsync();
        Assert.Equal(SaveListLoadState.Loading, Read(views).LoadState);
        var unchanged = await database.ReadCurrentStateIfChangedAsync(0);
        Assert.False(unchanged.Modified);
        Assert.False(unchanged.Initialized);
    }

    [Fact]
    public async Task IncompleteEmptyDiscovery_ShowsUnavailable_ThenRecoversToAConfirmedEmptyList()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var views = new RevisionedViewStore();
        var projector = new StateProjector(database, views);
        await ApplyBatchAsync(database, complete: false);
        await projector.ProjectOnceAsync();
        Assert.Equal(GameState.Unknown, Read(views).Game);
        Assert.Equal(SaveListLoadState.Unavailable, Read(views).LoadState);
        Assert.Equal(SaveListPlaceholder.Unavailable, SaveListPresentation.Resolve(Read(views)));

        await ApplyBatchAsync(database, complete: true);
        await projector.ProjectOnceAsync();
        Assert.Equal(GameState.NotPlaying, Read(views).Game);
        Assert.Equal(SaveListPlaceholder.Empty, SaveListPresentation.Resolve(Read(views)));
    }

    [Fact]
    public async Task ConfirmedEmptyDiscovery_IsPreservedOnReopen_AndOnUnchangedSnapshotReads()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        await ApplyBatchAsync(database, complete: true);
        database = await StateDatabase.CreateOrOpenAsync(database.DatabasePath);
        var snapshot = await database.ReadCurrentStateIfChangedAsync(-1);
        var unchanged = await database.ReadCurrentStateIfChangedAsync(snapshot.StateRevision);
        Assert.True(snapshot.Initialized);
        Assert.True(unchanged.Initialized);
        Assert.False(unchanged.Modified);
        var views = new RevisionedViewStore();
        await new StateProjector(database, views).ProjectOnceAsync();
        Assert.Equal(SaveListPlaceholder.Empty, SaveListPresentation.Resolve(Read(views)));
    }

    [Fact]
    public async Task CancelledReactor_DoesNotEndLoading_AndPendingBatchCanRecover()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var now = DateTimeOffset.UtcNow;
        await database.WritePendingBatchAsync(new(Guid.NewGuid().ToString("N"), 1, now, now, 0, true, []));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new StateReactor().RunAsync(
            database, cancellationToken: new CancellationToken(true)));
        var views = new RevisionedViewStore();
        var projector = new StateProjector(database, views);
        await projector.ProjectOnceAsync();
        Assert.Equal(SaveListPlaceholder.Loading, SaveListPresentation.Resolve(Read(views)));
        Assert.True(await database.HasPendingBatchesAsync());
        await new StateReactor().RunAsync(database);
        await projector.ProjectOnceAsync();
        Assert.Equal(SaveListPlaceholder.Empty, SaveListPresentation.Resolve(Read(views)));
    }

    [Fact]
    public async Task EmptyDiscoveryAfterAReadFailure_DoesNotKeepAnErrorOrInfiniteSpinner()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var views = new RevisionedViewStore();
        var projector = new StateProjector(database, views);
        await projector.ProjectOnceAsync();
        Assert.Equal(SaveListPlaceholder.Unavailable, SaveListPresentation.Resolve(Read(views), stateUnavailable: true));
        Assert.Equal(SaveListPlaceholder.Loading, SaveListPresentation.Resolve(Read(views), stateUnavailable: false));
        await ApplyBatchAsync(database, complete: true);
        await projector.ProjectOnceAsync();
        Assert.Equal(SaveListPlaceholder.Empty, SaveListPresentation.Resolve(Read(views)));
        Assert.Equal(SaveListPlaceholder.Unavailable, SaveListPresentation.Resolve(Read(views), stateUnavailable: true));
    }

    [Fact]
    public async Task UnknownActivityOrPartialRefresh_DoesNotHideAlreadyDiscoveredSaves()
    {
        using var temp = new TempDirectory();
        var database = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var now = DateTimeOffset.UtcNow;
        await database.WritePendingBatchAsync(new(Guid.NewGuid().ToString("N"), 1, now, now, 0, true,
            [new(temp.GetPath("save"), "Sandbox", "save", false, false, ActivityState.Unknown,
                CharacterState.Unknown, LaneStatus.Unavailable, LaneStatus.Unavailable)]));
        await new StateReactor().RunAsync(database);
        var views = new RevisionedViewStore();
        var projector = new StateProjector(database, views);
        await projector.ProjectOnceAsync();
        Assert.Single(Read(views).Saves);
        Assert.Equal(GameState.Unknown, Read(views).Game);
        Assert.Equal(SaveListPlaceholder.None, SaveListPresentation.Resolve(Read(views)));

        await ApplyBatchAsync(database, complete: false);
        await projector.ProjectOnceAsync();
        Assert.Single(Read(views).Saves);
        Assert.Equal(SaveListPlaceholder.None, SaveListPresentation.Resolve(Read(views), stateUnavailable: true));
    }

    [Fact]
    public void LoadStateChanges_ArePublishedEvenWithIdenticalRowsAndAuthorityRevision()
    {
        var views = new RevisionedViewStore();
        var loading = new SaveListView(0, GameState.Unknown, [], SaveListLoadState.Loading);
        var ready = loading with { LoadState = SaveListLoadState.Ready };
        var unavailable = loading with { LoadState = SaveListLoadState.Unavailable };
        Assert.False(ViewComparers.Saves.Equals(loading, ready));
        Assert.False(ViewComparers.Saves.Equals(loading, unavailable));
        Assert.False(ViewComparers.Saves.Equals(ready, unavailable));
        views.Publish(ViewKey.SaveList, loading, comparer: ViewComparers.Saves);
        var revision = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).ViewRevision;
        views.Publish(ViewKey.SaveList, ready, comparer: ViewComparers.Saves);
        Assert.True(views.ReadIfChanged<SaveListView>(ViewKey.SaveList, revision).Modified);
        revision = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).ViewRevision;
        views.Publish(ViewKey.SaveList, ready with { }, comparer: ViewComparers.Saves);
        Assert.False(views.ReadIfChanged<SaveListView>(ViewKey.SaveList, revision).Modified);
    }

    [Fact]
    public void HostStartupFailureWithoutAView_IsUnavailable_NotEmptyOrLoading() =>
        Assert.Equal(SaveListPlaceholder.Unavailable, SaveListPresentation.Resolve(null, stateUnavailable: true));

    private static SaveListView Read(RevisionedViewStore views) =>
        views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).Snapshot!;

    private static async Task ApplyBatchAsync(StateDatabase database, bool complete)
    {
        var now = DateTimeOffset.UtcNow;
        await database.WritePendingBatchAsync(new(Guid.NewGuid().ToString("N"), 1, now, now, 0, complete, []));
        await new StateReactor().RunAsync(database);
    }

    private static async Task CreateSaveAsync(string root)
    {
        var path = Path.Combine(root, "Sandbox", "existing-save");
        Directory.CreateDirectory(path);
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        { DataSource = Path.Combine(path, "players.db"), Pooling = false }.ToString());
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "CREATE TABLE localPlayers(id INTEGER,name TEXT,isDead INTEGER);"
            + "INSERT INTO localPlayers VALUES(1,'Test Player',0);";
        await command.ExecuteNonQueryAsync();
    }
}
