using System.Globalization;
using PzTools.Projections;

namespace PzTools.App.Core;

/// <summary>Editor values only: opening a picker must not change the active log query.</summary>
public sealed record LogTimeFilterDraft(string FromText, string ThroughText)
{
    public static LogTimeFilterDraft RecentDay(DateTimeOffset now, TimeZoneInfo zone) =>
        new(FormatLocal(now.AddDays(-1), zone), FormatLocal(now, zone));

    private static string FormatLocal(DateTimeOffset instant, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTime(instant, zone);
        // Preserve the instant when the previous 24 hours cross a repeated DST hour.
        return local.ToString(zone.IsAmbiguousTime(local.DateTime)
            ? "yyyy-MM-dd HH:mm zzz" : "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
    }

    public static DateTime PickerValue(string text, DateTimeOffset fallback, TimeZoneInfo zone)
    {
        var instant = LogTimeRange.TryParse(text, null, zone, out var range) && range?.FromUtc is { } selected
            ? selected : fallback;
        return TimeZoneInfo.ConvertTime(instant, zone).DateTime;
    }

    public static string FormatSelection(DateTime date, TimeSpan time)
    {
        if (time < TimeSpan.Zero || time >= TimeSpan.FromDays(1)) throw new ArgumentOutOfRangeException(nameof(time));
        return date.Date.Add(time).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
    }
}
