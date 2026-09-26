using System.Globalization;

namespace PzTools.Projections;

/// <summary>Exact integer IDs or a closed range. Never parse an identifier through double.</summary>
public sealed record LogNumberRange(long First, long Last)
{
    public static bool TryParse(string? text, out LogNumberRange? range)
    {
        range = null;
        if (string.IsNullOrWhiteSpace(text)) return true;
        var parts = text.Trim().Replace('\u2013', '-').Split('-');
        if (parts.Length is < 1 or > 2 || !Number(parts[0], out var first)) return false;
        var last = first;
        if (parts.Length == 2 && !Number(parts[1], out last)) return false;
        if (first > last) return false;
        range = new(first, last);
        return true;
    }
    private static bool Number(string text, out long value) => long.TryParse(
        text.Trim().TrimStart('#'), NumberStyles.None, CultureInfo.InvariantCulture, out value);
    public override string ToString() => First == Last ? First.ToString(CultureInfo.InvariantCulture)
        : $"{First.ToString(CultureInfo.InvariantCulture)}–{Last.ToString(CultureInfo.InvariantCulture)}";
}

/// <summary>UI time input is local, database bounds are UTC. Include the whole final minute/second.</summary>
public sealed record LogTimeRange(DateTimeOffset? FromUtc, DateTimeOffset? ThroughUtc)
{
    public static bool TryParse(string? from, string? through, TimeZoneInfo zone, out LogTimeRange? range)
    {
        ArgumentNullException.ThrowIfNull(zone);
        range = null;
        if (!TryBound(from, zone, false, out var start) || !TryBound(through, zone, true, out var end)
            || start > end) return false;
        if (start is not null || end is not null) range = new(start, end);
        return true;
    }
    private static bool TryBound(string? text, TimeZoneInfo zone, bool upper, out DateTimeOffset? value)
    {
        value = null;
        if (string.IsNullOrWhiteSpace(text)) return true;
        text = text.Trim();
        foreach (var seconds in new[] { false, true })
        {
            var format = seconds ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm";
            DateTimeOffset instant;
            if (DateTimeOffset.TryParseExact(text, format + " zzz", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out var offsetTime)) instant = offsetTime;
            else if (DateTime.TryParseExact(text, format, CultureInfo.InvariantCulture,
                         DateTimeStyles.None, out var wallTime))
            {
                wallTime = DateTime.SpecifyKind(wallTime, DateTimeKind.Unspecified);
                // Do not silently choose an instant in a DST gap or repeated clock hour.
                if (zone.IsInvalidTime(wallTime) || zone.IsAmbiguousTime(wallTime)) return false;
                try { instant = new DateTimeOffset(wallTime, zone.GetUtcOffset(wallTime)); }
                catch (ArgumentException) { return false; }
            }
            else continue;
            try
            {
                value = upper ? instant.ToUniversalTime().AddTicks(
                    (seconds ? TimeSpan.TicksPerSecond : TimeSpan.TicksPerMinute) - 1)
                    : instant.ToUniversalTime();
                return true;
            }
            catch (ArgumentOutOfRangeException) { return false; }
        }
        return false;
    }
}
