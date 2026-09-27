namespace PzTools.Scheduling;

public static class BackupScheduleTiming
{
    // Keep the configured cadence instead of restarting an interval at completion.
    public static DateTimeOffset NextDue(DateTimeOffset scheduledUtc, TimeSpan interval, DateTimeOffset attemptUtc)
    {
        if (interval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(interval));
        var due = scheduledUtc;
        do { due = due.Add(interval); } while (due <= attemptUtc);
        return due;
    }
}
