using System.Diagnostics;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.GameBridge;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.State.Scheduler;

/// <summary>Composition root for observation. Reception never waits for slow save discovery/SQLite.</summary>
internal sealed class RuntimeObservationCoordinator(StateDatabase state, SchedulerDatabase scheduler,
    string savesRoot, string bridgeDirectory, RuntimeSnapshotStore published,
    string runtimeRoot, RuntimeExtensionStatusStore extensions, ExtensionControlOptions extensionOptions,
    Func<CancellationToken, Task<long>>? allocateRunIndex = null, string? telemetryConfigurationPath = null,
    string? appRun = null)
{
    private readonly RuntimeSnapshotStore received = new();
    // The game process that refused the link for running a bridge from before an update; not asked again.
    private (int Id, DateTime Started)? refusedGame;

    public async Task RunAsync(CancellationToken token)
    {
        using var scope = CancellationTokenSource.CreateLinkedTokenSource(token);
        var reception = ReceiveAsync(scope.Token);
        var publication = PublishAsync(scope.Token);
        try { await await Task.WhenAny(reception, publication); }
        finally { await scope.CancelAsync(); try { await Task.WhenAll(reception, publication); } catch (OperationCanceledException) { } }
    }
    private async Task ReceiveAsync(CancellationToken token)
    {
        int failures = 0;
        while (!token.IsCancellationRequested)
        {
            System.Diagnostics.Process[] games = [];
            try
            {
                // A shared read-only runtime feed serves pause policy and extension metadata.
                // Disabling pause-aware scheduling does not disable other consumers or create a second watcher.
                // Checked every second while no game runs, from a process list shared with the exit watcher.
                games = GameProcessFinder.Find(GameProcessFinder.WatchSnapshotAge);
                if (games.Length != 1)
                {
                    extensions.Publish(new(RuntimeExtensionState.Disabled, games.Length == 0 ? "no-game-process" : "multiple-games"));
                    received.Publish(new("", games.Length == 0 ? RuntimeQuality.Offline : RuntimeQuality.Ambiguous,
                        null, Reason: games.Length == 0 ? "no-game-process" : "multiple-games"));
                    failures = 0; await Task.Delay(1000, token); continue;
                }
                var game = games[0];
                var started = game.StartTime.ToUniversalTime(); // Bind discovery to an OS process instance, not just PID.
                // A game that refused for running a bridge from before an update keeps refusing until it restarts:
                // asked again it would only start another attach helper. Its state stays said until it exits.
                if (refusedGame == (game.Id, started))
                {
                    received.Publish(RuntimeObservation.Unknown(RuntimeObservation.RestartRequiredReason));
                    extensions.Publish(new(RuntimeExtensionState.RestartRequired, "bootstrap-update"));
                    failures = 0; await Task.Delay(1000, token); continue;
                }
                refusedGame = null;
                string stream = Guid.NewGuid().ToString("N");
                received.Publish(RuntimeObservation.Unknown("connecting"));
                using var connection = CancellationTokenSource.CreateLinkedTokenSource(token);
                async Task WatchExitAsync()
                {
                    try
                    {
                        await game.WaitForExitAsync(connection.Token);
                        received.Publish(new("", RuntimeQuality.Offline, null, Reason: "game-exited"));
                        await connection.CancelAsync();
                    }
                    catch (OperationCanceledException) { }
                }
                var exit = WatchExitAsync();
                // Extension control is optional; its failure must not end the observation that times backups.
                var control = OptionalWorkSupervisor.RunAsync(
                    stop => new RuntimeExtensionCoordinator(bridgeDirectory, runtimeRoot, received, extensions, extensionOptions)
                        .RunAsync(game.Id, stream, stop),
                    () => extensions.Publish(new(RuntimeExtensionState.FaultedPassThrough, "controller-failed")),
                    connection.Token);
                try
                {
                    long lastConfigurationCheck = 0;
                    // The stream renews the app run's lease in the game: what the run asked of it lasts while connected.
                    await foreach (var snapshot in new GameRuntimeClient(bridgeDirectory).WatchAsync(game.Id, appRun, connection.Token))
                    {
                        if (game.HasExited || game.StartTime.ToUniversalTime() != started) break;
                        failures = 0;
                        if (Stopwatch.GetElapsedTime(lastConfigurationCheck).TotalSeconds >= 2)
                        {
                            lastConfigurationCheck = Stopwatch.GetTimestamp();

                            var currentGames = GameProcessFinder.Find();
                            try
                            {
                                if (currentGames.Length != 1 || currentGames[0].Id != game.Id)
                                {
                                    received.Publish(new("", RuntimeQuality.Ambiguous, null, Reason: "multiple-games"));
                                    break;
                                }
                            }
                            finally { foreach (var process in currentGames) process.Dispose(); }
                        }
                        if (snapshot.IsBeforeFirstFrame)
                        {
                            // Connected, but the game is still loading; that can take minutes.
                            received.Publish(RuntimeObservation.Unknown(RuntimeObservation.GameStartingReason));
                            continue;
                        }
                        bool validPath = !snapshot.IsWorldReady || RuntimeSaveResolver.Resolve(snapshot, savesRoot) is not null;
                        received.Publish(validPath ? new(stream, RuntimeQuality.Fresh, snapshot)
                            : new(stream, RuntimeQuality.Unsupported, snapshot, Reason: "outside-configured-save-root"));
                    }
                }
                finally { await connection.CancelAsync(); try { await Task.WhenAll(exit, control); } catch (OperationCanceledException) { } }
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested)
            { if (received.Read().Quality != RuntimeQuality.Offline) received.Publish(RuntimeObservation.Unknown("runtime-disconnected")); }
            catch (Exception error) when (error is IOException or InvalidDataException or GameSaveException or InvalidOperationException
                or System.ComponentModel.Win32Exception or FormatException or OverflowException or UnauthorizedAccessException
                or Microsoft.Data.Sqlite.SqliteException)
            {
                bool restart = error is GameSaveException { Code: "restart-required" };
                received.Publish(RuntimeObservation.Unknown(error is GameSaveException { Code: var code } ? code switch
                {
                    "restart-required" => RuntimeObservation.RestartRequiredReason,
                    AttachDiagnostics.ElevationCode => RuntimeObservation.ElevationReason,
                    AttachDiagnostics.DisabledCode => RuntimeObservation.AttachDisabledReason,
                    _ => "runtime-unavailable",
                } : "runtime-unavailable"));
                if (restart) extensions.Publish(new(RuntimeExtensionState.RestartRequired, "bootstrap-update"));
                if (restart && games.Length == 1)
                {
                    try { refusedGame = (games[0].Id, games[0].StartTime.ToUniversalTime()); }
                    catch (Exception gone) when (gone is InvalidOperationException or System.ComponentModel.Win32Exception) { }
                }
                if (error is GameSaveException { Diagnostics: not null } attach && games.Length == 1)
                    await RecordAttachFailureAsync(games[0], attach, token);
            }
            finally { foreach (var game in games) game.Dispose(); }
            failures = Math.Min(5, failures + 1);
            await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 1 << failures)), token);
        }
    }

    // The game and cause last written to the log: the link retries every half minute, and one entry per game and
    // cause says all a repeat would.
    private (int ProcessId, DateTime Started, string Code)? attachLogged;

    private async Task RecordAttachFailureAsync(System.Diagnostics.Process game, GameSaveException failure, CancellationToken token)
    {
        if (allocateRunIndex is null) return;
        DateTime started;
        try { started = game.StartTime; }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception) { return; }
        var key = (game.Id, started, failure.Code);
        if (attachLogged == key) return;
        attachLogged = key;
        long run;
        // The log is a record, never a reason to stop watching the game.
        try { run = await allocateRunIndex(token); }
        catch (Exception error) when (error is not OperationCanceledException) { return; }
        await PzTools.Process.Telemetry.BestEffortProcessTelemetry.TryRecordAsync(scheduler.DatabasePath, "state-scheduler",
            run, "game.link.failed",
            FailureTelemetry.FromException(failure.Code, failure, phase: "attach", operation: "game-link"),
            telemetryConfigurationPath);
    }

    private async Task PublishAsync(CancellationToken token)
    {
        RuntimeObservation? committed = null;
        var reducer = new RuntimeStateReactor();
        var relay = new StateOutboxRelay();
        while (!token.IsCancellationRequested)
        {
            var observation = received.Read();
            try
            {
                if (committed?.SemanticKey != observation.SemanticKey)
                {
                    // No new execution permission escapes before its policy transition commits.
                    published.Publish(RuntimeObservation.Unknown("state-transition-pending"));
                    var result = await NamedMutexRunner.TryRunAsync(
                        NamedMutexRunner.CreateName("StateCollection", state.DatabasePath), async ct =>
                        {
                            await state.StageRuntimeAsync(observation, ct);
                            var applied = await reducer.RunAsync(state, ct);
                            await relay.RelayRuntimeAsync(state, scheduler, savesRoot, ct);
                            return applied;
                        }, token);
                    if (result.Acquired && result.Value is { } applied) committed = applied;
                }
                if (committed?.SemanticKey == observation.SemanticKey)
                    published.Publish(observation with { StateRevision = committed.StateRevision, AuthorityEpoch = committed.AuthorityEpoch });
            }
            catch (Exception error) when (error is IOException or Microsoft.Data.Sqlite.SqliteException)
            { committed = null; published.Publish(RuntimeObservation.Unknown("runtime-state-commit-failed")); }
            await Task.Delay(100, token);
        }
    }
}
