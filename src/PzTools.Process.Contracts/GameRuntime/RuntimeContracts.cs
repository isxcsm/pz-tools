using System.Globalization;
using System.Text;
using System.Text.Json;

namespace PzTools.Process.Contracts.GameRuntime;

public enum WorldPhase { Unknown, Menu, Loading, Ready, Unloading }
public enum GamePause { Unknown, Running, Paused }
public enum RuntimeMode { Unsupported, LocalSinglePlayer, Networked }
public enum RuntimeQuality { Unknown, Fresh, Stale, Unsupported, Ambiguous, Offline }
[Flags]
public enum ScheduleHold { None = 0, Disabled = 1, NoWorld = 2, GamePaused = 4, Unknown = 8, Unsupported = 16, Ambiguous = 32 }
public enum ScheduleDisposition { Default, Preserve, Consume, CompletionUnknown }

/// <summary>Durations belong to one observer/clock epoch, never to the host's UTC clock.</summary>
public sealed record RuntimeSnapshot(
    string ProcessSession, string ObserverEpoch, string WorldSession, long ClockEpoch,
    long EligibilityEpoch, long Sequence, WorldPhase Phase, GamePause Pause,
    RuntimeMode Mode, int SpeedLevel, long ActiveMilliseconds, long SampleAgeMilliseconds,
    string? SavePath)
{
    public const string Capabilities = "runtime.snapshot.v1,runtime.active-clock.v1,save.guarded.v1";
    public string SemanticKey => $"{ProcessSession}/{ObserverEpoch}/{WorldSession}/{ClockEpoch}/{EligibilityEpoch}/{Phase}/{Pause}/{Mode}/{SavePath}";
    public bool IsWorldReady => Phase == WorldPhase.Ready && Mode == RuntimeMode.LocalSinglePlayer && SavePath is not null;
    public RuntimeSnapshot Validate()
    {
        if (!Id(ProcessSession) || !Id(ObserverEpoch) || !Id(WorldSession)
            || ClockEpoch < 0 || EligibilityEpoch < 0 || Sequence < 0 || ActiveMilliseconds < 0
            || SampleAgeMilliseconds < 0 || !Enum.IsDefined(Phase) || !Enum.IsDefined(Pause)
            || !Enum.IsDefined(Mode) || SpeedLevel is < -1 or > 4
            || SavePath is { Length: > 4096 } || SavePath?.IndexOf('\0') >= 0
            || SavePath is not null && !Path.IsPathFullyQualified(SavePath)
            || Phase == WorldPhase.Ready && SavePath is null)
            throw new InvalidDataException("Invalid runtime snapshot.");
        // Java may report Windows paths with forward slashes. Normalize once at ingress,
        // before semantic keys or target comparisons, without probing the filesystem.
        var normalized = SavePath is null ? null : Path.TrimEndingDirectorySeparator(Path.GetFullPath(SavePath));
        return StringComparer.Ordinal.Equals(normalized, SavePath) ? this : this with { SavePath = normalized };
    }
    internal static bool Id(string? value) => value is { Length: 32 } && Guid.TryParseExact(value, "N", out _);
    public static RuntimeSnapshot ParseWire(string line)
    {
        var p = line.Split('\t');
        if (p.Length != 15 || p[0] != "STATE1") throw new InvalidDataException("Unsupported runtime frame.");
        static long Number(string value) => long.Parse(value, NumberStyles.None, CultureInfo.InvariantCulture);
        static T Kind<T>(string value) where T : struct, Enum =>
            Enum.TryParse<T>(value, false, out var result) && Enum.IsDefined(result)
                ? result : throw new InvalidDataException("Unknown runtime state.");
        return new RuntimeSnapshot(p[1], p[2], p[3], Number(p[4]), Number(p[5]), Number(p[6]),
            Kind<WorldPhase>(p[7]), Kind<GamePause>(p[8]), Kind<RuntimeMode>(p[9]),
            int.Parse(p[10], CultureInfo.InvariantCulture), Number(p[11]), Number(p[12]),
            p[13] == "-" ? null : new UTF8Encoding(false, true).GetString(Convert.FromBase64String(p[13])))
            .RequireCapabilities(p[14]).Validate();
    }
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
    long StateRevision = 0, long AgeMilliseconds = 0, string? Reason = null, string AuthorityEpoch = "")
{
    public string SemanticKey => $"{StreamEpoch}/{Quality}/{Snapshot?.SemanticKey}/{Reason}";
    public bool IsFresh => Quality == RuntimeQuality.Fresh && AgeMilliseconds <= 2000
        && Snapshot is { SampleAgeMilliseconds: <= 2000 };
    public static RuntimeObservation Unknown(string? reason = null) => new("", RuntimeQuality.Unknown, null, Reason: reason);
    public RuntimeObservation Validate()
    {
        if (!Enum.IsDefined(Quality) || StateRevision < 0 || AgeMilliseconds < 0
            || StreamEpoch is null || StreamEpoch.Length > 32 || AuthorityEpoch is null
            || AuthorityEpoch.Length != 0 && !RuntimeSnapshot.Id(AuthorityEpoch) || Reason?.Length > 200 || Quality == RuntimeQuality.Fresh && !RuntimeSnapshot.Id(StreamEpoch))
            throw new InvalidDataException("Invalid runtime observation.");
        var normalized = Snapshot?.Validate();
        if (Quality == RuntimeQuality.Fresh && normalized is null) throw new InvalidDataException("Missing live snapshot.");
        return ReferenceEquals(normalized, Snapshot) ? this : this with { Snapshot = normalized };
    }
}

