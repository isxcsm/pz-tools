using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.SaveBridge;

namespace PzTools.Backup.Tests;

public sealed class ContinuousExtensionContractsTests
{
    [Theory]
    [InlineData(-1)]
    [InlineData(0)]
    [InlineData(4999)]
    [InlineData(60001)]
    public async Task ConnectionTimeoutRejectsInvalidValuesBeforeStartingAHelper(int milliseconds)
    {
        using var temp = new TempDirectory();
        var error = await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => GameExtensionClient.ConnectAsync(
            temp.GetPath("missing-bridge"), 1, TimeSpan.FromMilliseconds(milliseconds), CancellationToken.None));
        Assert.Equal("connectTimeout", error.ParamName);
    }

    [Theory]
    [InlineData(5)]
    [InlineData(60)]
    public async Task ConnectionTimeoutAcceptsBoundsBeforeCheckingBridgeFiles(int seconds)
    {
        using var temp = new TempDirectory();
        var error = await Assert.ThrowsAsync<GameSaveException>(() => GameExtensionClient.ConnectAsync(
            temp.GetPath("missing-bridge"), 1, TimeSpan.FromSeconds(seconds), CancellationToken.None));
        Assert.Equal("bridge-not-built", error.Code);
    }

    [Fact]
    public async Task OriginalConnectionOverloadRetainsItsDefault()
    {
        using var temp = new TempDirectory();
        var error = await Assert.ThrowsAsync<GameSaveException>(() => GameExtensionClient.ConnectAsync(
            temp.GetPath("missing-bridge"), 1, CancellationToken.None));
        Assert.Equal("bridge-not-built", error.Code);
    }

    [Fact]
    public void StatusProtocolBindsCommandAndAppliedIdentity()
    {
        var process = Guid.NewGuid().ToString("N"); var world = Guid.NewGuid().ToString("N");
        var generation = Guid.NewGuid().ToString("N"); var hash = new string('a', 64);
        var frame = $"STATE\tcmd\tActive\t-\t{process}\t{world}\t{generation}\t3\t0.1.0\t{hash}\t{Convert.ToBase64String("latest=1"u8)}";
        var parsed = RuntimeExtensionStatus.ParseWire(frame, "cmd");
        Assert.Equal(RuntimeExtensionState.Active, parsed.State);
        Assert.Equal(3, parsed.AppliedRevision); Assert.Equal(hash, parsed.ModuleHash); Assert.Equal("latest=1", parsed.Diagnostics);
        Assert.Throws<InvalidDataException>(() => RuntimeExtensionStatus.ParseWire(frame, "another"));
        Assert.Throws<InvalidDataException>(() => RuntimeExtensionStatus.ParseWire(frame.Replace(generation, "-"), "cmd"));
        Assert.Throws<InvalidDataException>(() => RuntimeExtensionStatus.ParseWire(frame + "\textra", "cmd"));
        Assert.Throws<InvalidDataException>(() => new RuntimeExtensionStatus(RuntimeExtensionState.Active).Validate());
    }

    [Fact]
    public void ExtensionFreshnessDoesNotChangeSavePolicyIdentity()
    {
        var clock = new Clock(); var extensions = new RuntimeExtensionStatusStore(clock);
        extensions.Publish(new(RuntimeExtensionState.Pending, "safe-boundary"));
        clock.Advance(500); Assert.Equal(500, extensions.Read().AgeMilliseconds);
        var baseline = RuntimeObservation.Unknown("fixture");
        var observation = baseline with { Extension = extensions.Read() };
        Assert.Equal(baseline.SemanticKey, observation.SemanticKey);
        var feed = new RuntimeSnapshotStore(clock); feed.Publish(observation);
        clock.Advance(750); Assert.Equal(1250, feed.Read().Extension!.AgeMilliseconds);
        Assert.Equal(observation, RuntimeJson.Read<RuntimeObservation>(RuntimeJson.Write(observation)));
    }

    private sealed class Clock : TimeProvider
    {
        private long milliseconds;
        public override long TimestampFrequency => 1000;
        public override long GetTimestamp() => milliseconds;
        public void Advance(long value) => milliseconds += value;
    }
}

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task ContinuousExtensionComposesWithWatchAndSave_ConfigAppliesAtGameBoundary_OffWorksPaused()
    {
        using var temp = new TempDirectory();
        var bridge = ContinuousFixtureBridge(temp);
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid, bridge);
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        await using var control = await GameExtensionClient.ConnectAsync(bridge, game.Pid, deadline.Token);
        Assert.Equal(RuntimeExtensionState.Disabled, (await control.StatusAsync(deadline.Token)).State);
        var pending = await control.ApplyAsync(ready.ProcessSession, ready.WorldSession, -1, 1,
            "pztools.vehicle-drivetrain", false, new Dictionary<string, string> { ["fixture_value"] = "first" }, deadline.Token);
        Assert.Equal(RuntimeExtensionState.Pending, pending.State);
        var active = await AwaitContinuousState(control, s => s.State == RuntimeExtensionState.Active, deadline.Token);
        Assert.Contains("fixtureValue=first", active.Diagnostics); Assert.Equal(1, active.AppliedRevision);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        await new GameSaveClient(bridge).RequestAsync(game.Pid, temp.Path, true, deadline.Token);
        var afterSave = await watch.WaitAsync(s => s.Sequence > ready.Sequence + 1);
        Assert.Equal(ready.ObserverEpoch, afterSave.ObserverEpoch);
        Assert.Equal(active.Generation, (await control.PingAsync(deadline.Token)).Generation);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        await File.WriteAllTextAsync(temp.GetPath("pause-game"), "pause", deadline.Token);
        await watch.WaitAsync(s => s.Pause == GamePause.Paused);
        var update = await control.ApplyAsync(ready.ProcessSession, ready.WorldSession, 1, 2,
            "pztools.vehicle-drivetrain", false, new Dictionary<string, string> { ["fixture_value"] = "second" }, deadline.Token);
        Assert.Equal(RuntimeExtensionState.Pending, update.State);
        Assert.Equal(1, (await control.PingAsync(deadline.Token)).AppliedRevision);
        Assert.Equal(RuntimeExtensionState.Disabled, (await control.DisableAsync(deadline.Token)).State);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        await File.WriteAllTextAsync(temp.GetPath("resume-game"), "resume", deadline.Token);
        await watch.WaitAsync(s => s.Pause == GamePause.Running);
        await control.ApplyAsync(ready.ProcessSession, ready.WorldSession, -1, 3,
            "pztools.vehicle-drivetrain", false, new Dictionary<string, string> { ["fixture_value"] = "third" }, deadline.Token);
        var replacement = await AwaitContinuousState(control, s => s.State == RuntimeExtensionState.Active, deadline.Token);
        Assert.NotEqual(active.Generation, replacement.Generation); Assert.Equal(3, replacement.AppliedRevision);
        Assert.Contains("fixtureValue=third", replacement.Diagnostics);
    }

    [BridgeFact]
    public async Task ContinuousDisconnectRetiresOldGeneration_AndWorldExitRevokesWithoutAnotherSave()
    {
        using var temp = new TempDirectory(); var bridge = ContinuousFixtureBridge(temp);
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid, bridge);
        var ready = await watch.WaitAsync(s => s.IsWorldReady);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        string? generation;
        await using (var first = await GameExtensionClient.ConnectAsync(bridge, game.Pid, deadline.Token))
        {
            await first.ApplyAsync(ready.ProcessSession, ready.WorldSession, -1, 1, "pztools.vehicle-drivetrain", false,
                new Dictionary<string, string>(), deadline.Token);
            generation = (await AwaitContinuousState(first, s => s.State == RuntimeExtensionState.Active, deadline.Token)).Generation;
        }
        // Observe actual ownership release; a transient BUSY is not permission to reuse an old session.
        GameExtensionClient? reconnected = null;
        while (reconnected is null)
        {
            try { reconnected = await GameExtensionClient.ConnectAsync(bridge, game.Pid, deadline.Token); }
            catch (GameSaveException) { await Task.Delay(100, deadline.Token); }
        }
        await using var second = reconnected;
        Assert.Equal(RuntimeExtensionState.Disabled, (await second.StatusAsync(deadline.Token)).State);
        await second.ApplyAsync(ready.ProcessSession, ready.WorldSession, -1, 2, "pztools.vehicle-drivetrain", false,
            new Dictionary<string, string>(), deadline.Token);
        var active = await AwaitContinuousState(second, s => s.State == RuntimeExtensionState.Active, deadline.Token);
        Assert.NotEqual(generation, active.Generation);
        await File.WriteAllTextAsync(temp.GetPath("leave-world"), "leave", deadline.Token);
        await watch.WaitAsync(s => s.Phase == WorldPhase.Menu);
        await AwaitContinuousState(second, s => s.State == RuntimeExtensionState.Disabled, deadline.Token);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }

    private static string ContinuousFixtureBridge(TempDirectory temp)
    {
        var bridge = temp.GetPath("continuous-bridge");
        foreach (var source in Directory.EnumerateFiles(RuntimeBridgeDirectory(), "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(bridge, Path.GetRelativePath(RuntimeBridgeDirectory(), source));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(source, target);
        }
        File.Copy(Environment.GetEnvironmentVariable("PZTOOLS_CONTINUOUS_FIXTURE_JAR")
            ?? throw new InvalidOperationException("Continuous fixture must be prepared."),
            Path.Combine(bridge, "extensions", "pztools-vehicle-drivetrain.jar"), true);
        return bridge;
    }

    private static async Task<RuntimeExtensionStatus> AwaitContinuousState(GameExtensionClient client,
        Func<RuntimeExtensionStatus, bool> predicate, CancellationToken token)
    {
        while (true)
        {
            var state = await client.PingAsync(token);
            if (predicate(state)) return state;
            await Task.Delay(30, token);
        }
    }
}
