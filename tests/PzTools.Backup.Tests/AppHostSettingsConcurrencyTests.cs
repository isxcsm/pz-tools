using PzTools.App.Core;
using PzTools.Process.Hosting;
using PzTools.Projections;
using PzTools.Scheduling;

namespace PzTools.Backup.Tests;

public sealed class AppHostSettingsConcurrencyTests
{
    [Fact]
    public async Task SettingsChangedDuringStartup_AreAppliedAfterTheStartupSnapshot()
    {
        await using var fixture = await PausedStartup.CreateAsync();
        await fixture.SnapshotPublished;
        var changed = fixture.InitialSettings with
        {
            AutomaticBackupEnabled = false,
            BackupIntervalMinutes = 17,
            BackupOnDeath = true,
        };

        var apply = fixture.Host.ApplySettingsAsync(changed);
        Assert.False(apply.IsCompleted);
        fixture.Release();
        await Task.WhenAll(fixture.Startup, apply).WaitAsync(TimeSpan.FromSeconds(20));

        var stored = fixture.Host.Settings.Load();
        var visible = fixture.Host.Views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot!;
        var scheduled = await fixture.Host.Scheduler!.ReadBackupStateIfChangedAsync(-1);
        Assert.False(stored.AutomaticBackupEnabled);
        Assert.False(visible.AutomaticBackupEnabled);
        Assert.False(scheduled.AutomaticEnabled);
        Assert.Equal(17, stored.BackupIntervalMinutes);
        Assert.Equal(17, visible.BackupIntervalMinutes);
        Assert.Equal(TimeSpan.FromMinutes(17), scheduled.Interval);
        Assert.True(stored.BackupOnDeath);
        Assert.True(visible.BackupOnDeath);
    }

    [Fact]
    public async Task CancelledSettingsWait_DoesNotWriteAfterStartup()
    {
        await using var fixture = await PausedStartup.CreateAsync();
        await fixture.SnapshotPublished;
        using var cancellation = new CancellationTokenSource();

        var apply = fixture.Host.ApplySettingsAsync(
            fixture.InitialSettings with { AutomaticBackupEnabled = false }, cancellation.Token);
        Assert.False(apply.IsCompleted);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => apply);
        fixture.Release();
        await fixture.Startup.WaitAsync(TimeSpan.FromSeconds(20));

        Assert.True(fixture.Host.Settings.Load().AutomaticBackupEnabled);
        Assert.True(fixture.Host.Views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0)
            .Snapshot!.AutomaticBackupEnabled);
        Assert.True((await fixture.Host.Scheduler!.ReadBackupStateIfChangedAsync(-1)).AutomaticEnabled);
    }

    [Fact]
    public async Task ConcurrentStart_WaitsForInitializationRatherThanReturningEarly()
    {
        await using var fixture = await PausedStartup.CreateAsync();
        await fixture.SnapshotPublished;

        var secondStart = fixture.Host.StartAsync();
        Assert.False(secondStart.IsCompleted);
        fixture.Release();
        await Task.WhenAll(fixture.Startup, secondStart).WaitAsync(TimeSpan.FromSeconds(20));

        Assert.NotNull(fixture.Host.Repository);
        Assert.NotNull(fixture.Host.Operations);
        Assert.Equal(2, fixture.Launcher.Starts);
    }

    [Fact]
    public async Task ShutdownDuringStartup_CancelsPendingSettingsAndDrainsStartup()
    {
        await using var fixture = await PausedStartup.CreateAsync();
        await fixture.SnapshotPublished;
        var apply = fixture.Host.ApplySettingsAsync(
            fixture.InitialSettings with { AutomaticBackupEnabled = false });

        var shutdown = fixture.Host.DisposeAsync().AsTask();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => apply)
            .WaitAsync(TimeSpan.FromSeconds(20));
        Assert.False(shutdown.IsCompleted);
        fixture.Release();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Startup)
            .WaitAsync(TimeSpan.FromSeconds(20));
        await shutdown.WaitAsync(TimeSpan.FromSeconds(20));

        Assert.Equal(0, fixture.Launcher.Starts);
        Assert.True(fixture.Host.Settings.Load().AutomaticBackupEnabled);
    }

    private sealed class PausedStartup : IAsyncDisposable
    {
        private readonly TempDirectory temp;
        private readonly ManualResetEventSlim release = new();
        private readonly TaskCompletionSource snapshotPublished =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly IDisposable subscription;
        private int hasPaused;

        private PausedStartup(TempDirectory temp, AppHost host, AppSettings settings,
            WaitingLauncher launcher)
        {
            this.temp = temp;
            Host = host;
            InitialSettings = settings;
            Launcher = launcher;
            subscription = host.Views.Subscribe((key, _) =>
            {
                if (key != ViewKey.Settings || Interlocked.Exchange(ref hasPaused, 1) != 0) return;
                snapshotPublished.TrySetResult();
                release.Wait();
            });
            Startup = Task.Run(() => host.StartAsync());
        }

        public AppHost Host { get; }
        public AppSettings InitialSettings { get; }
        public WaitingLauncher Launcher { get; }
        public Task Startup { get; }
        public Task SnapshotPublished => snapshotPublished.Task.WaitAsync(TimeSpan.FromSeconds(20));
        public void Release() => release.Set();

        public static async Task<PausedStartup> CreateAsync()
        {
            var temp = new TempDirectory();
            try
            {
                var paths = new AppHostPaths(temp.GetPath("runtime"), temp.GetPath("workers"),
                    temp.GetPath("state.db"), temp.GetPath("scheduler.db"));
                var settings = AppSettings.CreateDefault() with
                {
                    SavesRoot = temp.GetPath("saves"),
                    BackupRoot = temp.GetPath("backups"),
                    AutomaticBackupEnabled = true,
                };
                var scheduler = await SchedulerDatabase.CreateOrOpenAsync(paths.SchedulerDatabasePath);
                await new AppSettingsService(paths.RuntimeRoot).SaveAndApplyAsync(settings, scheduler);
                var launcher = new WaitingLauncher();
                return new PausedStartup(temp, new AppHost(paths, launcher), settings, launcher);
            }
            catch { temp.Dispose(); throw; }
        }

        public async ValueTask DisposeAsync()
        {
            release.Set();
            try
            {
                try { await Startup.WaitAsync(TimeSpan.FromSeconds(20)); }
                catch (OperationCanceledException) { }
            }
            finally
            {
                await Host.DisposeAsync();
                subscription.Dispose();
                release.Dispose();
                temp.Dispose();
            }
        }
    }

    private sealed class WaitingLauncher : IManagedProcessLauncher
    {
        private int starts;
        public int Starts => Volatile.Read(ref starts);

        public async Task<ManagedProcessExit> RunAsync(string executable,
            IReadOnlyList<string> arguments, Action<string>? standardOutput,
            Action<string>? standardError, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref starts);
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return new(true, 0, null);
        }
    }
}
