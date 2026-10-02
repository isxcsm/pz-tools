using PzTools.GameExtensions;
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
        await using var lease = await GameExtensionClient.ConnectAsync(bridge, game.Pid, deadline.Token);
        var control = lease.Module(ExtensionIds.VehicleDrivetrain);
        Assert.Equal(RuntimeExtensionState.Disabled, (await lease.StatusAsync(deadline.Token)).State);
        Assert.Equal(RuntimeExtensionState.Disabled, (await control.StatusAsync(deadline.Token)).State);
        var pending = await control.ApplyAsync(ready.ProcessSession, ready.WorldSession, -1, 1,
            "pztools.vehicle-drivetrain", false, new Dictionary<string, string> { ["fixture_value"] = "first" }, deadline.Token);
        Assert.Equal(RuntimeExtensionState.Pending, pending.State);
        var active = await AwaitContinuousState(control, s => s.State == RuntimeExtensionState.Active, deadline.Token);
        Assert.Contains("fixtureValue=first", active.Diagnostics); Assert.Equal(1, active.AppliedRevision);
        // An active generation is called once per game frame, whether or not any vehicle hook fires.
        var framed = await AwaitContinuousState(control, s => FixtureCount(s, "fixtureFrames") >= 5, deadline.Token);
        Assert.Equal(0, FixtureCount(framed, "fixtureCallbacks"));
        Assert.Equal(0, FixtureCount(framed, "fixtureLateFrames"));
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
    public async Task ADebugToolOnTopOfTheGame_IsAPause_NotTheEndOfTheWorld()
    {
        using var temp = new TempDirectory();
        var bridge = ContinuousFixtureBridge(temp);
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid, bridge);
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        await using var lease = await GameExtensionClient.ConnectAsync(bridge, game.Pid, deadline.Token);
        var control = lease.Module(ExtensionIds.VehicleDrivetrain);
        await control.ApplyAsync(ready.ProcessSession, ready.WorldSession, -1, 1,
            ExtensionIds.VehicleDrivetrain, false, new Dictionary<string, string> { ["fixture_value"] = "first" }, deadline.Token);
        var active = await AwaitContinuousState(control, s => s.State == RuntimeExtensionState.Active, deadline.Token);

        // The game yields to a debug tool (the chunk viewer): the same world, loaded, with time standing still.
        await File.WriteAllTextAsync(temp.GetPath("open-debug-tool"), "open", deadline.Token);
        var yielded = await watch.WaitAsync(s => s.Pause == GamePause.Paused);
        Assert.True(yielded.IsWorldReady);
        Assert.Equal((ready.WorldSession, ready.ObserverEpoch), (yielded.WorldSession, yielded.ObserverEpoch));
        await Task.Delay(500, deadline.Token);
        var during = await control.PingAsync(deadline.Token);
        Assert.Equal((RuntimeExtensionState.Active, active.Generation), (during.State, during.Generation));

        await File.WriteAllTextAsync(temp.GetPath("close-debug-tool"), "close", deadline.Token);
        var back = await watch.WaitAsync(s => s.Pause == GamePause.Running && s.Sequence > yielded.Sequence);
        Assert.Equal(ready.WorldSession, back.WorldSession);
        var after = await control.PingAsync(deadline.Token);
        Assert.Equal((RuntimeExtensionState.Active, active.Generation), (after.State, after.Generation));
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
            await first.Module(ExtensionIds.VehicleDrivetrain).ApplyAsync(ready.ProcessSession, ready.WorldSession, -1, 1, "pztools.vehicle-drivetrain", false,
                new Dictionary<string, string>(), deadline.Token);
            generation = (await AwaitContinuousState(first.Module(ExtensionIds.VehicleDrivetrain), s => s.State == RuntimeExtensionState.Active, deadline.Token)).Generation;
        }
        // Observe actual ownership release; a transient BUSY is not permission to reuse an old session.
        GameExtensionClient? reconnected = null;
        while (reconnected is null)
        {
            try { reconnected = await GameExtensionClient.ConnectAsync(bridge, game.Pid, deadline.Token); }
            catch (GameSaveException) { await Task.Delay(100, deadline.Token); }
        }
        await using var secondLease = reconnected;
        var second = secondLease.Module(ExtensionIds.VehicleDrivetrain);
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

    [BridgeFact]
    public async Task TwoContinuousModulesShareOneLease_AndAreAppliedUpdatedAndRetiredIndependently()
    {
        using var temp = new TempDirectory();
        var bridge = ContinuousFixtureBridge(temp, withSecondModule: true);
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid, bridge);
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        await using var lease = await GameExtensionClient.ConnectAsync(bridge, game.Pid, deadline.Token);
        var vehicle = lease.Module(ExtensionIds.VehicleDrivetrain);
        // A module that exists only for this test: the transport runs any catalogued continuous module.
        var second = lease.Module(SecondModule);
        Task<RuntimeExtensionStatus> Apply(GameExtensionModule module, long expected, long revision, string value) =>
            module.ApplyAsync(ready.ProcessSession, ready.WorldSession, expected, revision, module.ModuleId, false,
                new Dictionary<string, string> { ["fixture_value"] = value }, deadline.Token);

        Assert.Equal(RuntimeExtensionState.Pending, (await Apply(vehicle, -1, 1, "drive")).State);
        Assert.Equal(RuntimeExtensionState.Pending, (await Apply(second, -1, 2, "second")).State);
        var driving = await AwaitContinuousState(vehicle, s => s.State == RuntimeExtensionState.Active && FixtureCount(s, "fixtureFrames") >= 3, deadline.Token);
        var secondActive = await AwaitContinuousState(second, s => s.State == RuntimeExtensionState.Active && FixtureCount(s, "secondFrames") >= 3, deadline.Token);
        Assert.Equal((1L, 2L), (driving.AppliedRevision, secondActive.AppliedRevision));
        Assert.NotEqual(driving.Generation, secondActive.Generation);
        Assert.Contains("fixtureValue=drive", driving.Diagnostics);
        Assert.Contains("secondValue=second", secondActive.Diagnostics);
        // A command must name the module it means.
        await Assert.ThrowsAsync<ArgumentException>(() => second.ApplyAsync(ready.ProcessSession, ready.WorldSession, 2, 3,
            ExtensionIds.VehicleDrivetrain, false, new Dictionary<string, string>(), deadline.Token));

        // With the game paused nothing can be applied on the game thread. A new settings revision that
        // leaves this module's configuration as it was is still acknowledged at once, while a real
        // change to the other module waits. Neither holds the other up.
        await File.WriteAllTextAsync(temp.GetPath("pause-game"), "pause", deadline.Token);
        await watch.WaitAsync(s => s.Pause == GamePause.Paused);
        var unchanged = await Apply(vehicle, 1, 3, "drive");
        Assert.Equal((RuntimeExtensionState.Active, 3L, driving.Generation), (unchanged.State, unchanged.AppliedRevision, unchanged.Generation));
        var waiting = await Apply(second, 2, 3, "stronger");
        Assert.Equal((RuntimeExtensionState.Pending, 2L), (waiting.State, waiting.AppliedRevision));
        Assert.Equal(RuntimeExtensionState.Active, (await vehicle.PingAsync(deadline.Token)).State);
        await File.WriteAllTextAsync(temp.GetPath("resume-game"), "resume", deadline.Token);
        await watch.WaitAsync(s => s.Pause == GamePause.Running);
        var updated = await AwaitContinuousState(second, s => s.State == RuntimeExtensionState.Active && s.AppliedRevision == 3, deadline.Token);
        Assert.Contains("secondValue=stronger", updated.Diagnostics);
        Assert.Equal(secondActive.Generation, updated.Generation);

        // One module faults on its own; the other does not notice.
        await second.ApplyAsync(ready.ProcessSession, ready.WorldSession, 3, 4, second.ModuleId, false,
            new Dictionary<string, string> { ["fixture_fail"] = "true" }, deadline.Token);
        var faulted = await AwaitContinuousState(second, s => s.State == RuntimeExtensionState.FaultedPassThrough, deadline.Token);
        Assert.Equal("provider-failed:fixture-failed", faulted.Reason);
        var still = await vehicle.PingAsync(deadline.Token);
        Assert.Equal((RuntimeExtensionState.Active, driving.Generation), (still.State, still.Generation));
        Assert.Equal(RuntimeExtensionState.Disabled, (await lease.StatusAsync(deadline.Token)).State);

        // Turning one off leaves the other running on the same lease.
        Assert.Equal(RuntimeExtensionState.Disabled, (await second.DisableAsync(deadline.Token)).State);
        var frames = FixtureCount(await vehicle.PingAsync(deadline.Token), "fixtureFrames");
        var later = await AwaitContinuousState(vehicle, s => FixtureCount(s, "fixtureFrames") > frames, deadline.Token);
        Assert.Equal((RuntimeExtensionState.Active, driving.Generation, 3L), (later.State, later.Generation, later.AppliedRevision));
        Assert.Equal(RuntimeExtensionState.Pending, (await Apply(second, -1, 5, "again")).State);
        var again = await AwaitContinuousState(second, s => s.State == RuntimeExtensionState.Active, deadline.Token);
        Assert.NotEqual(secondActive.Generation, again.Generation);

        // OFF without a module is the whole host.
        Assert.Equal(RuntimeExtensionState.Disabled, (await lease.DisableAsync(deadline.Token)).State);
        Assert.Equal(RuntimeExtensionState.Disabled, (await vehicle.StatusAsync(deadline.Token)).State);
        Assert.Equal(RuntimeExtensionState.Disabled, (await second.StatusAsync(deadline.Token)).State);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }

    private static int FixtureCount(RuntimeExtensionStatus status, string key) =>
        status.Diagnostics?.Split(';').Select(field => field.Split('='))
            .Where(pair => pair.Length == 2 && pair[0] == key).Select(pair => int.Parse(pair[1])).FirstOrDefault(-1) ?? -1;

    private const string SecondModule = "pztools.second-module";

    private static string ContinuousFixtureBridge(TempDirectory temp, bool withSecondModule = false)
    {
        var bridge = temp.GetPath("continuous-bridge");
        foreach (var source in Directory.EnumerateFiles(RuntimeBridgeDirectory(), "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(bridge, Path.GetRelativePath(RuntimeBridgeDirectory(), source));
            Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(source, target);
        }
        var fixture = Environment.GetEnvironmentVariable("PZTOOLS_CONTINUOUS_FIXTURE_JAR")
            ?? throw new InvalidOperationException("Continuous fixture must be prepared.");
        File.Copy(fixture, Path.Combine(bridge, "extensions", "pztools-vehicle-drivetrain.jar"), true);
        if (withSecondModule)
        {
            // The second synthetic module is built beside the first and catalogued only in this copy.
            File.Copy(Path.Combine(Path.GetDirectoryName(fixture)!, "second-fixture.jar"),
                Path.Combine(bridge, "extensions", "pztools-second-module.jar"), true);
            File.AppendAllText(Path.Combine(bridge, "extensions", "catalog.tsv"),
                SecondModule + "\t0.1.0\tpztools.extensions.second\tpztools.extensions.second.SecondModuleProvider\tpztools-second-module.jar"
                + "\tMajor\t42\t42\tExtension.Second.Title\tExtension.Second.Description\tvehicle.drivetrain.v1\n");
        }
        return bridge;
    }

    private static async Task<RuntimeExtensionStatus> AwaitContinuousState(IGameExtensionSession client,
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
