using PzTools.App.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Tests;

public sealed class RuntimeConfigurationTests
{
    [Theory]
    [InlineData("capture_attempts", "0")]
    [InlineData("capture_retry_delay_ms", "-1")]
    [InlineData("copy_buffer_kib", "999999")]
    [InlineData("scan_batch_size", "0")]
    [InlineData("journal_batch_size", "0")]
    [InlineData("heartbeat_interval_ms", "10000")]
    [InlineData("game_connection_timeout_seconds", "0")]
    [InlineData("game_completion_timeout_seconds", "601")]
    [InlineData("game_queue_timeout_seconds", "61")]
    [InlineData("capture_attempts", "'five'")]
    [InlineData("capture_attempt_typo", "5")]
    public void BackupRuntime_RejectsInvalidValues(string key, string value)
    {
        using var temp = new TempDirectory();
        Assert.Throws<BackupConfigurationException>(() => BackupConfiguration.Parse(
            $"format_version = 1\n[runtime]\n{key} = {value}", temp.GetPath("repo"), temp.GetPath("config.toml"),
            new BackupOptionOverrides { Sources = [new("test", temp.GetPath("source"))] }));
    }

    [Fact]
    public async Task BackupRuntime_RoundTrips_AndTinyBatchesStillCaptureEveryFile()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        foreach (var name in new[] { "one", "two", "three" })
            await File.WriteAllTextAsync(Path.Combine(source, name), name);
        var configuration = BackupConfiguration.Parse("""
            format_version = 1
            [runtime]
            capture_attempts = 2
            capture_retry_delay_ms = 50
            copy_buffer_kib = 16
            progress_interval_ms = 100
            scan_batch_size = 1
            journal_batch_size = 1
            heartbeat_interval_ms = 1000
            game_connection_timeout_seconds = 10
            game_completion_timeout_seconds = 60
            game_queue_timeout_seconds = 2
            """, temp.GetPath("repo"), temp.GetPath("config.toml"),
            new BackupOptionOverrides { Sources = [new("test", source)] });
        var tuning = configuration.EffectiveTuning;
        Assert.Equal(new BackupTuningOptions(2, 50, 16, 100, 1, 1, 1000, 10, 60, 2), tuning);
        Assert.Equal(tuning, BackupConfiguration.Parse(BackupConfiguration.Serialize(configuration),
            configuration.RepositoryPath, temp.GetPath("config.toml")).EffectiveTuning);
        await new OneShotBackupService(new NoJournal()).RunAsync(configuration, "test");
        var repository = await RepositoryDatabase.OpenExistingAsync(configuration.RepositoryPath);
        var saved = await repository.GetSourceAsync("test");
        await new RevisionRestorer().RestoreAsync(repository, saved.SourceId, 1, temp.GetPath("restore"));
        foreach (var name in new[] { "one", "two", "three" })
            Assert.Equal(name, await File.ReadAllTextAsync(temp.GetPath("restore/" + name)));
    }

    [Fact]
    public void AppRuntime_UsesTomlAndRejectsZeroPolling()
    {
        var read = AppRuntimeOptions.Read(ComponentConfiguration.Parse("""
            [runtime]
            projection_interval_ms = 1200
            thumbnail_cache_mib = 128
            scheduler_restart_attempts = 0
            success_card_seconds = 9
            """));
        Assert.Equal(1200, read.ProjectionIntervalMs);
        Assert.Equal(128, read.ThumbnailCacheMib);
        Assert.Equal(0, read.SchedulerRestartAttempts);
        Assert.Equal(9, read.SuccessCardSeconds);
        Assert.Throws<InvalidDataException>(() => AppRuntimeOptions.Read(
            ComponentConfiguration.Parse("[runtime]\nprojection_interval_ms = 0")));
        Assert.Throws<InvalidDataException>(() => AppRuntimeOptions.Read(
            ComponentConfiguration.Parse("runtime = 1")));
    }

    [Fact]
    public async Task InvalidAppRuntime_DoesNotPreventSettingsRepair_ButBlocksWorkerStartup()
    {
        using var temp = new TempDirectory();
        var runtime = temp.GetPath("runtime");
        var config = Path.Combine(runtime, "config", "app", "default.toml");
        Directory.CreateDirectory(Path.GetDirectoryName(config)!);
        await File.WriteAllTextAsync(config, "[logs]\nmax_entries = 100000\n[runtime]\nprojection_interval_ms = 0");
        await using var host = new AppHost(new(runtime, temp.Path, temp.GetPath("state.db"), temp.GetPath("scheduler.db")));
        Assert.NotNull(host.Settings);
        await Assert.ThrowsAsync<InvalidDataException>(() => host.StartAsync());
        Assert.Throws<InvalidDataException>(() => host.Settings.ValidateEditableConfiguration());
    }

    [Fact]
    public async Task FreshTemplates_AreEnglishAndDoNotOverwriteUserValues()
    {
        using var temp = new TempDirectory();
        var settings = new AppSettingsService(temp.GetPath("runtime"));
        foreach (var component in new[] { "app", "backup-worker", "backup-scheduler", "state-scheduler",
                     "maintenance-worker", "archive-worker", "restore-worker", "character-recovery" })
        {
            await settings.EnsureComponentConfigurationAsync(temp.Path, component);
            var path = ComponentRuntimePaths.GetIdentityDefaultPath(temp.Path, component, settings.ConfigurationRoot);
            var text = await File.ReadAllTextAsync(path);
            Assert.DoesNotMatch("[가-힣]", text);
            _ = ComponentConfiguration.Parse(text);
            await File.WriteAllTextAsync(path, text + "\n# User note must survive.\n");
            await settings.EnsureComponentConfigurationAsync(temp.Path, component);
            Assert.EndsWith("# User note must survive.\n", await File.ReadAllTextAsync(path));
        }
    }

    private sealed class NoJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new System.ComponentModel.Win32Exception(50);
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint, long upperUsnExclusive,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
