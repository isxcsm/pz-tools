using System.Diagnostics;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;
using PzTools.SaveBridge;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.State.Scheduler;

/// <summary>Composition root for observation. Reception never waits for slow save discovery/SQLite.</summary>
internal sealed class RuntimeObservationCoordinator(StateDatabase state, SchedulerDatabase scheduler,
    string savesRoot, string bridgeDirectory, RuntimeSnapshotStore published)
{
    private readonly RuntimeSnapshotStore received = new();

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
                games = new[] { "ProjectZomboid64", "ProjectZomboid32", "ProjectZomboid" }
                    .SelectMany(System.Diagnostics.Process.GetProcessesByName).ToArray();
                if (games.Length != 1)
                {
                    received.Publish(new("", games.Length == 0 ? RuntimeQuality.Offline : RuntimeQuality.Ambiguous,
                        null, Reason: games.Length == 0 ? "no-game-process" : "multiple-games"));
                    failures = 0; await Task.Delay(1000, token); continue;
                }
                var game = games[0];
                var started = game.StartTime.ToUniversalTime(); // Bind discovery to an OS process instance, not just PID.
                string stream = Guid.NewGuid().ToString("N");
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
                try
                {
                    long lastConfigurationCheck = 0;
                    await foreach (var snapshot in new GameRuntimeClient(bridgeDirectory).WatchAsync(game.Id, connection.Token))
                    {
                        if (game.HasExited || game.StartTime.ToUniversalTime() != started) break;
                        failures = 0;
                        if (Stopwatch.GetElapsedTime(lastConfigurationCheck).TotalSeconds >= 2)
                        {
                            lastConfigurationCheck = Stopwatch.GetTimestamp();

                            var currentGames = new[] { "ProjectZomboid64", "ProjectZomboid32", "ProjectZomboid" }
                                .SelectMany(System.Diagnostics.Process.GetProcessesByName).ToArray();
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
                        bool validPath = !snapshot.IsWorldReady || RuntimeSaveResolver.Resolve(snapshot, savesRoot) is not null;
                        received.Publish(validPath ? new(stream, RuntimeQuality.Fresh, snapshot)
                            : new(stream, RuntimeQuality.Unsupported, snapshot, Reason: "outside-configured-save-root"));
                    }
                }
                finally { await connection.CancelAsync(); try { await exit; } catch (OperationCanceledException) { } }
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested)
            { if (received.Read().Quality != RuntimeQuality.Offline) received.Publish(RuntimeObservation.Unknown("runtime-disconnected")); }
            catch (Exception error) when (error is IOException or GameSaveException or InvalidOperationException
                or System.ComponentModel.Win32Exception or FormatException or OverflowException or UnauthorizedAccessException
                or Microsoft.Data.Sqlite.SqliteException)
            { received.Publish(RuntimeObservation.Unknown("runtime-unavailable")); }
            finally { foreach (var game in games) game.Dispose(); }
            failures = Math.Min(5, failures + 1);
            await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 1 << failures)), token);
        }
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