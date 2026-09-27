using PzTools.Zomboid.State;

namespace PzTools.Projections;

/// <summary>Display-only cache; never supplies gameplay/death authority. Failed reads have bounded retry cadence.</summary>
public sealed class CharacterProjectionCache(
    Func<string, CancellationToken, Task<CharacterSnapshot>> read,
    TimeProvider? timeProvider = null)
{
    private sealed record Entry(string? Version, CharacterSnapshot Snapshot, DateTimeOffset RetryAfter, int Failures);
    private readonly Dictionary<string, Entry> entries = new(StringComparer.OrdinalIgnoreCase);

    public async Task<CharacterSnapshot> ReadAsync(string path, string version, CancellationToken token = default)
    {
        token.ThrowIfCancellationRequested();
        var now = (timeProvider ?? TimeProvider.System).GetUtcNow();
        entries.TryGetValue(path, out var previous);
        if (previous is not null && (previous.Version == version || now < previous.RetryAfter))
            return previous.Snapshot;
        var current = await read(path, token);
        token.ThrowIfCancellationRequested();
        // Start backoff after the I/O completes, not before a potentially slow lock wait.
        now = (timeProvider ?? TimeProvider.System).GetUtcNow();
        if (current.ReadSucceeded)
            entries[path] = new Entry(version, current, now, 0);
        else
        {
            var failures = Math.Min(6, (previous?.Failures ?? 0) + 1);
            // Do not mark a failed version as read. Keep last good display through transient locks.
            current = previous?.Snapshot.ReadSucceeded == true ? previous.Snapshot : current;
            entries[path] = new Entry(previous?.Version, current,
                now.AddSeconds(Math.Min(30, 1 << (failures - 1))), failures);
        }
        return current;
    }

    public void RetainOnly(IEnumerable<string> paths)
    {
        var live = paths.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var path in entries.Keys.Where(path => !live.Contains(path)).ToArray()) entries.Remove(path);
    }
}
