using System.Globalization;
using System.Text;
using System.Text.Json;

namespace PzTools.Process.Contracts.GameRuntime;

public enum WorldPhase { Unknown, Menu, Loading, Ready, Unloading }
public enum GamePause { Unknown, Running, Paused }
// Live JVM facts, deliberately separate from the persisted players.db CharacterState.
public enum RuntimeCharacterLife { Unknown, Alive, Dead }
public enum RuntimeSleep { Unknown, Awake, Asleep }
public enum RuntimeMode { Unsupported, LocalSinglePlayer, Networked }
public enum RuntimeQuality { Unknown, Fresh, Stale, Unsupported, Ambiguous, Offline }
[Flags]
public enum ScheduleHold { None = 0, Disabled = 1, NoWorld = 2, GamePaused = 4, Unknown = 8, Unsupported = 16, Ambiguous = 32, Sleeping = 64, GameOffline = 128, CharacterDead = 256 }
public enum ScheduleDisposition { Default, Preserve, Consume, CompletionUnknown }

/// <summary>Durations belong to one observer/clock epoch, never to the host's UTC clock.</summary>
public sealed record RuntimeSnapshot(
    string ProcessSession, string ObserverEpoch, string WorldSession, long ClockEpoch,
    long EligibilityEpoch, long Sequence, WorldPhase Phase, GamePause Pause,
    RuntimeMode Mode, int SpeedLevel, long ActiveMilliseconds, long SampleAgeMilliseconds,
    string? SavePath, string? GameVersion = null, RuntimeCharacterLife CharacterLife = RuntimeCharacterLife.Unknown, string? CharacterSession = null, string? DeathId = null, RuntimeSaveExecution? LastSave = null, RuntimeSleep Sleep = RuntimeSleep.Unknown,
    // The most the game's Java heap may grow to, in megabytes (STATE5 on): the memory it was started with. Not part of
    // the semantic key, as it does not change while the game runs.
    long? HeapMaximumMegabytes = null)
{
    public const string Capabilities = "runtime.snapshot.v1,runtime.active-clock.v1,save.guarded.v1";
    public string SemanticKey => $"{ProcessSession}/{ObserverEpoch}/{WorldSession}/{ClockEpoch}/{EligibilityEpoch}/{Phase}/{Pause}/{Mode}/{SavePath}/{GameVersion}/{CharacterLife}/{CharacterSession}/{DeathId}/{LastSave?.SemanticKey}/{Sleep}";
    public bool IsWorldReady => Phase == WorldPhase.Ready && Mode == RuntimeMode.LocalSinglePlayer && SavePath is not null;
    /// <summary>
    /// The observer's initial snapshot, repeated until the game's main loop first runs. A game that runs
    /// but cannot be read is sampled too: its Unknown moves past sequence 0 within a tenth of a second.
    /// </summary>
    public bool IsBeforeFirstFrame => Sequence == 0 && Phase == WorldPhase.Unknown;
    public RuntimeSnapshot Validate()
    {
        if (!Id(ProcessSession) || !Id(ObserverEpoch) || !Id(WorldSession)
            || ClockEpoch < 0 || EligibilityEpoch < 0 || Sequence < 0 || ActiveMilliseconds < 0
            || SampleAgeMilliseconds < 0 || !Enum.IsDefined(Phase) || !Enum.IsDefined(Pause)
            || !Enum.IsDefined(Mode) || SpeedLevel is < -1 or > 4
            || !Enum.IsDefined(Sleep) || !Enum.IsDefined(CharacterLife) || CharacterSession is not null && !Id(CharacterSession)
            || DeathId is not null && (!Id(DeathId) || CharacterLife != RuntimeCharacterLife.Dead)
            || CharacterLife != RuntimeCharacterLife.Unknown && (!IsWorldReady || CharacterSession is null)
            || GameVersion is { Length: > 80 } || GameVersion?.IndexOf('\0') >= 0
            || SavePath is { Length: > 4096 } || SavePath?.IndexOf('\0') >= 0
            || SavePath is not null && !Path.IsPathFullyQualified(SavePath)
            || HeapMaximumMegabytes is < 0 or > 1L << 30
            || Phase == WorldPhase.Ready && SavePath is null)
            throw new InvalidDataException("Invalid runtime snapshot.");
        LastSave?.Validate();
        // Java may report Windows paths with forward slashes. Normalize once at ingress,
        // before semantic keys or target comparisons, without probing the filesystem.
        var normalized = SavePath is null ? null : Path.TrimEndingDirectorySeparator(Path.GetFullPath(SavePath));
        return StringComparer.Ordinal.Equals(normalized, SavePath) ? this : this with { SavePath = normalized };
    }
    internal static bool Id(string? value) => value is { Length: 32 } && Guid.TryParseExact(value, "N", out _);
    public static RuntimeSnapshot ParseWire(string line)
    {
        var p = line.Split('\t');
        if (!(p.Length == 15 && p[0] == "STATE1" || p.Length == 16 && p[0] == "STATE2" || p.Length == 20 && p[0] == "STATE3" || p.Length == 21 && p[0] == "STATE4"
            || p.Length == 22 && p[0] == "STATE5")) throw new InvalidDataException("Unsupported runtime frame.");
        static long Number(string value) => long.Parse(value, NumberStyles.None, CultureInfo.InvariantCulture);
        static T Kind<T>(string value) where T : struct, Enum =>
            Enum.TryParse<T>(value, false, out var result) && Enum.IsDefined(result)
                ? result : throw new InvalidDataException("Unknown runtime state.");
        return new RuntimeSnapshot(p[1], p[2], p[3], Number(p[4]), Number(p[5]), Number(p[6]),
            Kind<WorldPhase>(p[7]), Kind<GamePause>(p[8]), Kind<RuntimeMode>(p[9]),
            int.Parse(p[10], CultureInfo.InvariantCulture), Number(p[11]), Number(p[12]),
            p[13] == "-" ? null : new UTF8Encoding(false, true).GetString(Convert.FromBase64String(p[13])), p.Length >= 16 && p[15] != "-" ? new UTF8Encoding(false, true).GetString(Convert.FromBase64String(p[15])) : null, p.Length >= 19 ? Kind<RuntimeCharacterLife>(p[16]) : RuntimeCharacterLife.Unknown, p.Length >= 19 && p[17] != "-" ? p[17] : null, p.Length >= 19 && p[18] != "-" ? p[18] : null, p.Length >= 20 && p[19] != "-" ? RuntimeSaveExecution.Parse(p[19]) : null, p.Length >= 21 ? Kind<RuntimeSleep>(p[20]) : RuntimeSleep.Unknown,
            p.Length >= 22 ? Heap(p[21]) : null)
            .RequireCapabilities(p[14]).Validate();
    }
    // Only said for the player to see: a heap Java reports as having no limit (Long.MAX_VALUE, shifted) is no heap
    // to show, not a frame to refuse.
    private static long? Heap(string value) =>
        long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var megabytes) && megabytes <= 1L << 30 ? megabytes : null;
    private RuntimeSnapshot RequireCapabilities(string value)
    {
        if (value.Length > 1024) throw new InvalidDataException("Oversized capability list.");
        var available = value.Split(',', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
        if (!Capabilities.Split(',').All(available.Contains))
            throw new InvalidDataException("Required runtime capabilities are unavailable.");
        return this; // Future optional capabilities do not invalidate this version of the snapshot contract.
    }
}

