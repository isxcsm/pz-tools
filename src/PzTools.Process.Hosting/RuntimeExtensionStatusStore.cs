using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Process.Hosting;

/// <summary>Independent freshness; extension heartbeats never create save-policy revisions.</summary>
public sealed class RuntimeExtensionStatusStore(TimeProvider? timeProvider = null)
{
    private sealed record Stamped(RuntimeExtensionStatus Status, long Timestamp);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private Stamped? current;
    public void Publish(RuntimeExtensionStatus status) =>
        Volatile.Write(ref current, new(status.Validate(), clock.GetTimestamp()));
    public RuntimeExtensionStatus Read()
    {
        var value = Volatile.Read(ref current);
        if (value is null) return new(RuntimeExtensionState.Disabled, "not-connected");
        var elapsed = Math.Max(0, (long)clock.GetElapsedTime(value.Timestamp).TotalMilliseconds);
        var age = Math.Min(long.MaxValue - elapsed, value.Status.AgeMilliseconds) + elapsed;
        return value.Status with { AgeMilliseconds = age };
    }
}
