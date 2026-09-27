using PzTools.Projections;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class CharacterProjectionTimingTests
{
    [Fact]
    public async Task SlowFailedRead_BackoffStartsAtCompletion_NotBeforeLockWait()
    {
        var clock = new ManualClock();
        var calls = 0;
        var cache = new CharacterProjectionCache((_, _) =>
        {
            calls++;
            clock.Now += TimeSpan.FromSeconds(2);
            return Task.FromResult(new CharacterSnapshot(null, CharacterState.Unknown, ReadSucceeded: false));
        }, clock);
        await cache.ReadAsync("players", "v1");
        await cache.ReadAsync("players", "v2");
        Assert.Equal(1, calls);
        clock.Now += TimeSpan.FromSeconds(1);
        await cache.ReadAsync("players", "v2");
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task CancellationDuringRead_DoesNotPublishNewVersion()
    {
        using var cancellation = new CancellationTokenSource();
        var calls = 0;
        var cache = new CharacterProjectionCache((_, _) =>
        {
            if (++calls == 1) cancellation.Cancel();
            return Task.FromResult(new CharacterSnapshot("Name", CharacterState.Alive));
        });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cache.ReadAsync("players", "v1", cancellation.Token));
        await cache.ReadAsync("players", "v1");
        Assert.Equal(2, calls);
    }

    private sealed class ManualClock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = DateTimeOffset.UnixEpoch;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
