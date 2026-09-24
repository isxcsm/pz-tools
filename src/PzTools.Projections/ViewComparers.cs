namespace PzTools.Projections;

/// <summary>Compare immutable view data, without serializing it or allocating full copies.</summary>
public static class ViewComparers
{
    public static IEqualityComparer<SaveListView> Saves { get; } = EqualityComparer<SaveListView>.Create(
        (x, y) => ReferenceEquals(x, y) || x is not null && y is not null && x.StateRevision == y.StateRevision && x.Game == y.Game && SequenceEqual(x.Saves, y.Saves),
        x => HashCode.Combine(x.StateRevision, x.Game, SequenceHash(x.Saves)));
    public static IEqualityComparer<BackupSourceView> Source { get; } = EqualityComparer<BackupSourceView>.Create(
        (x, y) => ReferenceEquals(x, y) || x is not null && y is not null && x.SourceId == y.SourceId && x.SaveId == y.SaveId && x.RootPath == y.RootPath
            && x.CurrentRevision == y.CurrentRevision && SequenceEqual(x.Revisions, y.Revisions),
        x => HashCode.Combine(x.SourceId, x.SaveId, x.RootPath, x.CurrentRevision, SequenceHash(x.Revisions)));
    public static IEqualityComparer<BackupCatalogView> Backups { get; } = EqualityComparer<BackupCatalogView>.Create(
        (x, y) => ReferenceEquals(x, y) || x is not null && y is not null && x.RepositoryChangeRevision == y.RepositoryChangeRevision && SequenceEqual(x.Sources, y.Sources, Source),
        x => HashCode.Combine(x.RepositoryChangeRevision, SequenceHash(x.Sources, Source)));
    public static IEqualityComparer<SaveDetailView> Detail { get; } = EqualityComparer<SaveDetailView>.Create(
        (x, y) => ReferenceEquals(x, y) || x is not null && y is not null && x.SaveId == y.SaveId && x.LiveSave == y.LiveSave && SequenceEqual(x.BackupRevisions, y.BackupRevisions),
        x => HashCode.Combine(x.SaveId, x.LiveSave, SequenceHash(x.BackupRevisions)));
    public static IEqualityComparer<LogsView> Logs { get; } = EqualityComparer<LogsView>.Create(
        (x, y) => ReferenceEquals(x, y) || x is not null && y is not null && x.UnreadIssues == y.UnreadIssues && SequenceEqual(x.Entries, y.Entries),
        x => HashCode.Combine(x.UnreadIssues, SequenceHash(x.Entries)));
    public static IEqualityComparer<OperationsView> Operations { get; } = ListView<OperationsView, OperationView>(x => x.Operations);
    public static IEqualityComparer<TelemetrySourcesView> TelemetrySources { get; } = ListView<TelemetrySourcesView, TelemetrySourceView>(x => x.Sources);
    public static IEqualityComparer<ProjectorHealthView> Health { get; } = ListView<ProjectorHealthView, ProjectorStatus>(x => x.Projectors);
    private static readonly IEqualityComparer<ProducerMetricsView> Producer = EqualityComparer<ProducerMetricsView>.Create(
        (x, y) => ReferenceEquals(x, y) || x is not null && y is not null && x.Producer == y.Producer && x.RunCount == y.RunCount && x.SuccessCount == y.SuccessCount
            && x.FailureCount == y.FailureCount && x.BytesProcessed == y.BytesProcessed && x.BytesPerSecond == y.BytesPerSecond
            && x.PhaseDurations.Count == y.PhaseDurations.Count
            && x.PhaseDurations.All(pair => y.PhaseDurations.TryGetValue(pair.Key, out var value) && value == pair.Value),
        x => HashCode.Combine(x.Producer, x.RunCount, x.SuccessCount, x.FailureCount, x.BytesProcessed, x.BytesPerSecond));
    public static IEqualityComparer<MetricsView> Metrics { get; } = ListView<MetricsView, ProducerMetricsView>(x => x.Producers, Producer);

    public static IEqualityComparer<TView> ListView<TView, TItem>(Func<TView, IReadOnlyList<TItem>> items,
        IEqualityComparer<TItem>? comparer = null) where TView : class => EqualityComparer<TView>.Create(
            (x, y) => ReferenceEquals(x, y) || x is not null && y is not null && SequenceEqual(items(x), items(y), comparer),
            x => SequenceHash(items(x), comparer));

    public static bool SequenceEqual<T>(IReadOnlyList<T> x, IReadOnlyList<T> y, IEqualityComparer<T>? comparer = null)
    {
        if (ReferenceEquals(x, y)) return true;
        if (x.Count != y.Count) return false;
        comparer ??= EqualityComparer<T>.Default;
        for (var i = 0; i < x.Count; i++) if (!comparer.Equals(x[i], y[i])) return false;
        return true;
    }

    private static int SequenceHash<T>(IReadOnlyList<T> items, IEqualityComparer<T>? comparer = null)
    {
        var hash = new HashCode();
        foreach (var item in items) hash.Add(item, comparer);
        return hash.ToHashCode();
    }
}
