using System.Globalization;
using System.Text;

namespace PzTools.Process.Contracts.GameRuntime;

public enum RuntimeExtensionState { Disabled, Pending, Active, Unsupported, FaultedPassThrough, RestartRequired }

/// <summary>Feature values confirmed by an applied revision, never merely the saved request.</summary>
public sealed record RuntimeVehicleOptions(bool TorqueEnabled, bool ReverseEnabled, bool SteeringEnabled, bool AreaLightEnabled = true);

/// <summary>Applied JVM state, not the user's saved preference. It does not grant backup permission.</summary>
public sealed record RuntimeExtensionStatus(RuntimeExtensionState State, string? Reason = null,
    string ProcessSession = "", string? WorldSession = null, string? Generation = null,
    long AppliedRevision = -1, string? ModuleVersion = null, string? ModuleHash = null,
    string? Diagnostics = null, long AgeMilliseconds = 0, long RequestedRevision = -1,
    bool ControlReady = false, RuntimeVehicleOptions? AppliedVehicleOptions = null)
{
    public RuntimeExtensionStatus Validate()
    {
        if (!Enum.IsDefined(State) || ProcessSession is null
            || ProcessSession.Length != 0 && !RuntimeSnapshot.Id(ProcessSession)
            || WorldSession is not null && !RuntimeSnapshot.Id(WorldSession)
            || Generation is not null && !RuntimeSnapshot.Id(Generation)
            || AppliedRevision < -1 || RequestedRevision < -1 || AgeMilliseconds < 0
            || Reason is { Length: > 1024 } || Reason?.Any(char.IsControl) == true
            || Diagnostics is { Length: > 4096 } || Diagnostics?.IndexOf('\0') >= 0
            || ModuleVersion is { Length: > 80 } || ModuleVersion?.Any(char.IsControl) == true
            || ModuleHash is not null && (ModuleHash.Length != 64 || !ModuleHash.All(char.IsAsciiHexDigit))
            || State == RuntimeExtensionState.Active && (ProcessSession.Length == 0 || WorldSession is null
                || Generation is null || AppliedRevision < 0 || ModuleVersion is null || ModuleHash is null)
            || ControlReady && (ProcessSession.Length == 0 || WorldSession is null)
            || AppliedVehicleOptions is not null && (!ControlReady || State is not (RuntimeExtensionState.Active or RuntimeExtensionState.Pending)
                || ProcessSession.Length == 0 || WorldSession is null || Generation is null || AppliedRevision < 0))
            throw new InvalidDataException("Invalid extension runtime status.");
        return this;
    }

    public static RuntimeExtensionStatus ParseWire(string line, string commandId)
    {
        if (line.Length > 16384) throw new InvalidDataException("Oversized extension status.");
        var fields = line.Split('\t');
        if (fields.Length is not (10 or 11) || fields[0] != "STATE" || fields[1] != commandId
            || !Enum.TryParse<RuntimeExtensionState>(fields[2], false, out var state) || !Enum.IsDefined(state))
            throw new InvalidDataException("Unexpected extension response or command identity.");
        static string? Optional(string value) => value == "-" ? null : value;
        static string? Decode(string value) => value == "-" ? null
            : new UTF8Encoding(false, true).GetString(Convert.FromBase64String(value));
        return new RuntimeExtensionStatus(state, Decode(fields[3]), Optional(fields[4]) ?? "",
            Optional(fields[5]), Optional(fields[6]), long.Parse(fields[7], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture),
            Optional(fields[8]), Optional(fields[9]), fields.Length == 11 ? Decode(fields[10]) : null).Validate();
    }
}
