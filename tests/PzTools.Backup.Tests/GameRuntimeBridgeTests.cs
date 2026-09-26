using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.SaveBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task RuntimeSubscription_DoesNotSave_AndPreservesPauseTimeWithoutBlockingManualSave()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var first = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        await File.WriteAllTextAsync(temp.GetPath("pause-game"), "pause");
        var paused = await watch.WaitAsync(s => s.Pause == GamePause.Paused);
        var stillPaused = await watch.WaitAsync(s => s.Pause == GamePause.Paused && s.Sequence > paused.Sequence + 1);
        Assert.Equal(paused.ActiveMilliseconds, stillPaused.ActiveMilliseconds);
        // A paused world is open. Explicit manual saves remain permitted and still flush memory.
        await Client().RequestAsync(game.Pid, temp.Path, true);
        Assert.Equal("1", await File.ReadAllTextAsync(temp.GetPath("memory-only-state.txt")));
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        await File.WriteAllTextAsync(temp.GetPath("resume-game"), "resume");
        var resumed = await watch.WaitAsync(s => s.Pause == GamePause.Running && s.ActiveMilliseconds > paused.ActiveMilliseconds);
        Assert.Equal(first.ObserverEpoch, resumed.ObserverEpoch);
        Assert.Equal(first.WorldSession, resumed.WorldSession);
        Assert.True(resumed.EligibilityEpoch > first.EligibilityEpoch);
    }

    [BridgeFact]
    public async Task GuardedSave_PauseDefersBeforeFlush_ResumeUsesNewTicket_AndDuplicateTicketDoesNotSaveAgain()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        var first = Ticket(ready, 1, 30_000);
        var submitted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: first,
            preparationAllowed: _ => { submitted.TrySetResult(); return Task.FromResult(true); })
            .RequestAsync(game.Pid, temp.Path, true);
        await submitted.Task.WaitAsync(TimeSpan.FromSeconds(15));
        await File.WriteAllTextAsync(temp.GetPath("pause-game"), "pause");
        await watch.WaitAsync(s => s.Pause == GamePause.Paused);
        var deferred = await Assert.ThrowsAsync<GameSaveException>(() => queued);
        Assert.Equal("runtime-deferred", deferred.Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        await File.WriteAllTextAsync(temp.GetPath("resume-game"), "resume");
        var resumed = await watch.WaitAsync(s => s.Pause == GamePause.Running && s.EligibilityEpoch > first.EligibilityEpoch);
        var second = Ticket(resumed, 2);
        await new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: second).RequestAsync(game.Pid, temp.Path, true);
        var duplicate = await Assert.ThrowsAsync<GameSaveException>(() =>
            new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: second).RequestAsync(game.Pid, temp.Path, true));
        Assert.Equal("runtime-deferred", duplicate.Code);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        Assert.Equal("1", await File.ReadAllTextAsync(temp.GetPath("memory-only-state.txt")));
    }

    [BridgeFact]
    public async Task GuardedSave_RevokedPreparationPermissionCancelsWithoutPausingGameOrSaving()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        int permission = 1;
        var submitted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(ready, 1, 30_000),
            preparationAllowed: _ => { submitted.TrySetResult(); return Task.FromResult(Volatile.Read(ref permission) == 1); })
            .RequestAsync(game.Pid, temp.Path, true);
        await submitted.Task.WaitAsync(TimeSpan.FromSeconds(15));
        Volatile.Write(ref permission, 0);
        var result = await Assert.ThrowsAsync<GameSaveException>(() => queued);
        Assert.Equal("runtime-deferred", result.Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        var latest = await watch.WaitAsync(s => s.Sequence > ready.Sequence);
        Assert.Equal(GamePause.Running, latest.Pause);
        await new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(latest, 2),
            preparationAllowed: _ => Task.FromResult(true)).RequestAsync(game.Pid, temp.Path, true);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
    }

    [BridgeFact]
    public async Task StoppedObservationInvalidatesGuard_WithoutUninstallingOrDisablingManualSave()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var watch = new RuntimeWatchCapture(game.Pid);
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        await watch.DisposeAsync();
        // A future guarded deadline cannot execute before subscription teardown is observed.
        // Assert the protocol outcome instead of repeatedly inspecting/retransforming classes.
        var error = await Assert.ThrowsAsync<GameSaveException>(() =>
            new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(ready, 1, 30_000)).RequestAsync(game.Pid, temp.Path, true));
        Assert.Equal("runtime-deferred", error.Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        await Client().RequestAsync(game.Pid, temp.Path, true);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        await AssertIdleAsync(temp);
    }

    [BridgeFact]
    public async Task GuardedBackup_DeferralDoesNotCommit_AndSaveFlushPrecedesInitialAndIncrementalCapture()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("world");
        Directory.CreateDirectory(sourcePath);
        await using var game = await FakeGame.StartAsync(sourcePath, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var options = new BackupOptions(BackupConfiguration.CurrentFormatVersion, temp.GetPath("repo"),
            [new BackupSourceOptions("world", sourcePath)],
            new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false),
            new TelemetryOptions(TelemetryMode.Off, 16, 10, 10, 32))
            { AlwaysIncludePaths = ["calls.txt", "memory-only-state.txt"] };
        long ordinal = 0;
        async Task<long?> BackupAsync(RuntimeSnapshot snapshot)
        {
            var client = new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(snapshot, ++ordinal));
            var service = new OneShotBackupService(new UsnJournalReader(), async (path, token) =>
            {
                try { return new BackupPreparationResult("saved", await client.RequestAsync(game.Pid, path, true, token)); }
                catch (GameSaveException error) when (error.Code == "runtime-deferred")
                { throw new BackupPreparationDeferredException(error.Message); }
            });
            return (await service.RunAsync(options, "world")).Revision;
        }
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        Assert.Equal(1, await BackupAsync(ready));
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "pause-game"), "pause");
        var paused = await watch.WaitAsync(s => s.Pause == GamePause.Paused);
        await Assert.ThrowsAsync<BackupPreparationDeferredException>(() => BackupAsync(paused));
        var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
        var source = await repository.GetSourceAsync("world");
        Assert.Equal(1, (await repository.GetSourceStateAsync(source.SourceId)).CurrentRevision);
        Assert.Equal("1", await File.ReadAllTextAsync(Path.Combine(sourcePath,"memory-only-state.txt")));
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "resume-game"), "resume");
        var resumed = await watch.WaitAsync(s => s.Pause == GamePause.Running && s.EligibilityEpoch >= paused.EligibilityEpoch);
        Assert.Equal(2, await BackupAsync(resumed));
        for (int revision = 1; revision <= 2; revision++)
        {
            var restored = temp.GetPath($"restored-{revision}");
            await new RevisionRestorer().RestoreAsync(repository, source.SourceId, revision, restored);
            Assert.Equal(revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
                await File.ReadAllTextAsync(Path.Combine(restored,"memory-only-state.txt")));
            Assert.Equal(revision, (await File.ReadAllLinesAsync(Path.Combine(restored,"calls.txt"))).Length);
        }
    }
    [BridgeFact]
    public async Task GuardedSave_DoesNotSubmitWhileInitialPermissionIsUnresolvedOrRevoked()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await using var watch = new RuntimeWatchCapture(game.Pid);
        var ready = await watch.WaitAsync(s => s.IsWorldReady && s.Pause == GamePause.Running);
        var checking = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var permission = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var request = new GameSaveClient(RuntimeBridgeDirectory(), runtimeTicket: Ticket(ready, 1),
            preparationAllowed: token => { checking.TrySetResult(); return permission.Task.WaitAsync(token); })
            .RequestAsync(game.Pid, temp.Path, true);
        try
        {
            await checking.Task.WaitAsync(TimeSpan.FromSeconds(15));
            // The live game loop advances, but zero-delay saving must not start without permission.
            await watch.WaitAsync(s => s.ActiveMilliseconds >= ready.ActiveMilliseconds + 1000);
            Assert.False(File.Exists(temp.GetPath("calls.txt")));
        }
        finally { permission.TrySetResult(false); }
        var error = await Assert.ThrowsAsync<GameSaveException>(() => request);
        Assert.Equal("runtime-deferred", error.Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        await Client().RequestAsync(game.Pid, temp.Path, true);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
    }
    private static string RuntimeBridgeDirectory() => Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")
        ?? throw new InvalidOperationException("Synthetic bridge fixture was not prepared.");

    private static RuntimeSaveTicket Ticket(RuntimeSnapshot state, long ordinal, long delay = 0) =>
        new(state.ProcessSession, state.ObserverEpoch, state.WorldSession, state.ClockEpoch, state.EligibilityEpoch,
            state.ActiveMilliseconds + delay, ordinal, Guid.NewGuid().ToString("N"));

    private sealed class RuntimeWatchCapture : IAsyncDisposable
    {
        private readonly CancellationTokenSource cancellation = new();
        private readonly Task worker;
        private RuntimeSnapshot? latest;
        public RuntimeWatchCapture(int pid) => worker = ReceiveAsync(pid);
        private async Task ReceiveAsync(int pid)
        {
            try
            {
                await foreach (var snapshot in new GameRuntimeClient(RuntimeBridgeDirectory()).WatchAsync(pid, cancellation.Token))
                    Volatile.Write(ref latest, snapshot);
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        }
        public async Task<RuntimeSnapshot> WaitAsync(Func<RuntimeSnapshot, bool> predicate)
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            while (true)
            {
                if (worker.IsCompleted) { await worker; throw new InvalidOperationException("Runtime stream ended."); }
                var snapshot = Volatile.Read(ref latest);
                if (snapshot is not null && predicate(snapshot)) return snapshot;
                await Task.Delay(20, deadline.Token);
            }
        }
        public async ValueTask DisposeAsync()
        {
            await cancellation.CancelAsync();
            try { await worker.WaitAsync(TimeSpan.FromSeconds(10)); }
            finally { cancellation.Dispose(); }
        }
    }
}