using System.Globalization;
using System.Text;

namespace PzTools.Process.Contracts.GameRuntime;

public enum RuntimeSaveOutcome { Running, Succeeded, Failed }

/// <summary>Observed game-side execution; not the user's toggle and not a durable backup result.</summary>
public sealed record RuntimeSaveExecution(string RequestId, string ProcessSession, string WorldSession,
    string RequestedProvider, string Provider, RuntimeSaveOutcome Outcome, string? Reason,
    long GameThreadMilliseconds, long ElapsedMilliseconds)
{
    public string SemanticKey => $"{RequestId}/{Outcome}/{Provider}/{Reason}/{GameThreadMilliseconds}/{ElapsedMilliseconds}";
    public RuntimeSaveExecution Validate()
    {
        static bool Identifier(string s) => s is { Length: > 0 and <= 80 }
            && s.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-');
        if (!RuntimeSnapshot.Id(RequestId) || !RuntimeSnapshot.Id(ProcessSession) || !RuntimeSnapshot.Id(WorldSession)
            || !Identifier(RequestedProvider) || !Identifier(Provider) || !Enum.IsDefined(Outcome)
            || Reason is not null && !Identifier(Reason) || GameThreadMilliseconds < 0
            || ElapsedMilliseconds < GameThreadMilliseconds)
            throw new InvalidDataException("Invalid save execution report.");
        return this;
    }
    public static RuntimeSaveExecution Parse(string encoded)
    {
        if (encoded.Length > 2048) throw new InvalidDataException("Oversized save execution report.");
        var p = new UTF8Encoding(false, true).GetString(Convert.FromBase64String(encoded)).Split('|');
        if (p.Length != 10 || p[0] != "1" || !Enum.TryParse<RuntimeSaveOutcome>(p[6], out var outcome))
            throw new InvalidDataException("Unsupported save execution report.");
        return new RuntimeSaveExecution(p[1], p[2], p[3], p[4], p[5], outcome, p[7] == "-" ? null : p[7],
            long.Parse(p[8], NumberStyles.None, CultureInfo.InvariantCulture),
            long.Parse(p[9], NumberStyles.None, CultureInfo.InvariantCulture)).Validate();
    }
}