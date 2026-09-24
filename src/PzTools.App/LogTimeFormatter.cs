namespace PzTools.App;

internal static class LogTimeFormatter
{
    private static bool UsesKoreanTimeZone => TimeZoneInfo.Local.Id is
        "Korea Standard Time" or "Asia/Seoul";

    public static string ShortZoneName => UsesKoreanTimeZone
        ? "KST" : Localizer.Get("LogLocalTimeZone");

    public static string ZoneLabel(DateTimeOffset time)
    {
        var offset = time.ToLocalTime().ToString("zzz", System.Globalization.CultureInfo.InvariantCulture);
        return UsesKoreanTimeZone ? $"KST, UTC{offset}" : $"UTC{offset}";
    }

    public static string FormatFull(DateTimeOffset time)
    {
        var local = time.ToLocalTime();
        return $"{local.ToString("G", Localizer.Culture)} ({ZoneLabel(local)})";
    }

    public static string FormatShort(DateTimeOffset time) =>
        time.ToLocalTime().ToString("HH:mm:ss", Localizer.Culture);
}
