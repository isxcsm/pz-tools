using System.Globalization;

namespace PzTools.App.Core;

/// <summary>Log times as read from the PC clock: no zone names, and a day only when it is not today.</summary>
public static class LogTimeDisplay
{
    public static string Short(DateTimeOffset time, DateTimeOffset now, TimeZoneInfo zone,
        CultureInfo culture, string yesterdayFormat)
    {
        var local = TimeZoneInfo.ConvertTime(time, zone);
        var today = TimeZoneInfo.ConvertTime(now, zone).Date;
        if (local.Date == today) return local.ToString("HH:mm:ss", culture);
        var clock = local.ToString("HH:mm", culture);
        if (local.Date == today.AddDays(-1)) return string.Format(culture, yesterdayFormat, clock);
        // The list column is narrow; the full time stays available in the tooltip and details.
        if (local.Year != today.Year) return local.ToString("d", culture);
        var monthDay = culture.DateTimeFormat.MonthDayPattern.Replace("MMMM", "MMM", StringComparison.Ordinal);
        return $"{local.ToString(monthDay, culture)} {clock}";
    }

    public static string Full(DateTimeOffset time, TimeZoneInfo zone, CultureInfo culture) =>
        TimeZoneInfo.ConvertTime(time, zone).ToString("G", culture);
}
