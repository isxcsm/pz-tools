using PzTools.Projections;

namespace PzTools.App.Core;

public enum LogListPlaceholder { None, Loading, Unavailable, Empty, MinimumLevel, Filtered }

public readonly record struct LogListEmptyState(LogListPlaceholder Kind, bool ShowAllLogs)
{
    public static LogListEmptyState Create(bool hasLoaded, bool isLoading, bool loadFailed,
        int rowCount, LogLevel minimumLevel, LogLevel recordMinimum, bool hasOtherFilters)
    {
        // Keep existing rows visible during refreshes; never turn a failed query into a clean bill of health.
        if (rowCount > 0) return new(LogListPlaceholder.None, false);
        if (isLoading) return new(LogListPlaceholder.Loading, false);
        if (loadFailed) return new(LogListPlaceholder.Unavailable, false);
        if (!hasLoaded) return new(LogListPlaceholder.Loading, false);
        var hasLevelFilter = minimumLevel > recordMinimum;
        if (hasOtherFilters) return new(LogListPlaceholder.Filtered, true);
        if (hasLevelFilter || minimumLevel >= LogLevel.Warning)
            return new(LogListPlaceholder.MinimumLevel, hasLevelFilter);
        return new(LogListPlaceholder.Empty, false);
    }
}
