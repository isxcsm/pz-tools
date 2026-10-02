using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PzTools.App.Core;
using Windows.Foundation;

namespace PzTools.App;

/// <summary>
/// Widths of the log list's short columns, fitted to what they show in the current language:
/// the level names, the time formats and the run number. The message takes the rest.
/// The header row and the row template read the same values, so they stay lined up.
/// </summary>
public static class LogColumns
{
    // A header holds its text (11 px), a 9 px icon, 3 px between them and 3 px of button padding each side.
    private const double HeaderExtra = 9 + 3 + 6;

    public static GridLength Level { get; private set; } = new(64);
    public static GridLength Time { get; private set; } = new(104);
    public static GridLength Run { get; private set; } = new(72);

    public static void Fit(string levelHeader, string timeHeader, string runHeader)
    {
        var culture = Localizer.Culture;
        var levels = new[] { "Trace", "Information", "Warning", "Error", "Critical" }
            .Select(level => Localizer.Get("LogLevel." + level)).ToArray();
        Level = new(Math.Clamp(Math.Max(Widest(levels, 12), Widest([levelHeader, .. levels], 11) + HeaderExtra), 44, 140));

        // Every shape the short time can take: today, yesterday, this year (each month, since their
        // abbreviations differ in length) and another year.
        var now = new DateTimeOffset(2026, 12, 31, 12, 0, 0, TimeSpan.Zero);
        var yesterday = Localizer.Get("LogTimeYesterdayFormat");
        string Short(DateTimeOffset time) => LogTimeDisplay.Short(time, now, TimeZoneInfo.Utc, culture, yesterday);
        List<string> times = [Short(now.AddHours(11)), Short(now.AddDays(-1).AddHours(11)), Short(now.AddYears(-1))];
        for (var month = 1; month <= 11; month++) times.Add(Short(new DateTimeOffset(2026, month, 28, 22, 48, 0, TimeSpan.Zero)));
        Time = new(Math.Clamp(Math.Max(Widest(times, 12), Measure(timeHeader, 11) + HeaderExtra), 64, 160));

        // Long run numbers are shortened to "#…" and six digits.
        Run = new(Math.Clamp(Math.Max(Widest(["#…888888", "#88888888"], 12), Measure(runHeader, 11) + HeaderExtra), 48, 120));
    }

    private static double Widest(IEnumerable<string> texts, double size) => texts.Max(text => Measure(text, size));

    private static double Measure(string text, double size)
    {
        // The page's language picks the same fallback fonts the list uses for Korean, Japanese and the rest.
        var block = new TextBlock { Text = text, FontSize = size, Language = Localizer.Culture.Name };
        block.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return Math.Ceiling(block.DesiredSize.Width) + 2;
    }
}