/// <summary>A limited game-side predicate, not an arbitrary expression or remote method invocation.</summary>
public sealed record RuntimeSaveTicket(string ProcessSession, string ObserverEpoch, string WorldSession,
    long ClockEpoch, long EligibilityEpoch, long DueActiveMilliseconds, long CommandSequence, string RequestId)
{
    public RuntimeSaveTicket Validate()
    {
        if (!RuntimeSnapshot.Id(ProcessSession) || !RuntimeSnapshot.Id(ObserverEpoch)
            || !RuntimeSnapshot.Id(WorldSession) || !RuntimeSnapshot.Id(RequestId)
            || ClockEpoch < 0 || EligibilityEpoch < 0 || DueActiveMilliseconds < 0 || CommandSequence <= 0)
            throw new InvalidDataException("Invalid guarded save ticket.");
        return this;
    }
    public string Encode() { Validate(); return string.Join('|', "1", ProcessSession, ObserverEpoch, WorldSession,
        ClockEpoch.ToString(CultureInfo.InvariantCulture), EligibilityEpoch.ToString(CultureInfo.InvariantCulture),
        DueActiveMilliseconds.ToString(CultureInfo.InvariantCulture), CommandSequence.ToString(CultureInfo.InvariantCulture), RequestId); }
    public static RuntimeSaveTicket Parse(string value)
    {
        if (value.Length > 1024) throw new InvalidDataException("Oversized save ticket.");
        var p = value.Split('|');
        if (p.Length != 9 || p[0] != "1") throw new InvalidDataException("Unsupported save ticket.");
        return new RuntimeSaveTicket(p[1], p[2], p[3], long.Parse(p[4], CultureInfo.InvariantCulture),
            long.Parse(p[5], CultureInfo.InvariantCulture), long.Parse(p[6], CultureInfo.InvariantCulture),
            long.Parse(p[7], CultureInfo.InvariantCulture), p[8]).Validate();
    }
}

public static class RuntimeJson
{
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web) { IgnoreReadOnlyProperties = true };
    public static string Write<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static T Read<T>(string value) => JsonSerializer.Deserialize<T>(value, Options)
        ?? throw new InvalidDataException("Empty runtime message.");
}