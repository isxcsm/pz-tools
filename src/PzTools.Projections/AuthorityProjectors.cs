using PzTools.Backup.Storage.Repository;
using PzTools.Scheduling;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.Zomboid.State;

namespace PzTools.Projections;

public sealed class StateProjector(
    StateDatabase database,
    RevisionedViewStore views,
    DateTimeOffset? observedAfterUtc = null,
    Func<RuntimeObservation?>? runtime = null)
{
    private long cursor = -1;
    private bool awaitingFreshObservation = observedAfterUtc.HasValue;
    private CurrentStateSnapshot? latestSnapshot;
    private readonly CharacterProjectionCache characters = new(new CharacterNameReader().ReadSnapshotAsync);

    public async Task ProjectOnceAsync(CancellationToken cancellationToken = default)
    {
        // Revalidation may update only observation time, without a semantic revision.
        var current = await database.ReadCurrentStateIfChangedAsync(
            awaitingFreshObservation ? -1 : cursor, cancellationToken);
        if (current.Modified)
        {
            latestSnapshot = current;
            cursor = current.StateRevision;
            awaitingFreshObservation = current.Saves.Any(IsFromPreviousSession);
        }
        if (latestSnapshot is not { } snapshot) return;
        // Game files can change without a semantic state revision. Check their metadata
        // on every projection tick; equivalent views do not notify or reload images.
        var saves = snapshot.Saves.Select(state =>
            state.Stale || IsFromPreviousSession(state)
                ? state with { Activity = ActivityState.Unknown, Stale = true } : state).ToArray();
        var game = snapshot.Game;
        if (saves.Any(save => save.Stale))
        {
            var active = saves.Count(save => save.Activity == ActivityState.Active);
            game = active > 1 ? GameState.Ambiguous : active == 1 ? GameState.Playing : GameState.Unknown;
        }
        var mapped = new List<SaveListItemView>(saves.Length);
        foreach (var state in saves)
        {
            var item = Map(state);
            var path = Path.Combine(item.SourcePath, "players.db");
            // A changed thumbnail does not invalidate player parsing. Include WAL changes.
            var version = FileVersion(path) + ":wal:" + FileVersion(path + "-wal");
            var character = await characters.ReadAsync(path, version, cancellationToken);
            mapped.Add(item with { Character = character });
        }
        characters.RetainOnly(mapped.Select(item => Path.Combine(item.SourcePath, "players.db")));
        var observation = runtime?.Invoke();
        if (observation is not null)
        {
            var world = observation.Snapshot;
            bool ready = observation.IsFresh && world?.IsWorldReady == true;
            bool offline = observation.Quality == RuntimeQuality.Offline
                || observation.IsFresh && world?.Phase is WorldPhase.Menu or WorldPhase.Unloading;
            game = ready ? GameState.Playing : offline ? GameState.NotPlaying
                : observation.Quality == RuntimeQuality.Ambiguous ? GameState.Ambiguous : GameState.Unknown;
            for (int i = 0; i < mapped.Count; i++)
            {
                bool selected = ready && StringComparer.OrdinalIgnoreCase.Equals(mapped[i].SourcePath, world!.SavePath);
                mapped[i] = mapped[i] with { Activity = selected ? ActivityState.Active
                    : ready || offline ? ActivityState.Inactive : ActivityState.Unknown,
                    Freshness = ready || offline ? ViewFreshness.Fresh : ViewFreshness.Stale };
            }
        }

        // A fresh state DB can publish an empty snapshot before the first collector
        // batch is applied. Only an initialized, conclusive empty discovery is Empty.
        // Empty + Unknown after initialization is an incomplete discovery, not absence.
        var loadState = !snapshot.Initialized ? SaveListLoadState.Loading
            : snapshot.Saves.Count == 0 && snapshot.Game == GameState.Unknown
                ? SaveListLoadState.Unavailable : SaveListLoadState.Ready;
        var model = new SaveListView(
            snapshot.StateRevision,
            game,
            mapped.OrderByDescending(item => item.LastPlayedUtc)
                .ThenBy(item => item.SaveId, StringComparer.OrdinalIgnoreCase).ToArray(),
            loadState);
        views.Publish(
            ViewKey.SaveList, model, snapshot.StateRevision,
            ViewComparers.Saves);
    }

    private bool IsFromPreviousSession(CurrentSaveState state) => observedAfterUtc is { } minimum
        && (state.ObservedUtc is null || state.ObservedUtc < minimum);

    private static SaveListItemView Map(CurrentSaveState state)
    {
        var saveId = CreateSaveId(state.Mode, state.DisplayName);
        return new SaveListItemView(
            saveId,
            state.Mode,
            state.DisplayName,
            state.NormalizedPath,
            state.LastPlayedUtc,
            LiveThumbnailKey(state.NormalizedPath, saveId),
            state.Activity,
            state.Character,
            state.Stale ? ViewFreshness.Stale : ViewFreshness.Fresh);
    }

    private static string LiveThumbnailKey(string savePath, string saveId) =>
        $"live:{saveId}:players:{FileVersion(Path.Combine(savePath, "players.db"))}"
        + $":thumb:{FileVersion(Path.Combine(savePath, "thumb.png"))}";

    private static string FileVersion(string path)
    {
        try
        {
            var file = new FileInfo(path);
            return file.Exists
                ? $"{file.LastWriteTimeUtc.Ticks}:{file.Length}"
                : "missing";
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return "unavailable";
        }
    }

    internal static string CreateSaveId(string mode, string name) =>
        $"{mode.Trim().Replace('\\', '/')}/{name.Trim().Replace('\\', '/')}";
}

