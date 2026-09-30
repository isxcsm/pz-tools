using PzTools.App.Core;

namespace PzTools.App;

internal static class LogTimeFormatter
{
    public static string FormatFull(DateTimeOffset time) =>
        LogTimeDisplay.Full(time, TimeZoneInfo.Local, Localizer.Culture);

    public static string FormatShort(DateTimeOffset time) =>
        LogTimeDisplay.Short(time, DateTimeOffset.Now, TimeZoneInfo.Local, Localizer.Culture,
            Localizer.Get("LogTimeYesterdayFormat"));
}
