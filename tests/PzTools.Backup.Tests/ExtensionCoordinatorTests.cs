using PzTools.GameExtensions;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.State.Scheduler;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    /// <summary>
    /// The scheduler's coordinator against a synthetic game and two synthetic modules: saved
    /// preferences in, one lease, per-module statuses out.
    /// </summary>
    [BridgeFact]
    public async Task Coordinator_RunsEachModuleFromItsOwnPreference_AndAFailureTurnsOffOnlyThatModule()
    {
        using var temp = new TempDirectory();
        var bridge = ContinuousFixtureBridge(temp);
        var runtimeRoot = temp.GetPath("runtime");
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid, bridge);
        await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);

        var stream = Guid.NewGuid().ToString("N");
        var observations = new RuntimeSnapshotStore();
        var published = new RuntimeExtensionStatusStore();
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        // What the scheduler's observation loop does: keep the latest game sample fresh.
        var feed = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                observations.Publish(new RuntimeObservation(stream, RuntimeQuality.Fresh, await watch.WaitAsync(_ => true)));
                try { await Task.Delay(100, stop.Token); } catch (OperationCanceledException) { }
            }
        });
        var settings = new ExtensionSettingsStore(runtimeRoot);
        var run = new RuntimeExtensionCoordinator(bridge, runtimeRoot, observations, published,
            new ExtensionControlOptions(ReconcileIntervalMs: 250, ConnectTimeoutSeconds: 20)).RunAsync(game.Pid, stream, stop.Token);
        async Task<RuntimeExtensionStatus> Until(string module, Func<RuntimeExtensionStatus, bool> reached, string what)
        {
            var give = DateTime.UtcNow.AddSeconds(30);
            while (true)
            {
                var status = published.Read(module);
                if (reached(status)) return status;
                if (run.IsCompleted) await run;
                if (DateTime.UtcNow > give) throw new TimeoutException($"{what}: last {module} status was {status}");
                await Task.Delay(50);
            }
        }
        const string vehicle = ExtensionIds.VehicleDrivetrain, look = ExtensionIds.ScreenLook;
        try
        {
            // Nothing asked for: both modules are confirmed off, on one lease.
            await Until(vehicle, s => s.State == RuntimeExtensionState.Disabled && s.ControlReady, "vehicle confirmed off");
            await Until(look, s => s.State == RuntimeExtensionState.Disabled && s.ControlReady, "look confirmed off");

            // Only the look is switched on. The vehicle module stays off and is not touched.
            Assert.Equal(1, settings.SetEnabled(look, true, 0).Revision);
            var looking = await Until(look, s => s.State == RuntimeExtensionState.Active && s.AppliedRevision == 1, "look active");
            var idle = await Until(vehicle, s => s.RequestedRevision == 1, "vehicle saw the new revision");
            Assert.Equal(RuntimeExtensionState.Disabled, idle.State);

            // The vehicle is switched on as well. For the look this is a new revision of the same
            // configuration: it follows the revision and keeps its generation.
            Assert.Equal(2, settings.SetEnabled(vehicle, true, 1).Revision);
            var driving = await Until(vehicle, s => s.State == RuntimeExtensionState.Active && s.AppliedRevision == 2, "vehicle active");
            var same = await Until(look, s => s.State == RuntimeExtensionState.Active && s.AppliedRevision == 2, "look follows the revision");
            Assert.Equal(looking.Generation, same.Generation);
            Assert.Equal(0, FixtureCount(same, "lookUpdates"));
            Assert.NotEqual(driving.Generation, same.Generation);
            Assert.NotNull(driving.AppliedVehicleOptions);

            // The look's options change. It is updated; the vehicle only follows the revision.
            Assert.Equal(3, settings.SetPreference(look, new(true, false, null, new ScreenLookPreference("vivid", 80, true)), 2).Revision);
            var restyled = await Until(look, s => s.State == RuntimeExtensionState.Active && s.AppliedRevision == 3, "look updated");
            Assert.Equal(1, FixtureCount(restyled, "lookUpdates"));
            Assert.Equal(looking.Generation, restyled.Generation);
            var undisturbed = await Until(vehicle, s => s.AppliedRevision == 3, "vehicle follows the revision");
            Assert.Equal((RuntimeExtensionState.Active, driving.Generation), (undisturbed.State, undisturbed.Generation));

            // The look's tuning file becomes invalid. Its next request is rejected before it reaches the
            // game: the look is turned off, in the game and in the saved preferences. The vehicle stays on.
            Directory.CreateDirectory(Path.Combine(runtimeRoot, "extensions"));
            await File.WriteAllTextAsync(Path.Combine(runtimeRoot, "extensions", "screen-look.toml"), "clarity_scale = 9\n");
            Assert.Equal(4, settings.SetPreference(look, new(true, false, null, new ScreenLookPreference("vivid", 70, true)), 3).Revision);
            var rejected = await Until(look, s => s.State == RuntimeExtensionState.Unsupported && s.Reason == "configuration-rejected", "look rejected");
            Assert.False(rejected.ControlReady);
            var after = settings.Read();
            Assert.Equal(5, after.Revision);
            Assert.False(after.Extensions[look].Enabled);
            Assert.Equal(new ScreenLookPreference("vivid", 70, true), after.Extensions[look].ScreenLook);
            Assert.True(after.Extensions[vehicle].Enabled);
            var surviving = await Until(vehicle, s => s.AppliedRevision == 5, "vehicle outlives the other module's failure");
            Assert.Equal((RuntimeExtensionState.Active, driving.Generation), (surviving.State, surviving.Generation));

            // The vehicle is switched off by the user; it is retired on the lease that is still open.
            Assert.Equal(6, settings.SetEnabled(vehicle, false, 5).Revision);
            await Until(vehicle, s => s.State == RuntimeExtensionState.Disabled && s.RequestedRevision == 6 && s.ControlReady, "vehicle off");
        }
        finally
        {
            await stop.CancelAsync();
            try { await run; } catch (OperationCanceledException) { }
            await feed;
        }
        // Without a coordinator nothing is known about any module.
        Assert.Equal("observer-disconnected", published.Read(vehicle).Reason);
        Assert.Equal("observer-disconnected", published.Read(look).Reason);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }

    /// <summary>
    /// A game thread busy for a few seconds (a long save of a big world) stops fresh samples. The coordinator
    /// keeps the lease and the running module instead of tearing it down and installing it again.
    /// </summary>
    [BridgeFact]
    public async Task Coordinator_KeepsModulesThroughAShortSilenceFromTheGame()
    {
        using var temp = new TempDirectory();
        var bridge = ContinuousFixtureBridge(temp);
        var runtimeRoot = temp.GetPath("runtime");
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid, bridge);
        await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);

        var stream = Guid.NewGuid().ToString("N");
        var observations = new RuntimeSnapshotStore();
        var published = new RuntimeExtensionStatusStore();
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        var silent = false;
        var feed = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                var sample = await watch.WaitAsync(_ => true);
                if (!Volatile.Read(ref silent)) observations.Publish(new RuntimeObservation(stream, RuntimeQuality.Fresh, sample));
                try { await Task.Delay(100, stop.Token); } catch (OperationCanceledException) { }
            }
        });
        var settings = new ExtensionSettingsStore(runtimeRoot);
        var run = new RuntimeExtensionCoordinator(bridge, runtimeRoot, observations, published,
            new ExtensionControlOptions(ReconcileIntervalMs: 250, ConnectTimeoutSeconds: 20)).RunAsync(game.Pid, stream, stop.Token);
        const string vehicle = ExtensionIds.VehicleDrivetrain;
        async Task<RuntimeExtensionStatus> Until(Func<RuntimeExtensionStatus, bool> reached, string what)
        {
            var give = DateTime.UtcNow.AddSeconds(30);
            while (true)
            {
                var status = published.Read(vehicle);
                if (reached(status)) return status;
                if (run.IsCompleted) await run;
                if (DateTime.UtcNow > give) throw new TimeoutException($"{what}: last status was {status}");
                await Task.Delay(50);
            }
        }
        try
        {
            Assert.Equal(1, settings.SetEnabled(vehicle, true, 0).Revision);
            var driving = await Until(s => s.State == RuntimeExtensionState.Active && s.AppliedRevision == 1, "vehicle active");

            // Five seconds without a fresh sample: longer than a sample stays fresh, shorter than the grace.
            Volatile.Write(ref silent, true);
            var seen = new List<RuntimeExtensionStatus>();
            for (var elapsed = 0; elapsed < 5000; elapsed += 100)
            {
                seen.Add(published.Read(vehicle));
                await Task.Delay(100);
            }
            Volatile.Write(ref silent, false);
            Assert.DoesNotContain(seen, s => s.Reason == "waiting-for-local-world" || s.State != RuntimeExtensionState.Active);

            await Task.Delay(1000);
            var after = await Until(s => s.State == RuntimeExtensionState.Active, "vehicle still active");
            Assert.Equal(driving.Generation, after.Generation);
        }
        finally
        {
            await stop.CancelAsync();
            try { await run; } catch (OperationCanceledException) { }
            await feed;
        }
    }
}
