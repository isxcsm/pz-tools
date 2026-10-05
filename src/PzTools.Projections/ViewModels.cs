using PzTools.Backup.Core;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Projections;

public enum ViewFreshness { Fresh, Stale }

public sealed record SaveListItemView(
    string SaveId,
    string Mode,
    string Name,
    string SourcePath,
    DateTimeOffset? LastPlayedUtc,
    string? ThumbnailKey,
    ActivityState Activity,
    CharacterState CharacterState,
    ViewFreshness Freshness,
    CharacterSnapshot? Character = null);

public enum SaveListLoadState { Loading, Ready, Unavailable }

public sealed record SaveListView(
    long StateRevision,
    GameState Game,
    IReadOnlyList<SaveListItemView> Saves,
    SaveListLoadState LoadState = SaveListLoadState.Ready);

public sealed record BackupRevisionView(
    long Revision,
    DateTimeOffset CreatedUtc,
    long LogicalSize,
    long FileCount,
    string Status,
    string ThumbnailKey,
    DateTimeOffset? LastPlayedUtc = null,
    string DisplayName = "",
    string? CharacterName = null,
    CharacterState CharacterState = CharacterState.Unknown,
    double? HoursSurvived = null,
    bool SurvivalPending = false,
    BackupKind Kind = BackupKind.Unknown,
    string? CharacterMetadataError = null,
    string? GameVersion = null);

public sealed record BackupSourceView(
    long SourceId,
    string SaveId,
    string RootPath,
    long CurrentRevision,
    IReadOnlyList<BackupRevisionView> Revisions);

public sealed record BackupCatalogView(
    long RepositoryChangeRevision,
    IReadOnlyList<BackupSourceView> Sources);

public sealed record SaveDetailView(
    string SaveId,
    SaveListItemView? LiveSave,
    IReadOnlyList<BackupRevisionView> BackupRevisions);

public sealed record ScheduleStatusView(
    long SchedulerRevision,
    SchedulerMode Mode,
    BackupTarget? CurrentTarget,
    DateTimeOffset? NextDueUtc,
    long? LastRunIndex,
    ProcessOutcome? LastOutcome,
    bool AutomaticEnabled,
    int PendingRuns,
    bool PeriodicBackupInProgress = false,
    bool PauseAware = false,
    long? RemainingMilliseconds = null,
    ScheduleHold Hold = ScheduleHold.None,
    bool CompletionUncertain = false,
    // Live presentation only; committed scheduler facts still control admission.
    WorldPhase GamePhase = WorldPhase.Unknown,
    // The game cannot be observed: NextDueUtc is a wall-clock backup of the files on disk.
    bool Fallback = false);

public sealed record SettingsView(
    string Language,
    string Theme,
    string SavesRoot,
    string BackupRoot,
    int BackupIntervalMinutes,
    int RetainedRevisions,
    bool BackupOnDeath,
    int LogDisplayLimit,
    bool UseSystemTray = false,
    bool VerifyStagedCopies = true,
    string LogRecordMinimumLevel = "Information",
    int LogMaxEntries = 100000,
    bool SaveGameBeforeBackup = true,
    bool GameSaveCountdown = true,
    bool AutomaticBackupEnabled = true,
    bool PausePeriodicDuringGame = true,
    bool RollingEnabled = false,
    bool RollingDetailed = false,
    int RollingMinutes = 2,
    HotKeySettings? HotKeys = null,
    bool CheckForUpdates = true);

public sealed record ProjectorHealthView(IReadOnlyList<ProjectorStatus> Projectors)
{
    public bool IsFaulted(string name) => Projectors.Any(item =>
        StringComparer.Ordinal.Equals(item.Name, name)
        && item.Health == ProjectorHealth.Faulted);
}
