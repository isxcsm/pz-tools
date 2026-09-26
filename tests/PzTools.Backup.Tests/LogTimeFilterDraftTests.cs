using PzTools.App.Core;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class LogTimeFilterDraftTests
{
    [Theory]
    [InlineData(2026, 1, 1, "2025-12-31 15:45", "2026-01-01 15:45")]
    [InlineData(2024, 3, 1, "2024-02-29 15:45", "2024-03-01 15:45")]
    public void RecentDayHasActualValuesAcrossCalendarBoundaries(int year, int month, int day, string from, string through)
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("fixture+09", TimeSpan.FromHours(9), "fixture", "fixture");
        var now = new DateTimeOffset(year, month, day, 15, 45, 0, TimeSpan.FromHours(9));
        var draft = LogTimeFilterDraft.RecentDay(now, zone);
        Assert.Equal(from, draft.FromText);
        Assert.Equal(through, draft.ThroughText);
        Assert.True(LogTimeRange.TryParse(draft.FromText, draft.ThroughText, zone, out var range));
        Assert.Equal(now.AddDays(-1).ToUniversalTime(), range!.FromUtc);
        Assert.Equal(now.ToUniversalTime().AddMinutes(1).AddTicks(-1), range.ThroughUtc);
    }

    [Fact]
    public void RecentDayRemainsUnambiguousAcrossDaylightSavingClockChanges()
    {
        var rule = TimeZoneInfo.AdjustmentRule.CreateAdjustmentRule(new DateTime(2020, 1, 1), new DateTime(2030, 12, 31), TimeSpan.FromHours(1),
            TimeZoneInfo.TransitionTime.CreateFloatingDateRule(new DateTime(1, 1, 1, 2, 0, 0), 3, 2, DayOfWeek.Sunday),
            TimeZoneInfo.TransitionTime.CreateFloatingDateRule(new DateTime(1, 1, 1, 2, 0, 0), 11, 1, DayOfWeek.Sunday));
        var zone = TimeZoneInfo.CreateCustomTimeZone("fixture-dst", TimeSpan.FromHours(-5), "fixture", "standard", "daylight", [rule]);
        var now = new DateTimeOffset(2026, 11, 1, 1, 30, 0, TimeSpan.FromHours(-5));
        var draft = LogTimeFilterDraft.RecentDay(now, zone);
        Assert.True(LogTimeRange.TryParse(draft.FromText, draft.ThroughText, zone, out var range));
        Assert.Equal(now.AddDays(-1).ToUniversalTime(), range!.FromUtc);
        Assert.Equal(now.ToUniversalTime().AddMinutes(1).AddTicks(-1), range.ThroughUtc);
    }

    [Fact]
    public void PickerUsesTypedInstantInLocalZone_AndAppliesTheChosenDateAndTime()
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("fixture+14", TimeSpan.FromHours(14), "fixture", "fixture");
        var fallback = new DateTimeOffset(2026, 9, 26, 0, 0, 0, TimeSpan.Zero);
        var picked = LogTimeFilterDraft.PickerValue("2026-09-25 23:45:30 -05:00", fallback, zone);
        Assert.Equal(new DateTime(2026, 9, 26, 18, 45, 30), picked);
        Assert.Equal("2026-09-27 08:15", LogTimeFilterDraft.FormatSelection(picked.AddDays(1), new TimeSpan(8, 15, 0)));
        Assert.Equal(TimeZoneInfo.ConvertTime(fallback, zone).DateTime, LogTimeFilterDraft.PickerValue("", fallback, zone));
        // Invalid typed values are still rejected when applying the filter; opening an aid does not apply them.
        Assert.False(LogTimeRange.TryParse("2026-02-30 12:00", "", zone, out _));
        Assert.Throws<ArgumentOutOfRangeException>(() => LogTimeFilterDraft.FormatSelection(picked, TimeSpan.FromDays(1)));
    }
}
