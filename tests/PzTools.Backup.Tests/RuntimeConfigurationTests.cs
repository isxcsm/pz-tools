using PzTools.App.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Tests;

public sealed class RuntimeConfigurationTests
{
    [Fact]
    public async Task ExtensionControl_DefaultsMatchFreshSchedulerTemplate()
    {
        using var temp = new TempDirectory();
        var settings = new AppSettingsService(temp.GetPath("runtime"));
        await settings.EnsureComponentConfigurationAsync(temp.Path, "state-scheduler");
        var path = ComponentRuntimePaths.GetIdentityDefaultPath(temp.Path, "state-scheduler", settings.ConfigurationRoot);
        var text = await File.ReadAllTextAsync(path);
        Assert.Contains("reconcile_interval_ms = 1000", text);
        Assert.Contains("connect_timeout_seconds = 20", text);
        var template = ComponentConfiguration.Parse(text);
        ComponentOptions.Validate("state-scheduler", template);
        Assert.Equal(new ExtensionControlOptions(), StateSchedulerOptions.Read(template).Extensions);
        Assert.Equal(new ExtensionControlOptions(), StateSchedulerOptions.Read(ComponentConfiguration.Parse("[scheduler]")).Extensions);
    }

    [Theory]
    [InlineData(250, 5)]
    [InlineData(1000, 60)]
    public void ExtensionControl_UsesBoundedSchedulerOptions(int interval, int timeout)
    {
        var configuration = ComponentConfiguration.Parse($"[extensions]\nreconcile_interval_ms = {interval}\nconnect_timeout_seconds = {timeout}");
        ComponentOptions.Validate("state-scheduler", configuration);
        Assert.Equal(new ExtensionControlOptions(interval, timeout), StateSchedulerOptions.Read(configuration).Extensions);
        Assert.Throws<InvalidDataException>(() => ComponentOptions.Validate("backup-scheduler", configuration));
    }

    [Theory]
    [InlineData("[extensions]\nreconcile_interval_ms = 249")]
    [InlineData("[extensions]\nreconcile_interval_ms = 1001")]
    [InlineData("[extensions]\nconnect_timeout_seconds = 4")]
    [InlineData("[extensions]\nconnect_timeout_seconds = 61")]
    [InlineData("[extensions]\nconnect_timeout_seconds = '20'")]
    [InlineData("[extensions]\nreconcile_interval_ms = true")]
    [InlineData("[extensions]\nreconcile_interval_ms = 500.0")]
    [InlineData("[extensions]\nconnect_timeout_typo = 20")]
    [InlineData("extensions = 1")]
    public void ExtensionControl_InvalidOptionsFailComponentPreflight(string text)
    {
        Assert.Throws<InvalidDataException>(() => ComponentOptions.Validate("state-scheduler", ComponentConfiguration.Parse(text)));
    }