/// <summary>Current state, not a complete event history. Only committed semantic revisions may be published.</summary>
public sealed record RuntimeObservation(string StreamEpoch, RuntimeQuality Quality, RuntimeSnapshot? Snapshot,
    long StateRevision = 0, long AgeMilliseconds = 0, string? Reason = null, string AuthorityEpoch = "",
    RuntimeExtensionStatus? Extension = null,
    IReadOnlyDictionary<string, RuntimeExtensionStatus>? Extensions = null)
{
    /// <summary>
    /// A module's own status. <see cref="Extension"/> is about the connection as a whole and stands
    /// for any module that has not reported on its own.
    /// </summary>
    public RuntimeExtensionStatus? ExtensionFor(string moduleId) =>
        Extensions is not null && Extensions.TryGetValue(moduleId, out var own) ? own : Extension;
    public string SemanticKey => $"{StreamEpoch}/{Quality}/{Snapshot?.SemanticKey}/{Reason}";
    public bool IsFresh => Quality == RuntimeQuality.Fresh && AgeMilliseconds <= 2000
        && Snapshot is { SampleAgeMilliseconds: <= 2000 };
    public static RuntimeObservation Unknown(string? reason = null) => new("", RuntimeQuality.Unknown, null, Reason: reason);
    /// <summary>
    /// The played character is dead. Periodic backups of a dead character only push the backups
    /// made while it was alive out of the retained history, so they wait for a new life.
    /// </summary>
    public bool IsCharacterDead => IsFresh && Snapshot is { IsWorldReady: true, CharacterLife: RuntimeCharacterLife.Dead };
    /// <summary>
    /// Connected, but the game has not run a frame yet: its observer samples on the main loop, which
    /// starts only after the initial load, and that load can take minutes.
    /// </summary>
    public const string GameStartingReason = "game-starting";
    /// <summary>
    /// Connected, outside a world, and the game has stopped sampling: its main loop is busy loading or unloading.
    /// Returning to the main menu reloads every mod, which can take minutes. A known state, not a lost link.
    /// </summary>
    public const string GameBusyReason = "game-busy";
    /// <summary>The game still runs a bridge older than this app's; it connects again after a game restart.</summary>
    public const string RestartRequiredReason = "runtime-restart-required";
    /// <summary>The game was started with connecting turned off by a launch option.</summary>
    public const string AttachDisabledReason = "runtime-attach-disabled";
    /// <summary>
    /// A game is running but its state cannot be read: the connection failed, or it answers without
    /// a recognisable game state (for example after a game update). An absent game, a second game,
    /// multiplayer, a game still starting and a loading world are known states, not an unusable link.
    /// </summary>
    public bool IsLinkUnusable => Quality is RuntimeQuality.Unknown && Reason != GameStartingReason
        || Quality is RuntimeQuality.Stale && Reason != GameBusyReason
        || Quality == RuntimeQuality.Fresh && Snapshot is { Phase: WorldPhase.Unknown };
    /// <summary>The running game's version, only while it has this save loaded; a save records no version itself.</summary>
    public string? GameVersionFor(string savePath) =>
        IsFresh && Snapshot is { IsWorldReady: true, GameVersion: { } version } && !string.IsNullOrWhiteSpace(version)
        && StringComparer.OrdinalIgnoreCase.Equals(Snapshot.SavePath, Path.TrimEndingDirectorySeparator(Path.GetFullPath(savePath)))
            ? version.Trim() : null;
    public RuntimeObservation Validate()
    {
        if (!Enum.IsDefined(Quality) || StateRevision < 0 || AgeMilliseconds < 0
            || StreamEpoch is null || StreamEpoch.Length > 32 || AuthorityEpoch is null
            || AuthorityEpoch.Length != 0 && !RuntimeSnapshot.Id(AuthorityEpoch) || Reason?.Length > 200 || Quality == RuntimeQuality.Fresh && !RuntimeSnapshot.Id(StreamEpoch))
            throw new InvalidDataException("Invalid runtime observation.");
        var normalized = Snapshot?.Validate();
        Extension?.Validate();
        if (Extensions is { } modules)
        {
            if (modules.Count > 64) throw new InvalidDataException("Too many extension statuses.");
            foreach (var (id, status) in modules)
            {
                if (string.IsNullOrEmpty(id) || id.Length > 80 || status is null) throw new InvalidDataException("Invalid extension status entry.");
                status.Validate();
            }
        }
        if (Quality == RuntimeQuality.Fresh && normalized is null) throw new InvalidDataException("Missing live snapshot.");
        return ReferenceEquals(normalized, Snapshot) ? this : this with { Snapshot = normalized };
    }
}

