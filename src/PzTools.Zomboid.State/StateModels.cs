namespace PzTools.Zomboid.State;

public enum LaneStatus { Succeeded, Unavailable, Unsupported, Failed }
public enum ActivityState { Unknown, Active, Inactive }
public enum GameState { Unknown, Playing, NotPlaying, Ambiguous }
public enum CharacterState { Unknown, Alive, Dead }

public sealed record SaveObservation(
    string NormalizedPath,
    string Mode,
    string DisplayName,
    bool HasPlayersDatabase,
    bool Invalidated,
    ActivityState Activity,
    CharacterState Character,
    LaneStatus ActivityLaneStatus,
    LaneStatus CharacterLaneStatus,
    string? ErrorCode = null,
    DateTimeOffset? LastPlayedUtc = null);

public sealed record CollectionBatch(
    string BatchId,
    long RunIndex,
    DateTimeOffset StartedUtc,
    DateTimeOffset CompletedUtc,
    long ElapsedMilliseconds,
    bool DiscoveryComplete,
    IReadOnlyList<SaveObservation> Saves);

public sealed record CurrentSaveState(
    string NormalizedPath,
    string Mode,
    string DisplayName,
    ActivityState Activity,
    CharacterState Character,
    bool Stale,
    long ChangedRevision,
    DateTimeOffset? LastPlayedUtc = null,
    DateTimeOffset? ObservedUtc = null);

public sealed record CurrentStateSnapshot(
    bool Modified,
    long StateRevision,
    GameState Game,
    IReadOnlyList<CurrentSaveState> Saves);

public sealed record ReactorResult(
    IReadOnlyList<string> AppliedBatchIds,
    long BeforeRevision,
    long AfterRevision,
    int Transitions,
    int OutboxMessages);

public sealed record StateCollectionResult(
    CollectionBatch Batch,
    LaneStatus DiscoveryStatus);

public sealed record SchedulerOutboxMessage(
    string MessageId,
    string IdempotencyKey,
    string Command,
    string SaveId,
    string SourceKey,
    string SourcePath,
    string TransitionId,
    long StateRunIndex);

public sealed record StateReactorOptions(bool BackupOnDeath = false);
