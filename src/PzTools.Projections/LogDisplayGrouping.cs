namespace PzTools.Projections;

/// <summary>
/// Presents one row per warning/error incident while retaining every raw log
/// and its stable log number for the detail view.
/// </summary>
public sealed record LogDisplayGroup(
    string Key,
    LogEntryView Primary,
    IReadOnlyList<LogEntryView> Entries,
    DateTimeOffset LatestUtc,
    LogLevel Level,
    bool IsUnread);

public static class LogDisplayGrouping
{
    public static IReadOnlyList<LogDisplayGroup> Group(IEnumerable<LogEntryView> entries) =>
        entries.GroupBy(item => item.Level >= LogLevel.Warning && item.IncidentKey is not null
                ? $"incident:{item.IncidentKey}"
                : $"entry:{item.EntryId}", StringComparer.Ordinal)
            .Select(group =>
            {
                var related = group.OrderByDescending(item => item.OccurredUtc)
                    .ThenByDescending(item => item.LogIndex).ToArray();
                var primary = related.OrderByDescending(Priority)
                    .ThenByDescending(item => item.OccurredUtc)
                    .ThenByDescending(item => item.LogIndex).First();
                return new LogDisplayGroup(group.Key, primary, related,
                    related[0].OccurredUtc, related.Max(item => item.Level),
                    related.Any(item => item.Level >= LogLevel.Warning && !item.IsAcknowledged));
            })
            .OrderByDescending(group => group.Entries.Max(item => item.LogIndex))
            .ThenByDescending(group => group.LatestUtc)
            .ToArray();

    private static int Priority(LogEntryView entry)
    {
        var diagnostics = LogDiagnostics.Parse(entry.PayloadJson);
        var score = entry.Level switch
        {
            LogLevel.Critical => 40,
            LogLevel.Error => 30,
            LogLevel.Warning => 20,
            _ => 0,
        };
        if (entry.EventName == "run.failed") score += 40;
        else if (entry.EventName.EndsWith(".failed", StringComparison.Ordinal)) score += 20;
        if (diagnostics?.FailureCode is not null) score += 20;
        if (diagnostics?.Path is not null) score += 20;
        if (diagnostics?.Reason is not null) score += 10;
        return score;
    }
}
