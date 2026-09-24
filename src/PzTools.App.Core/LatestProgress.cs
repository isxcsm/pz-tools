namespace PzTools.App.Core;

// A single-slot mailbox, not a queue. The UI samples it on its own timer, so a
// blocked dispatcher never accumulates callbacks or replays obsolete progress.
public sealed class LatestProgress<T> : IProgress<T> where T : class
{
    private T? latest;

    public void Report(T value) => Interlocked.Exchange(ref latest, value);

    public T? TakeLatest() => Interlocked.Exchange(ref latest, null);
}