public sealed class BackupProjector(
    RepositoryDatabase repository,
    RevisionedViewStore views)
{
    private long cursor = -1;

    public async Task ProjectOnceAsync(CancellationToken cancellationToken = default)
    {
        var snapshot = await repository.ReadCatalogIfChangedAsync(cursor, "players.db", cancellationToken);
        if (!snapshot.Modified) return;
        var model = new BackupCatalogView(
            snapshot.RepositoryChangeRevision,
            snapshot.Sources.Select(source => new BackupSourceView(
                source.SourceId, source.SourceKey, source.RootPath, source.CurrentRevision,
                source.Revisions.Select(revision => new BackupRevisionView(
                    revision.Revision, revision.CreatedUtc, revision.LogicalSize, revision.FileCount,
                    revision.State,
                    $"repository:{repository.Identity.RepositoryId:D}:{source.SourceId}:{revision.Revision}:thumb.png",
                    revision.MetadataFileModifiedUtc, revision.DisplayName, revision.CharacterName,
                    Enum.TryParse<CharacterState>(revision.CharacterState, out var state)
                        ? state : CharacterState.Unknown,
                    revision.HoursSurvived, !revision.CharacterMetadataRead && revision.CharacterMetadataError is null,
                    revision.Kind, revision.CharacterMetadataError, revision.GameVersion)).ToArray())).ToArray());
        views.Publish(ViewKey.BackupCatalog, model, snapshot.RepositoryChangeRevision,
            ViewComparers.Backups);
        cursor = snapshot.RepositoryChangeRevision;
    }
}

