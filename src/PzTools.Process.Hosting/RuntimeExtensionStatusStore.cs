using System.Collections.Immutable;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Process.Hosting;

/// <summary>
/// Independent freshness; extension heartbeats never create save-policy revisions. Each module has
/// its own status. A status published without a module is about the connection as a whole (no
/// game, not connected): it replaces what the modules reported, and stands for any module that
/// has not reported since.
/// </summary>
public sealed class RuntimeExtensionStatusStore(TimeProvider? timeProvider = null)
{
    private sealed record Stamped(RuntimeExtensionStatus Status, long Timestamp);
    private sealed record State(Stamped? Everything, ImmutableDictionary<string, Stamped> Modules);
    private static readonly ImmutableDictionary<string, Stamped> None = ImmutableDictionary.Create<string, Stamped>(StringComparer.Ordinal);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private State current = new(null, None);

    public void Publish(RuntimeExtensionStatus status) =>
        Volatile.Write(ref current, new(new(status.Validate(), clock.GetTimestamp()), None));

    public void Publish(string moduleId, RuntimeExtensionStatus status)
    {
        ArgumentException.ThrowIfNullOrEmpty(moduleId);
        var stamped = new Stamped(status.Validate(), clock.GetTimestamp());
        while (true)
        {
            var before = Volatile.Read(ref current);
            if (ReferenceEquals(Interlocked.CompareExchange(ref current, before with { Modules = before.Modules.SetItem(moduleId, stamped) }, before), before))
                return;
        }
    }

    public RuntimeExtensionStatus Read() => Aged(Volatile.Read(ref current).Everything);

    public RuntimeExtensionStatus Read(string moduleId)
    {
        var state = Volatile.Read(ref current);
        return Aged(state.Modules.GetValueOrDefault(moduleId) ?? state.Everything);
    }

    public IReadOnlyDictionary<string, RuntimeExtensionStatus> ReadModules() =>
        Volatile.Read(ref current).Modules.ToDictionary(pair => pair.Key, pair => Aged(pair.Value), StringComparer.Ordinal);

    private RuntimeExtensionStatus Aged(Stamped? value)
    {
        if (value is null) return new(RuntimeExtensionState.Disabled, "not-connected");
        var elapsed = Math.Max(0, (long)clock.GetElapsedTime(value.Timestamp).TotalMilliseconds);
        var age = Math.Min(long.MaxValue - elapsed, value.Status.AgeMilliseconds) + elapsed;
        return value.Status with { AgeMilliseconds = age };
    }
}
