using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class LogHeaderFilterTests
{
    [Fact]
    public void NumberRangesAreExactInt64_AndInvalidDraftsAreRejected()
    {
        Assert.True(LogNumberRange.TryParse("", out var none)); Assert.Null(none);
        Assert.True(LogNumberRange.TryParse(" #42 ", out var exact)); Assert.Equal(new(42, 42), exact);
        Assert.True(LogNumberRange.TryParse("#40 – #50", out var range)); Assert.Equal(new(40, 50), range);
        Assert.True(LogNumberRange.TryParse("9007199254740993", out var large));
        Assert.Equal(9007199254740993, large!.First); // Beyond double's exact integer range.
        Assert.True(LogNumberRange.TryParse(long.MaxValue.ToString(), out var maximum)); Assert.Equal(long.MaxValue, maximum!.Last);
        foreach (var invalid in new[] { "-1", "50-40", "1-2-3", "1.5", "1e3", "9223372036854775808", "1 OR 1=1" })
            Assert.False(LogNumberRange.TryParse(invalid, out _), invalid);
    }

    [Fact]
    public void LocalTimeBoundsIncludeTheFinalMinuteOrSecond_AndNormalizeToUtc()
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("test+09", TimeSpan.FromHours(9), "test", "test");
        Assert.True(LogTimeRange.TryParse("2026-09-26 07:00", "2026-09-26 07:00", zone, out var minute));
        var start = new DateTimeOffset(2026, 9, 25, 22, 0, 0, TimeSpan.Zero);
        Assert.Equal(start, minute!.FromUtc);
        Assert.Equal(start.AddMinutes(1).AddTicks(-1), minute.ThroughUtc);
        Assert.True(LogTimeRange.TryParse("2026-09-26 07:00:05", "2026-09-26 07:00:05", zone, out var second));
        Assert.Equal(start.AddSeconds(6).AddTicks(-1), second!.ThroughUtc);
        Assert.True(LogTimeRange.TryParse("", "2026-09-26 07:00 +09:00", TimeZoneInfo.Utc, out var upperOnly));
        Assert.Null(upperOnly!.FromUtc); Assert.Equal(minute.ThroughUtc, upperOnly.ThroughUtc);
        Assert.True(LogTimeRange.TryParse("", "", zone, out var unbounded)); Assert.Null(unbounded);
        Assert.False(LogTimeRange.TryParse("2026-09-27 00:00", "2026-09-26 23:59", zone, out _));
        Assert.False(LogTimeRange.TryParse("2026-02-30 12:00", "", zone, out _));
    }

    [Fact]
    public void DstGapsAndRepeatedHoursAreNotSilentlyReinterpreted()
    {
        var rule = TimeZoneInfo.AdjustmentRule.CreateAdjustmentRule(new DateTime(2020, 1, 1), new DateTime(2030, 12, 31), TimeSpan.FromHours(1),
            TimeZoneInfo.TransitionTime.CreateFloatingDateRule(new DateTime(1, 1, 1, 2, 0, 0), 3, 2, DayOfWeek.Sunday),
            TimeZoneInfo.TransitionTime.CreateFloatingDateRule(new DateTime(1, 1, 1, 2, 0, 0), 11, 1, DayOfWeek.Sunday));
        var zone = TimeZoneInfo.CreateCustomTimeZone("test-dst", TimeSpan.FromHours(-5), "test", "standard", "daylight", [rule]);
        Assert.False(LogTimeRange.TryParse("2026-03-08 02:30", "", zone, out _));
        Assert.False(LogTimeRange.TryParse("2026-11-01 01:30", "", zone, out _));
        Assert.True(LogTimeRange.TryParse("2026-11-01 01:30 -04:00", "2026-11-01 01:30 -05:00", zone, out var explicitOffsets));
        Assert.Equal(TimeSpan.FromMinutes(61).Subtract(TimeSpan.FromTicks(1)), explicitOffsets!.ThroughUtc - explicitOffsets.FromUtc);
    }

    [Fact]
    public async Task HeadersFilterBeforeGroupingAndPagination_AndEveryFieldInvalidatesTheCache()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var t = new DateTimeOffset(2026, 9, 25, 22, 0, 0, TimeSpan.Zero);
        await inbox.AppendAsync([
            Entry("one", 1, t, 42), Entry("two", 2, t.AddMinutes(1), 142, "state-collector", LogLevel.Warning),
            Entry("three", 3, t.AddMinutes(2), 42, level: LogLevel.Error),
            Entry("four", 4, t.AddMinutes(3), 9007199254740993, "character-recovery"), Entry("five", 5, t.AddMinutes(4), 42),
        ]);
        var all = new LogPageQuery(LogLevel.Information, "All", "", 0);
        Assert.Equal(5, (await inbox.ReadPageAsync(all)).TotalGroups);
        var exact = await inbox.ReadPageAsync(all with { RunText = "42" });
        Assert.Equal(3, exact.TotalGroups); Assert.DoesNotContain(exact.Entries, e => e.RunIndex == 142);
        Assert.Equal(4, (await inbox.ReadPageAsync(all with { RunText = "40-142" })).TotalGroups);
        var combined = all with { LogText = "2-4", ComponentCategory = "Backup", FromUtc = t.AddMinutes(1), ThroughUtc = t.AddMinutes(2) };
        Assert.Equal("three", Assert.Single((await inbox.ReadPageAsync(combined)).Entries).EntryId);
        Assert.Empty((await inbox.ReadPageAsync(combined with { LogText = "4" })).Entries);
        Assert.Empty((await inbox.ReadPageAsync(combined with { ThroughUtc = t.AddMinutes(1) })).Entries);
        Assert.Equal("four", Assert.Single((await inbox.ReadPageAsync(all with { ComponentCategory = "Recovery", RunText = "9007199254740993" })).Entries).EntryId);
        var offsetBounds = combined with { FromUtc = combined.FromUtc!.Value.ToOffset(TimeSpan.FromHours(9)), ThroughUtc = combined.ThroughUtc!.Value.ToOffset(TimeSpan.FromHours(9)) };
        Assert.Equal("three", Assert.Single((await inbox.ReadPageAsync(offsetBounds)).Entries).EntryId);
        Assert.Equal(5, (await inbox.ReadPageAsync(all)).TotalGroups); // Clear restores the unfiltered set, not only visible rows.
    }

    [Fact]
    public async Task FilteredPagesKeepSnapshotWhileNewLogsArrive()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var t = DateTimeOffset.UnixEpoch;
        await inbox.AppendAsync(Enumerable.Range(1, 5).Select(i => Entry($"old-{i}", i, t.AddMinutes(i), 42)).ToArray());
        var query = new LogPageQuery(LogLevel.Information, "Backup", "42", 0, 2, FromUtc: t.AddMinutes(2));
        var first = await inbox.ReadPageAsync(query);
        Assert.Equal(4, first.TotalGroups);
        Assert.Equal(new long[] { 5, 4 }, first.Entries.Select(e => e.LogIndex));
        await inbox.AppendAsync([Entry("new", 6, t.AddMinutes(6), 42)]);
        var second = await inbox.ReadPageAsync(query with { PageIndex = 1, SnapshotMaxLogIndex = first.SnapshotMaxLogIndex });
        Assert.Equal(4, second.TotalGroups);
        Assert.Equal(new long[] { 3, 2 }, second.Entries.Select(e => e.LogIndex));
        Assert.Equal(5, (await inbox.ReadPageAsync(query)).TotalGroups);
    }

    [Fact]
    public async Task NumberFilterCanSelectARelatedLogWithoutLeakingUnmatchedRowsOrChangingAcknowledgments()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var t = DateTimeOffset.UnixEpoch;
        await inbox.AppendAsync([Entry("cause", 1, t, 42, level: LogLevel.Error),
            Entry("summary", 2, t.AddSeconds(1), 42, level: LogLevel.Error)]);
        var all = new LogPageQuery(LogLevel.Information, "All", "", 0);
        Assert.Equal(1, (await inbox.ReadPageAsync(all)).TotalGroups);
        var match = await inbox.ReadPageAsync(all with { LogText = "1" });
        var row = Assert.Single(match.Entries); Assert.Equal("cause", row.EntryId); Assert.False(row.IsAcknowledged);
        await inbox.AcknowledgeIssueAsync(row.IncidentKey!, row.LogIndex);
        Assert.True(Assert.Single((await inbox.ReadPageAsync(all with { LogText = "1" })).Entries).IsAcknowledged);
        Assert.Equal(2, (await inbox.ReadPageAsync(all)).Entries.Count);
    }

    [Fact]
    public async Task InvalidOrCancelledQueriesCannotReplaceTheValidCachedResult()
    {
        using var temp = new TempDirectory();
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        await inbox.AppendAsync([Entry("one", 1, DateTimeOffset.UnixEpoch, 42)]);
        var query = new LogPageQuery(LogLevel.Information, "All", "", 0);
        Assert.Single((await inbox.ReadPageAsync(query)).Entries);
        await Assert.ThrowsAsync<ArgumentException>(() => inbox.ReadPageAsync(query with { RunText = "42 OR 1=1" }));
        await Assert.ThrowsAsync<ArgumentException>(() => inbox.ReadPageAsync(query with { LogText = "2-1" }));
        await Assert.ThrowsAsync<ArgumentException>(() => inbox.ReadPageAsync(query with { FromUtc = DateTimeOffset.UnixEpoch.AddDays(1), ThroughUtc = DateTimeOffset.UnixEpoch }));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => inbox.ReadPageAsync(query, new CancellationToken(true)));
        Assert.Single((await inbox.ReadPageAsync(query)).Entries);
    }

    private static LogEntryView Entry(string id, long eventId, DateTimeOffset time, long run,
        string component = "backup-worker", LogLevel level = LogLevel.Information) =>
        new(id, "fixture", Guid.Empty, eventId, time, level, component, run, "run.completed", null);
}