public sealed class SchedulerProjector(
    SchedulerDatabase database,
    RevisionedViewStore views,
    RepositoryDatabase? repository = null,
    TimeProvider? timeProvider = null,
    bool requireActiveState = false,
    RuntimeSnapshotStore? runtimeSnapshot = null)
{
    private long cursor = -1;
    private BackupSchedulerState? cachedState;

    public async Task ProjectOnceAsync(CancellationToken cancellationToken = default)
    {
        var snapshot = await database.ReadBackupStateIfChangedAsync(cursor, cancellationToken);
        if (snapshot.Modified)
        {
            cachedState = snapshot;
            cursor = snapshot.SchedulerRevision;
        }
        else if (cachedState is { } cached) snapshot = cached;
        else return;

        var runtimeSchedule = await database.ReadRuntimeScheduleAsync(cancellationToken);
        var observation = runtimeSnapshot?.Read() ?? RuntimeObservation.Unknown("runtime-feed-disconnected");
        if (runtimeSchedule.Enabled)
        {
            var runtimeView = RuntimeScheduleProjection.Build(snapshot, runtimeSchedule, observation);
            if (repository is not null && runtimeView.RemainingMilliseconds == 0
                && runtimeSchedule.Checkpoint is { AttemptId: { } attempt } checkpoint)
            {
                var execution = await repository.TryReadWorkflowByAdmissionAsync(
                    $"runtime:{checkpoint.Generation}:{checkpoint.Slot}:{attempt}", cancellationToken);
                if (execution?.Status == WorkflowStatus.Running)
                {
                    var stages = await repository.ReadWorkflowStagesAsync(execution.RunIndex, cancellationToken);
                    runtimeView = runtimeView with { PeriodicBackupInProgress = stages.Any(stage => stage.Producer == "backup-worker") };
                }
            }
            views.Publish(ViewKey.ScheduleStatus, runtimeView, cursor, EqualityComparer<ScheduleStatusView>.Default);
            return;
        }
        var canCountDown = snapshot.AutomaticEnabled && snapshot.Mode == SchedulerMode.Continuous
            && snapshot.CurrentTarget is not null;
        if (canCountDown && requireActiveState)
        {
            var activity = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).Snapshot;
            var active = activity?.Saves.Where(save => save.Activity == ActivityState.Active
                && save.Freshness == ViewFreshness.Fresh).ToArray();
            canCountDown = activity?.Game == GameState.Playing && active is { Length: 1 }
                && StringComparer.OrdinalIgnoreCase.Equals(active[0].SourcePath, snapshot.CurrentTarget!.SourcePath);
        }
        var offline = observation.Quality == RuntimeQuality.Offline;
        if (offline) canCountDown = false;
        var nextDue = canCountDown ? snapshot.NextDueUtc : (DateTimeOffset?)null;
        var periodicInProgress = false;
        // Scheduler authority keeps the admission due until completion for crash recovery
        // and busy retries. Display the next slot once this exact periodic worker starts
        // and its due time arrives (early preparation must retain the current countdown),
        // even if the scheduler revision has not changed. Do not infer this from any
        // unrelated manual/final backup or from the mere passage of time.
        if (repository is not null && canCountDown)
        {
            var workflow = await repository.TryReadWorkflowByAdmissionAsync(
                snapshot.PeriodicAdmissionId, cancellationToken);
            if (workflow is not null)
            {
                var stages = await repository.ReadWorkflowStagesAsync(workflow.RunIndex, cancellationToken);
                if ((timeProvider ?? TimeProvider.System).GetUtcNow() >= snapshot.NextDueUtc
                    && stages.Any(stage => stage.Producer == "backup-worker"))
                {
                    nextDue = BackupScheduleTiming.NextDue(snapshot.NextDueUtc,
                        snapshot.Interval, workflow.StartedUtc);
                    periodicInProgress = workflow.Status == WorkflowStatus.Running;
                }
            }
        }
        var model = new ScheduleStatusView(
            cursor,
            snapshot.Mode,
            snapshot.CurrentTarget,
            nextDue,
            snapshot.LastRunIndex,
            snapshot.LastOutcome,
            snapshot.AutomaticEnabled,
            snapshot.PendingRuns,
            periodicInProgress,
            Hold: offline ? ScheduleHold.GameOffline | ScheduleHold.NoWorld
                : observation.IsCharacterDead ? ScheduleHold.CharacterDead : ScheduleHold.None,
            GamePhase: RuntimeScheduleProjection.ObservedGamePhase(observation));
        views.Publish(
            ViewKey.ScheduleStatus, model, cursor,
            EqualityComparer<ScheduleStatusView>.Default);
    }
}

public sealed class SaveDetailComposer(RevisionedViewStore views)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private long stateViewRevision;
    private long backupViewRevision;

    public async Task ComposeOnceAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            var state = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, stateViewRevision);
            var backup = views.ReadIfChanged<BackupCatalogView>(
                ViewKey.BackupCatalog, backupViewRevision);
            if (!state.Modified && !backup.Modified) return;
            if (state.Modified) stateViewRevision = state.ViewRevision;
            if (backup.Modified) backupViewRevision = backup.ViewRevision;
            // Both projections must finish their first pass before an empty backup list is authoritative.
            var currentState = views.ReadIfChanged<SaveListView>(ViewKey.SaveList, 0).Snapshot;
            var currentBackup = views.ReadIfChanged<BackupCatalogView>(ViewKey.BackupCatalog, 0).Snapshot;
            if (currentState is null || currentBackup is null) return;
            var liveById = currentState.Saves.ToDictionary(
                item => item.SaveId, StringComparer.OrdinalIgnoreCase);
            var backupById = currentBackup.Sources.ToDictionary(
                item => item.SaveId, StringComparer.OrdinalIgnoreCase);
            foreach (var saveId in liveById.Keys.Union(
                         backupById.Keys, StringComparer.OrdinalIgnoreCase))
            {
                liveById.TryGetValue(saveId, out var live);
                backupById.TryGetValue(saveId, out var history);
                views.Publish(
                    ViewKey.SaveDetail(saveId),
                    new SaveDetailView(saveId, live, history?.Revisions ?? []),
                    comparer: ViewComparers.Detail);
            }
        }
        finally
        {
            gate.Release();
        }
    }
}
