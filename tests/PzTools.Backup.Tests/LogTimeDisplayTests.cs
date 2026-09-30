using System.Globalization;
using PzTools.App.Core;

namespace PzTools.Backup.Tests;

public sealed class LogTimeDisplayTests
{
    private static readonly TimeZoneInfo Zone =
        TimeZoneInfo.CreateCustomTimeZone("fixture+09", TimeSpan.FromHours(9), "fixture", "fixture");
    private static readonly DateTimeOffset Now = new(2026, 9, 30, 0, 30, 0, TimeSpan.FromHours(9));

    [Theory]
    [InlineData("2026-09-29T15:00:05Z", "00:00:05")] // Local today, although the UTC date is yesterday.
    [InlineData("2026-09-29T14:59:59Z", "Yesterday 23:59")]
    [InlineData("2026-09-28T06:12:05Z", "Sep 28 15:12")]
    [InlineData("2025-12-31T06:12:05Z", "12/31/2025")]
    public void ShortTimeNamesTheDayOnlyWhenItIsNotToday(string utc, string expected)
    {
        var time = DateTimeOffset.Parse(utc, CultureInfo.InvariantCulture);
        Assert.Equal(expected, LogTimeDisplay.Short(time, Now, Zone, CultureInfo.InvariantCulture, "Yesterday {0}"));
    }

    [Fact]
    public void FullTimeIsTheLocalClockWithoutAZoneName()
    {
        var time = new DateTimeOffset(2026, 9, 30, 6, 12, 5, TimeSpan.Zero);
        Assert.Equal("09/30/2026 15:12:05", LogTimeDisplay.Full(time, Zone, CultureInfo.InvariantCulture));
    }
}
