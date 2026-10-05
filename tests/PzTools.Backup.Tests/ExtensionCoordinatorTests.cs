using PzTools.GameBridge;
using PzTools.GameExtensions;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.State.Scheduler;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    /// <summary>
    /// The scheduler's coordinator against a synthetic game and a synthetic module: saved
    /// preferences in, one lease, the module's status out. A rejected configuration turns it off.
    /// </summary>
    [BridgeFact]
    public async Task Coordinator_RunsTheModuleFromItsPreference_AndARejectedConfigurationTurnsItOff()
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
        const string vehicle = ExtensionIds.VehicleDrivetrain;
        try
        {
            // Nothing asked for: the module is confirmed off.
            await Until(vehicle, s => s.State == RuntimeExtensionState.Disabled && s.ControlReady, "vehicle confirmed off");

            // Switched on: active at the saved revision, with the options it was asked for.
            Assert.Equal(1, settings.SetEnabled(vehicle, true, 0).Revision);
            var driving = await Until(vehicle, s => s.State == RuntimeExtensionState.Active && s.AppliedRevision == 1, "vehicle active");
            Assert.NotNull(driving.AppliedVehicleOptions);

            // Its options change: applied to the running generation, not a new one.
            Assert.Equal(2, settings.SetPreference(vehicle, new(true, false, new VehicleDrivetrainPreference(TorqueEnabled: false)), 1).Revision);
            var retuned = await Until(vehicle, s => s.State == RuntimeExtensionState.Active && s.AppliedRevision == 2, "vehicle options applied");
            Assert.Equal(driving.Generation, retuned.Generation);

            // Its tuning file becomes invalid. The next request is rejected before it reaches the game:
            // the module is turned off, in the game and in the saved preferences, which keep its options.
            Directory.CreateDirectory(Path.Combine(runtimeRoot, "extensions"));
            await File.WriteAllTextAsync(Path.Combine(runtimeRoot, "extensions", "vehicle-drivetrain.toml"), "area_light_radius = 999\n");
            Assert.Equal(3, settings.SetPreference(vehicle, new(true, false, new VehicleDrivetrainPreference(ReverseEnabled: false)), 2).Revision);
            var rejected = await Until(vehicle, s => s.State == RuntimeExtensionState.Unsupported && s.Reason == "configuration-rejected", "vehicle rejected");
            Assert.False(rejected.ControlReady);
            var after = settings.Read();
            Assert.Equal(4, after.Revision);
            Assert.False(after.Extensions[vehicle].Enabled);
            Assert.Equal(new VehicleDrivetrainPreference(ReverseEnabled: false), after.Extensions[vehicle].VehicleDrivetrain);
        }
        finally
        {
            await stop.CancelAsync();
            try { await run; } catch (OperationCanceledException) { }
            await feed;
        }
        // Without a coordinator nothing is known about any module.
        Assert.Equal("observer-disconnected", published.Read(vehicle).Reason);
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

    /// <summary>
    /// A game still running the bootstrap from before an update of the app refuses the extension link. That is the
    /// restart the update needs, reported as such, and the player's preference stays on for the next game.
    /// </summary>
    [BridgeFact]
    public async Task Coordinator_ReportsAGameThatNeedsARestartAfterAnUpdate_AndKeepsThePreference()
    {
        using var temp = new TempDirectory();
        var bridge = ContinuousFixtureBridge(temp);
        var runtimeRoot = temp.GetPath("runtime");
        // What a bootstrap of API 10 (PZ Tools 0.2.1 and before) leaves in a game it was attached to.
        await using var game = await FakeGame.StartAsync(temp.Path, "normal", properties:
            ["pztools.bridge.control.v1=2:1:1:" + new string('0', 64), "pztools.bridge.bootstrap.api=10"]);

        // Such a game cannot be watched either; the scheduler's last word on it is a ready world.
        var stream = Guid.NewGuid().ToString("N");
        var observations = new RuntimeSnapshotStore();
        var published = new RuntimeExtensionStatusStore();
        string process = Guid.NewGuid().ToString("N"), world = Guid.NewGuid().ToString("N");
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        var feed = Task.Run(async () =>
        {
            for (long sequence = 1; !stop.IsCancellationRequested; sequence++)
            {
                observations.Publish(new RuntimeObservation(stream, RuntimeQuality.Fresh, new RuntimeSnapshot(process, stream, world,
                    1, 1, sequence, WorldPhase.Ready, GamePause.Running, RuntimeMode.LocalSinglePlayer, 1, sequence * 100, 0,
                    temp.GetPath("Saves", "Sandbox", "World"))));
                try { await Task.Delay(100, stop.Token); } catch (OperationCanceledException) { }
            }
        });
        var settings = new ExtensionSettingsStore(runtimeRoot);
        Assert.Equal(1, settings.SetEnabled(ExtensionIds.VehicleDrivetrain, true, 0).Revision);
        var run = new RuntimeExtensionCoordinator(bridge, runtimeRoot, observations, published,
            new ExtensionControlOptions(ReconcileIntervalMs: 250, ConnectTimeoutSeconds: 20)).RunAsync(game.Pid, stream, stop.Token);
        try
        {
            var give = DateTime.UtcNow.AddSeconds(30);
            RuntimeExtensionStatus status;
            while ((status = published.Read(ExtensionIds.VehicleDrivetrain)).State != RuntimeExtensionState.RestartRequired)
            {
                if (run.IsCompleted) await run;
                if (DateTime.UtcNow > give) throw new TimeoutException($"vehicle restart required: last status was {status}");
                await Task.Delay(50);
            }
            // The reason the Logs page and the sidebar's card read as "restart the game", not as a failure.
            Assert.Equal(GameExtensionActivationState.BootstrapUpdateReason, status.Reason);
            // Further rounds keep the answer and leave the preference alone.
            await Task.Delay(1000);
            Assert.Equal(GameExtensionActivationState.BootstrapUpdateReason, published.Read(ExtensionIds.VehicleDrivetrain).Reason);
            var after = settings.Read();
            Assert.Equal(1, after.Revision);
            Assert.True(after.Extensions[ExtensionIds.VehicleDrivetrain].Enabled);
        }
        finally
        {
            await stop.CancelAsync();
            try { await run; } catch (OperationCanceledException) { }
            await feed;
        }
    }
}