/// <summary>A limited game-side predicate, not an arbitrary expression or remote method invocation.</summary>
public sealed record RuntimeSaveTicket(string ProcessSession, string ObserverEpoch, string WorldSession,
    long ClockEpoch, long EligibilityEpoch, long DueActiveMilliseconds, long CommandSequence, string RequestId,
    string? CharacterSession = null, string? DeathId = null)
{
    public bool IsDeath => DeathId is not null;
    public RuntimeSaveTicket Validate()
    {
        if (!RuntimeSnapshot.Id(ProcessSession) || !RuntimeSnapshot.Id(ObserverEpoch)
            || !RuntimeSnapshot.Id(WorldSession) || !RuntimeSnapshot.Id(RequestId)
            || ClockEpoch < 0 || EligibilityEpoch < 0 || DueActiveMilliseconds < 0 || CommandSequence <= 0
            || (CharacterSession is null) != (DeathId is null)
            || IsDeath && (!RuntimeSnapshot.Id(CharacterSession) || !RuntimeSnapshot.Id(DeathId) || DueActiveMilliseconds != 0))
            throw new InvalidDataException("Invalid guarded save ticket.");
        return this;
    }
    public bool MatchesDeath(RuntimeSnapshot value) => IsDeath && value.IsWorldReady
        && value.ProcessSession == ProcessSession && value.WorldSession == WorldSession
        && value.CharacterLife == RuntimeCharacterLife.Dead && value.CharacterSession == CharacterSession && value.DeathId == DeathId;
    public string Encode()
    {
        Validate();
        var text = string.Join('|', IsDeath ? "2" : "1", ProcessSession, ObserverEpoch, WorldSession,
            ClockEpoch.ToString(CultureInfo.InvariantCulture), EligibilityEpoch.ToString(CultureInfo.InvariantCulture),
            DueActiveMilliseconds.ToString(CultureInfo.InvariantCulture), CommandSequence.ToString(CultureInfo.InvariantCulture), RequestId);
        return IsDeath ? text + "|" + CharacterSession + "|" + DeathId : text;
    }
    public static RuntimeSaveTicket Parse(string value)
    {
        if (value.Length > 1024) throw new InvalidDataException("Oversized save ticket.");
        var p = value.Split('|');
        if (!(p.Length == 9 && p[0] == "1" || p.Length == 11 && p[0] == "2")) throw new InvalidDataException("Unsupported save ticket.");
        return new RuntimeSaveTicket(p[1], p[2], p[3], long.Parse(p[4], CultureInfo.InvariantCulture),
            long.Parse(p[5], CultureInfo.InvariantCulture), long.Parse(p[6], CultureInfo.InvariantCulture),
            long.Parse(p[7], CultureInfo.InvariantCulture), p[8], p.Length == 11 ? p[9] : null, p.Length == 11 ? p[10] : null).Validate();
    }
}
public static class RuntimeJson
{
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web) { IgnoreReadOnlyProperties = true };
    public static string Write<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static T Read<T>(string value) => JsonSerializer.Deserialize<T>(value, Options)
        ?? throw new InvalidDataException("Empty runtime message.");
}
