using System.Globalization;
using System.Text.RegularExpressions;

namespace PzTools.GameExtensions;

public enum VersionSupportScope { All, Major, Minor }

/// <summary>Inclusive component ranges. Minor 42.20 includes 42.20.x; never compare version strings or decimals.</summary>
public sealed record GameVersionSupport(VersionSupportScope Scope, string? Minimum = null, string? Maximum = null)
{
    public static GameVersionSupport All { get; } = new(VersionSupportScope.All);
    public GameVersionSupport Validate()
    {
        if (!Enum.IsDefined(Scope) || Scope == VersionSupportScope.All && (Minimum is not null || Maximum is not null))
            throw new InvalidDataException("Invalid version support scope.");
        if (Scope != VersionSupportScope.All)
        {
            var minimum = Bound(Minimum ?? throw new InvalidDataException("Missing version bound."));
            if (Maximum is not null && Bound(Maximum) < minimum) throw new InvalidDataException("Reversed version range.");
        }
        return this;
    }
    public bool Matches(string? installed)
    {
        Validate();
        if (Scope == VersionSupportScope.All) return true;
        if (installed is null || installed.Length > 80) return false;
        var match = Regex.Match(installed, @"\A([0-9]{1,4})\.([0-9]{1,4})(?:\.[0-9]{1,4})?(?:[-+][A-Za-z0-9.-]+)?\z", RegexOptions.CultureInvariant);
        if (!match.Success) return false;
        long major = long.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
        long value = Scope == VersionSupportScope.Major ? major : major * 10000 + long.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture);
        return value >= Bound(Minimum!) && (Maximum is null || value <= Bound(Maximum));
    }
    private long Bound(string value)
    {
        var parts = value.Split('.');
        if (parts.Length != (Scope == VersionSupportScope.Major ? 1 : 2)
            || parts.Any(part => part.Length is < 1 or > 4 || !part.All(char.IsAsciiDigit)))
            throw new InvalidDataException("Invalid version range bound.");
        long first = long.Parse(parts[0], CultureInfo.InvariantCulture);
        return Scope == VersionSupportScope.Major ? first : first * 10000 + long.Parse(parts[1], CultureInfo.InvariantCulture);
    }
    public string RangeText => Scope == VersionSupportScope.All ? "*" : Maximum is null ? Minimum + "+"
        : Minimum == Maximum ? Minimum! : Minimum + " - " + Maximum;
}