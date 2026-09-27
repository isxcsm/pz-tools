using System.Collections.Concurrent;

namespace PzTools.Projections;

public readonly record struct ViewKey(string Value)
{
    public override string ToString() => Value;

    public static ViewKey SaveList { get; } = new("save-list");
    public static ViewKey ScheduleStatus { get; } = new("schedule-status");
    public static ViewKey BackupCatalog { get; } = new("backup-catalog");
    public static ViewKey Settings { get; } = new("settings");
    public static ViewKey Operations { get; } = new("operations");
    public static ViewKey Metrics { get; } = new("metrics");
    public static ViewKey TelemetrySources { get; } = new("telemetry-sources");
    public static ViewKey ProjectorHealth { get; } = new("projector-health");
    public static ViewKey Logs { get; } = new("logs");
    public static ViewKey SaveDetail(string saveId) => new($"save-detail:{saveId}");
}

public sealed record RevisionedView<T>(ViewKey Key, long ViewRevision, T Snapshot);

public sealed record ViewReadResult<T>(
    bool Modified,
    long ViewRevision,
    T? Snapshot);

public sealed class RevisionedViewStore
{
    private readonly ConcurrentDictionary<ViewKey, Entry> entries = new();
    private readonly object subscriberGate = new();
    private readonly Dictionary<long, Action<ViewKey, long>> subscribers = [];
    private long nextSubscriberId;

    public RevisionedView<T> Publish<T>(
        ViewKey key,
        T snapshot,
        long sourceVersion = 0,
        IEqualityComparer<T>? comparer = null)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        comparer ??= EqualityComparer<T>.Default;
        RevisionedView<T>? published = null;
        var changed = false;
        entries.AddOrUpdate(
            key,
            _ =>
            {
                published = new RevisionedView<T>(key, 1, snapshot);
                changed = true;
                return new Entry(typeof(T), snapshot, 1, sourceVersion);
            },
            (_, current) =>
            {
                if (current.SnapshotType != typeof(T))
                    throw new InvalidOperationException(
                        $"View '{key}' is already registered as {current.SnapshotType.Name}.");
                if (sourceVersion < current.SourceVersion)
                {
                    published = new RevisionedView<T>(
                        key, current.ViewRevision, (T)current.Snapshot);
                    return current;
                }
                if (comparer.Equals((T)current.Snapshot, snapshot))
                {
                    published = new RevisionedView<T>(
                        key, current.ViewRevision, (T)current.Snapshot);
                    return sourceVersion == current.SourceVersion
                        ? current
                        : current with { SourceVersion = sourceVersion };
                }
                var revision = checked(current.ViewRevision + 1);
                published = new RevisionedView<T>(key, revision, snapshot);
                changed = true;
                return new Entry(typeof(T), snapshot, revision, sourceVersion);
            });

        var result = published!;
        if (changed) Notify(key, result.ViewRevision);
        return result;
    }

    public ViewReadResult<T> ReadIfChanged<T>(ViewKey key, long lastSeenRevision)
    {
        if (lastSeenRevision < 0) throw new ArgumentOutOfRangeException(nameof(lastSeenRevision));
        if (!entries.TryGetValue(key, out var entry))
            return new ViewReadResult<T>(false, 0, default);
        if (entry.SnapshotType != typeof(T))
            throw new InvalidOperationException(
                $"View '{key}' contains {entry.SnapshotType.Name}, not {typeof(T).Name}.");
        return entry.ViewRevision == lastSeenRevision
            ? new ViewReadResult<T>(false, entry.ViewRevision, default)
            : new ViewReadResult<T>(true, entry.ViewRevision, (T)entry.Snapshot);
    }

    public IDisposable Subscribe(Action<ViewKey, long> callback)
    {
        ArgumentNullException.ThrowIfNull(callback);
        long id;
        lock (subscriberGate)
        {
            id = ++nextSubscriberId;
            subscribers.Add(id, callback);
        }
        return new Subscription(this, id);
    }

    private void Notify(ViewKey key, long revision)
    {
        Action<ViewKey, long>[] callbacks;
        lock (subscriberGate) callbacks = subscribers.Values.ToArray();
        foreach (var callback in callbacks)
        {
            try { callback(key, revision); }
            catch { }
        }
    }

    private void Unsubscribe(long id)
    {
        lock (subscriberGate) subscribers.Remove(id);
    }

    private sealed record Entry(
        Type SnapshotType,
        object Snapshot,
        long ViewRevision,
        long SourceVersion);

    private sealed class Subscription(RevisionedViewStore owner, long id) : IDisposable
    {
        private RevisionedViewStore? owner = owner;
        public void Dispose() => Interlocked.Exchange(ref owner, null)?.Unsubscribe(id);
    }
}
