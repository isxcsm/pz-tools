using PzTools.App.Core;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class LogListEmptyStateTests
{
    [Fact]
    public void DefaultWarningFilterExplainsEmptyListAndOffersCollectedLogs()
    {
        var state = Empty();
        Assert.Equal(LogListPlaceholder.MinimumLevel, state.Kind);
        Assert.True(state.ShowAllLogs);
    }

    [Fact]
    public void AdditionalFiltersTakePrecedenceOverMinimumLevelExplanation()
    {
        var state = Empty(otherFilters: true);
        Assert.Equal(LogListPlaceholder.Filtered, state.Kind);
        Assert.True(state.ShowAllLogs);
    }

    [Theory]
    [InlineData(LogLevel.Trace)]
    [InlineData(LogLevel.Information)]
    public void UnfilteredEmptyListDoesNotOfferARedundantReset(LogLevel recordMinimum)
    {
        var state = Empty(minimum: recordMinimum, recordMinimum: recordMinimum);
        Assert.Equal(LogListPlaceholder.Empty, state.Kind);
        Assert.False(state.ShowAllLogs);
    }

    [Theory]
    [InlineData(LogLevel.Warning)]
    [InlineData(LogLevel.Error)]
    public void RestrictedRecordingStillExplainsLevelButDoesNotOfferUncollectedLogs(LogLevel minimum)
    {
        var state = Empty(minimum: minimum, recordMinimum: minimum);
        Assert.Equal(LogListPlaceholder.MinimumLevel, state.Kind);
        Assert.False(state.ShowAllLogs);
    }

    [Theory]
    [InlineData(false, false, false, LogListPlaceholder.Loading)]
    [InlineData(false, true, false, LogListPlaceholder.Loading)]
    [InlineData(true, true, false, LogListPlaceholder.Loading)]
    [InlineData(false, false, true, LogListPlaceholder.Unavailable)]
    [InlineData(true, false, true, LogListPlaceholder.Unavailable)]
    [InlineData(true, true, true, LogListPlaceholder.Loading)]
    public void LoadingAndFailureNeverReportAnEmptySuccess(bool loaded, bool loading,
        bool failed, LogListPlaceholder expected)
    {
        var state = LogListEmptyState.Create(loaded, loading, failed, 0,
            LogLevel.Warning, LogLevel.Information, true);
        Assert.Equal(expected, state.Kind);
        Assert.False(state.ShowAllLogs);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void RefreshDoesNotCoverPreviouslyLoadedRows(bool loading, bool failed)
    {
        var state = LogListEmptyState.Create(true, loading, failed, 1,
            LogLevel.Warning, LogLevel.Information, false);
        Assert.Equal(LogListPlaceholder.None, state.Kind);
        Assert.False(state.ShowAllLogs);
    }

    private static LogListEmptyState Empty(bool otherFilters = false,
        LogLevel minimum = LogLevel.Warning, LogLevel recordMinimum = LogLevel.Information) =>
        LogListEmptyState.Create(true, false, false, 0, minimum, recordMinimum, otherFilters);
}