    [Fact]
    public async Task BackupRuntime_DefaultsMatchFreshTemplateAndSerialization()
    {
        using var temp = new TempDirectory();
        var settings = new AppSettingsService(temp.GetPath("runtime"));
        await settings.EnsureComponentConfigurationAsync(temp.Path, "backup-worker");
        var path = ComponentRuntimePaths.GetIdentityDefaultPath(temp.Path, "backup-worker", settings.ConfigurationRoot);
        var template = BackupConfiguration.Parse(await File.ReadAllTextAsync(path), temp.GetPath("repo"), path,
            new BackupOptionOverrides { Sources = [new("test", temp.GetPath("source"))] });
        var defaults = new BackupTuningOptions();
        Assert.Equal(defaults, template.EffectiveTuning);
        Assert.Equal(defaults, BackupTuningOptions.Read(ComponentConfiguration.Parse("[runtime]")));
        Assert.Equal(defaults, BackupConfiguration.Parse(BackupConfiguration.Serialize(template),
            template.RepositoryPath, path).EffectiveTuning);
    }

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
    [InlineData("small_file_staging_kib", "-1")]
    [InlineData("small_file_staging_kib", "1025")]
    [InlineData("staging_memory_mib", "0")]
    [InlineData("staging_memory_mib", "257")]
    [InlineData("capture_read_concurrency", "0")]
    [InlineData("capture_read_concurrency", "9")]
    [InlineData("capture_queue_capacity", "0")]
    [InlineData("capture_queue_capacity", "129")]
    [InlineData("full_scan_hash_batch_size", "0")]
    [InlineData("full_scan_hash_batch_size", "129")]
    [InlineData("full_scan_hash_read_concurrency", "0")]
    [InlineData("full_scan_hash_read_concurrency", "9")]
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
    public void BackupRuntime_CaptureAndHashLimitsRoundTrip()
    {
        using var temp = new TempDirectory();
        var options = BackupConfiguration.Parse("""
            format_version = 1
            [runtime]
            small_file_staging_kib = 0
            staging_memory_mib = 1
            capture_read_concurrency = 3
            capture_queue_capacity = 7
            full_scan_hash_batch_size = 3
            full_scan_hash_read_concurrency = 1
            """, temp.GetPath("repo"), temp.GetPath("config.toml"),
            new BackupOptionOverrides { Sources = [new("test", temp.GetPath("source"))] });
        Assert.Equal(new BackupTuningOptions(SmallFileStagingKib: 0, StagingMemoryMib: 1,
            CaptureReadConcurrency: 3, CaptureQueueCapacity: 7,
            FullScanHashBatchSize: 3, FullScanHashReadConcurrency: 1), options.EffectiveTuning);
        Assert.Equal(options.EffectiveTuning, BackupConfiguration.Parse(BackupConfiguration.Serialize(options),
            options.RepositoryPath, temp.GetPath("config.toml")).EffectiveTuning);
    }

    [Theory]
    [InlineData(1, 3)]
    [InlineData(32, 1)]
    public async Task BackupRuntime_CustomHashLimitsWorkDuringUsnFallback(int batchSize, int readers)
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        for (var index = 0; index < 35; index++)
            await File.WriteAllTextAsync(Path.Combine(source, $"file-{index}.bin"), $"content-{index}");
        var options = BackupConfiguration.Parse($"""
            format_version = 1
            [runtime]
            full_scan_hash_batch_size = {batchSize}
            full_scan_hash_read_concurrency = {readers}
            copy_buffer_kib = 16
            """, temp.GetPath("repo"), temp.GetPath("config.toml"),
            new BackupOptionOverrides { Sources = [new("test", source)] });
        var service = new OneShotBackupService(new NoJournal());
        Assert.Equal(1, (await service.RunAsync(options, "test")).Revision);
        var unchanged = await service.RunAsync(options, "test");
        Assert.Equal("FullScan", unchanged.Mode);
        Assert.Null(unchanged.Revision);
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

    // The vehicle extension's tuning sits with the other editable files, and Apply settings checks it by its own rules.
    [Fact]
    public async Task ApplyingSettings_ChecksTheVehicleTuningByItsOwnRules_AndNamesTheFile()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var tuning = PzTools.GameExtensions.VehicleDrivetrainConfiguration.OverridePath(service.RuntimeRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(tuning)!);
        await File.WriteAllTextAsync(tuning, "diagnostics_enabled = true\n");
        service.ValidateEditableConfiguration();

        await File.WriteAllTextAsync(tuning, "area_light_radius = 999\n");
        var failure = Assert.Throws<InvalidDataException>(service.ValidateEditableConfiguration);
        Assert.Equal(Path.Combine("vehicle-drivetrain", "default.toml"),
            UserFacingErrorCatalog.InvalidSettingsFile(failure, service.ConfigurationRoot));
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
        var failure = Assert.Throws<InvalidDataException>(() => host.Settings.ValidateEditableConfiguration());
        // The player is told which file to fix, as the configuration folder shows it.
        Assert.Equal(Path.Combine("app", "default.toml"), UserFacingErrorCatalog.InvalidSettingsFile(failure, host.Settings.ConfigurationRoot));
    }

    [Fact]
    public async Task FreshTemplates_AreEnglishAndDoNotOverwriteUserValues()
    {
        using var temp = new TempDirectory();
        var settings = new AppSettingsService(temp.GetPath("runtime"));
        foreach (var component in new[] { "app", "backup-worker", "backup-scheduler", "state-scheduler",
                     "maintenance-worker", "archive-worker", "restore-worker", "character-recovery", "profiler" })
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
