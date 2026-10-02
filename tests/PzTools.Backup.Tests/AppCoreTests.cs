using System.Collections.ObjectModel;
using System.Collections.Specialized;
using PzTools.App.Core;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Projections;
using PzTools.Scheduling;
using PzTools.Zomboid.Archive;

namespace PzTools.Backup.Tests;

[Collection("AppHost integration")]
public sealed class AppCoreTests
{
    [Fact]
    public void BackupDefaults_UseFiveMinutesAndTwentyRevisions()
    {
        var defaults = AppSettings.CreateDefault();
        Assert.Equal(5, defaults.BackupIntervalMinutes);
        Assert.Equal(20, defaults.RetainedRevisions);

        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        Assert.Equal(5, service.Load().BackupIntervalMinutes);
        Assert.Equal(20, service.Load().RetainedRevisions);

        Directory.CreateDirectory(service.RuntimeRoot);
        File.WriteAllText(service.SettingsPath, "[backup]\nsave_game_before_backup = false\n");
        Assert.Equal(5, service.Load().BackupIntervalMinutes);
        Assert.Equal(20, service.Load().RetainedRevisions);
    }

    [Theory]
    [InlineData(1, 100)]
    [InlineData(17, 23)]
    public void BackupDefaults_PreserveExplicitUserSettings(int interval, int retained)
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        Directory.CreateDirectory(service.RuntimeRoot);
        var document = $"[backup]\ninterval_minutes = {interval}\nretained_revisions = {retained}\n";
        File.WriteAllText(service.SettingsPath, document);

        var loaded = service.Load();
        Assert.Equal(interval, loaded.BackupIntervalMinutes);
        Assert.Equal(retained, loaded.RetainedRevisions);
        Assert.Equal(document, File.ReadAllText(service.SettingsPath));
    }

    [Fact]
    public async Task GameSaveCountdownToggle_PersistsDuringBackupWithoutDisablingSavingOrRescheduling()
    {
        using var temp = new TempDirectory();
        var busy = false;
        var service = new AppSettingsService(temp.GetPath("runtime"), () => busy);
        Assert.True(service.Load().GameSaveCountdown);
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var initial = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups"),
        };
        await service.SaveAndApplyAsync(initial, scheduler);
        var before = await scheduler.ReadBackupStateIfChangedAsync(-1);
        busy = true;
        foreach (var enabled in new[] { false, true, false })
        {
            await service.SaveAndApplyAsync(initial with { GameSaveCountdown = enabled }, scheduler);
            var loaded = new AppSettingsService(service.RuntimeRoot).Load();
            Assert.Equal(enabled, loaded.GameSaveCountdown);
            Assert.True(loaded.SaveGameBeforeBackup);
            Assert.Equal(before, await scheduler.ReadBackupStateIfChangedAsync(-1));
            var effective = PzTools.Backup.Core.Configuration.BackupConfiguration.Load(initial.BackupRoot,
                overrides: new() { Sources = [new("test", initial.SavesRoot)] },
                appSettingsPath: service.SettingsPath, configurationRoot: service.ConfigurationRoot);
            Assert.Equal(enabled, effective.GameSaveCountdown);
            Assert.True(effective.SaveGameBeforeBackup);
            var views = new RevisionedViewStore();
            new SettingsProjector(views).Project(loaded);
            Assert.Equal(enabled, views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot!.GameSaveCountdown);
        }
        await service.SaveLogOptionsAsync(LogLevel.Warning, 1200);
        Assert.False(service.Load().GameSaveCountdown);
    }

    [Fact]
    public async Task LastMinutesAndHotKeys_PersistWithoutRescheduling_AndADuplicateKeyIsRefused()
    {
        using var temp = new TempDirectory();
        var busy = false;
        var service = new AppSettingsService(temp.GetPath("runtime"), () => busy);
        // Off at first, one key: saving the last minutes.
        var defaults = service.Load();
        Assert.Equal((false, false, 2, "Ctrl+Shift+F9", ""), (defaults.RollingEnabled, defaults.RollingDetailed, defaults.RollingMinutes,
            defaults.Keys.SaveLast, defaults.Keys.ManualBackup));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var initial = AppSettings.CreateDefault() with { SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups") };
        await service.SaveAndApplyAsync(initial with { HotKeys = null }, scheduler);
        var before = await scheduler.ReadBackupStateIfChangedAsync(-1);
        // A backup running does not keep these from being saved: they touch no folder the backup uses.
        busy = true;

        var changed = initial with
        {
            RollingEnabled = true, RollingDetailed = true, RollingMinutes = 3,
            HotKeys = new HotKeySettings(SaveLast: "ctrl+f9", RecordMode: "ctrl+shift+f10", ManualBackup: "Ctrl+Alt+B", Status: ""),
        };
        await service.SaveAndApplyAsync(changed, scheduler);
        var loaded = new AppSettingsService(service.RuntimeRoot).Load();
        Assert.Equal((true, true, 3), (loaded.RollingEnabled, loaded.RollingDetailed, loaded.RollingMinutes));
        // Written in one form, read back as written.
        Assert.Equal(new HotKeySettings(SaveLast: "Ctrl+F9", RecordMode: "Ctrl+Shift+F10", ManualBackup: "Ctrl+Alt+B", Status: ""), loaded.Keys);
        Assert.Equal(before, await scheduler.ReadBackupStateIfChangedAsync(-1));
        var views = new RevisionedViewStore();
        new SettingsProjector(views).Project(loaded);
        Assert.Equal(loaded.Keys, views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot!.HotKeys);

        // One combination for two actions is refused when saved, and dropped from a file edited by hand.
        await Assert.ThrowsAsync<ArgumentException>(() => service.SaveAndApplyAsync(
            changed with { HotKeys = new HotKeySettings(SaveLast: "Ctrl+F9", Record: "Ctrl+F9") }, scheduler));
        await File.AppendAllTextAsync(service.SettingsPath, "");
        var text = (await File.ReadAllTextAsync(service.SettingsPath)).Replace("record = \"\"", "record = \"Ctrl+F9\"");
        await File.WriteAllTextAsync(service.SettingsPath, text.Replace("rolling_minutes = 3", "rolling_minutes = 99"));
        var edited = service.Load();
        Assert.Equal(("Ctrl+F9", "", 10), (edited.Keys.SaveLast, edited.Keys.Record, edited.RollingMinutes));
    }

    [Fact]
    public async Task GameSaveToggle_PersistsForWorkersWithoutRewritingDefaultsOrRescheduling()
    {
        using var temp = new TempDirectory();
        var busy = false;
        var service = new AppSettingsService(temp.GetPath("runtime"), () => busy);
        Assert.True(service.Load().SaveGameBeforeBackup);
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var initial = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups"),
        };
        await service.SaveAndApplyAsync(initial, scheduler);
        var before = await scheduler.ReadBackupStateIfChangedAsync(-1);
        var defaults = Directory.EnumerateFiles(service.ConfigurationRoot, "*.toml", SearchOption.AllDirectories)
            .ToDictionary(path => path, File.ReadAllText);
        busy = true;
        foreach (var enabled in new[] { false, true, false })
        {
            var changed = initial with { SaveGameBeforeBackup = enabled };
            await service.SaveAndApplyAsync(changed, scheduler);
            Assert.Equal(changed, new AppSettingsService(service.RuntimeRoot).Load());
            Assert.Equal(before, await scheduler.ReadBackupStateIfChangedAsync(-1));
            foreach (var file in defaults) Assert.Equal(file.Value, File.ReadAllText(file.Key));
            var effective = PzTools.Backup.Core.Configuration.BackupConfiguration.Load(initial.BackupRoot,
                overrides: new() { Sources = [new("test", initial.SavesRoot)] },
                appSettingsPath: service.SettingsPath, configurationRoot: service.ConfigurationRoot);
            Assert.Equal(enabled, effective.SaveGameBeforeBackup);
            var views = new RevisionedViewStore();
            new SettingsProjector(views).Project(changed);
            Assert.Equal(enabled, views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot!.SaveGameBeforeBackup);
        }
        await service.SaveLogOptionsAsync(LogLevel.Warning, 1200);
        Assert.False(service.Load().SaveGameBeforeBackup);
    }

    [Fact]
    public void GameSaveToggle_LoadsTomlDefaultUnlessAppPreferenceExists()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var config = Path.Combine(service.ConfigurationRoot, "backup-worker", "default.toml");
        Directory.CreateDirectory(Path.GetDirectoryName(config)!);
        File.WriteAllText(config, "[capture]\nsave_game_before_backup = false\n");
        Assert.False(service.Load().SaveGameBeforeBackup);
        File.WriteAllText(service.SettingsPath, "[backup]\nsave_game_before_backup = true\n");
        Assert.True(service.Load().SaveGameBeforeBackup);
    }

    [Fact]
    public void LogOptions_DefaultToWarningDisplayAndOneHundredThousandStoredRows()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));

        var defaults = service.Load();
        Assert.Equal(LogLevel.Warning, defaults.LogMinimumLevel);
        Assert.Equal(LogLevel.Information, defaults.LogRecordMinimumLevel);
        Assert.Equal(100000, defaults.LogMaxEntries);
        Assert.Equal(1000, defaults.LogDisplayLimit);
        Assert.Equal(LogLevel.Warning, new LogProjectionOptions().MinimumLevel);
        Assert.Equal(1000, new LogProjectionOptions().DisplayLimit);

        Directory.CreateDirectory(service.RuntimeRoot);
        File.WriteAllText(service.SettingsPath, "[ui]\nlanguage = \"Korean\"\n");
        var partial = service.Load();
        Assert.Equal(LogLevel.Warning, partial.LogMinimumLevel);
        Assert.Equal(100000, partial.LogMaxEntries);
        Assert.Equal(1000, partial.LogDisplayLimit);
    }

    [Fact]
    public void IncrementalListReconciler_InsertsAndMovesWithoutResettingExistingItems()
    {
        var first = new object();
        var second = new object();
        var added = new object();
        var items = new ObservableCollection<object> { first, second };
        var changes = new List<NotifyCollectionChangedAction>();
        items.CollectionChanged += (_, args) => changes.Add(args.Action);

        IncrementalListReconciler.Reconcile(items, [added, second, first]);

        Assert.Equal([added, second, first], items);
        Assert.Contains(NotifyCollectionChangedAction.Add, changes);
        Assert.DoesNotContain(NotifyCollectionChangedAction.Reset, changes);
        changes.Clear();

        IncrementalListReconciler.Reconcile(items, [added, second, first]);
        Assert.Empty(changes);
    }

    [Fact]
    public async Task LogOptions_PersistWithoutChangingBackupSettingsOrSchedulerWhileBusy()
    {
        using var temp = new TempDirectory();
        var busy = false;
        var service = new AppSettingsService(temp.GetPath("runtime"), () => busy);
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var original = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"),
            BackupRoot = temp.GetPath("backups"),
            Theme = AppTheme.Dark,
            Language = SupportedLanguage.English,
            BackupIntervalMinutes = 17,
            RetainedRevisions = 23,
            UseSystemTray = true,
            VerifyStagedCopies = false,
        };
        await service.SaveAndApplyAsync(original, scheduler);
        var before = await scheduler.ReadBackupStateIfChangedAsync(-1);
        var configFiles = Directory.EnumerateFiles(temp.Path, "*.toml", SearchOption.AllDirectories)
            .Where(path => path != service.SettingsPath)
            .ToDictionary(path => path, File.ReadAllText);
        busy = true;

        await service.SaveLogOptionsAsync(LogLevel.Warning, 1200);

        Assert.Equal(original with { LogMinimumLevel = LogLevel.Warning, LogDisplayLimit = 1200 }, service.Load());
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() =>
            service.SaveLogOptionsAsync(LogLevel.Trace, 1200));
        Assert.Equal(before, await scheduler.ReadBackupStateIfChangedAsync(-1));
        foreach (var (path, text) in configFiles) Assert.Equal(text, await File.ReadAllTextAsync(path));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => service.SaveLogOptionsAsync(LogLevel.Error, 99));
        Assert.Equal(1200, service.Load().LogDisplayLimit);

        var logging = await File.ReadAllTextAsync(service.LoggingConfigurationPath);
        await File.WriteAllTextAsync(service.LoggingConfigurationPath,
            logging.Replace("Information", "Warning").Replace("100000", "10000"));
        var advanced = service.Load();
        Assert.Equal(LogLevel.Warning, advanced.LogRecordMinimumLevel);
        Assert.Equal(10000, advanced.LogMaxEntries);
        await service.SaveAndApplyAsync(advanced, scheduler);
        Assert.Equal(advanced, service.Load());
        Assert.Contains("max_entries = 10000",
            await File.ReadAllTextAsync(service.LoggingConfigurationPath));
        Assert.Equal(before, await scheduler.ReadBackupStateIfChangedAsync(-1));
    }

    [Fact]
    public async Task Settings_AreAtomicDurableAndAppliedToOwnedComponents()
    {
        using var temp = new TempDirectory();
        var runtime = temp.GetPath("runtime");
        var stateDb = temp.GetPath("state/state.db");
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var service = new AppSettingsService(runtime);
        var settings = AppSettings.CreateDefault() with
        {
            Language = SupportedLanguage.English,
            Theme = AppTheme.Dark,
            SavesRoot = temp.GetPath("saves"),
            BackupRoot = temp.GetPath("backups"),
            BackupIntervalMinutes = 17,
            AutomaticBackupEnabled = false,
            RetainedRevisions = 42,
            BackupOnDeath = true,
            LogMinimumLevel = LogLevel.Warning,
            LogDisplayLimit = 1200,
            UseSystemTray = true,
            VerifyStagedCopies = false,
        };
        var reactorConfig = PzTools.Process.Contracts.ComponentRuntimePaths
            .GetIdentityDefaultPath(stateDb, "state-reactor", service.ConfigurationRoot);
        var maintenanceConfig = PzTools.Process.Contracts.ComponentRuntimePaths
            .GetIdentityDefaultPath(settings.BackupRoot, "maintenance-worker", service.ConfigurationRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(reactorConfig)!);
        Directory.CreateDirectory(Path.GetDirectoryName(maintenanceConfig)!);
        await File.WriteAllTextAsync(reactorConfig, "[telemetry]\nenabled = false\n");
        await File.WriteAllTextAsync(maintenanceConfig, "[telemetry]\nretain_runs = 7\n");

        await service.SaveAndApplyAsync(settings, scheduler);

        Assert.Equal(settings.Validate(), service.Load());
        var schedulerState = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.False(schedulerState.AutomaticEnabled);
        Assert.Equal("[telemetry]\nenabled = false\n", await File.ReadAllTextAsync(reactorConfig));
        Assert.Equal("[telemetry]\nretain_runs = 7\n", await File.ReadAllTextAsync(maintenanceConfig));
        Assert.True(ComponentConfiguration.Load(stateDb, "state-reactor",
            appSettingsPath: service.SettingsPath,
            configurationRoot: service.ConfigurationRoot)
            .GetBoolean("state", "backup_on_death", false));
        Assert.Equal(42, ComponentConfiguration.Load(settings.BackupRoot, "maintenance-worker",
            appSettingsPath: service.SettingsPath,
            configurationRoot: service.ConfigurationRoot)
            .GetInt32("maintenance", "retain_latest_revisions", 100));
        var backupPath = ComponentRuntimePaths.GetIdentityDefaultPath(
            settings.BackupRoot, "backup-worker", service.ConfigurationRoot);
        var backupConfig = await File.ReadAllTextAsync(backupPath);
        Assert.Contains("players.db", backupConfig);
        Assert.Contains("thumb.png", backupConfig);
        Assert.DoesNotContain("[naming]", backupConfig);
        Assert.Contains("verify_staged_copies = false", backupConfig);
        var effective = PzTools.Backup.Core.Configuration.BackupConfiguration.Parse(
            backupConfig, settings.BackupRoot, backupPath,
            new PzTools.Backup.Core.Configuration.BackupOptionOverrides
            {
                Sources = [new PzTools.Backup.Core.Configuration.BackupSourceOptions(
                    "test", settings.SavesRoot)],
            }, service.SettingsPath);
        Assert.Equal(PzTools.Process.Contracts.SupportedLanguage.English,
            effective.NameLanguage);
        var explicitCli = PzTools.Backup.Core.Configuration.BackupConfiguration.Parse(
            backupConfig, settings.BackupRoot, backupPath,
            new PzTools.Backup.Core.Configuration.BackupOptionOverrides
            {
                Sources = [new PzTools.Backup.Core.Configuration.BackupSourceOptions(
                    "test", settings.SavesRoot)],
                NameLanguage = PzTools.Process.Contracts.SupportedLanguage.Korean,
            }, service.SettingsPath);
        Assert.Equal(PzTools.Process.Contracts.SupportedLanguage.Korean,
            explicitCli.NameLanguage);
        Assert.Empty(Directory.GetFiles(runtime, "*.tmp", SearchOption.TopDirectoryOnly));
        var settingsText = await File.ReadAllTextAsync(service.SettingsPath);
        Assert.Contains("[logs]", settingsText);
        Assert.Contains("minimum_level = \"Warning\"", settingsText);
        Assert.Contains("display_limit = 1200", settingsText);
        Assert.Contains("system_tray = true", settingsText);
        Assert.DoesNotContain("verify_staged_copies", settingsText);
        Assert.Contains("record_minimum_level = \"Information\"",
            await File.ReadAllTextAsync(service.LoggingConfigurationPath));
        Assert.True(new SettingsProjector(new RevisionedViewStore())
            .Project(service.Load()).Snapshot.UseSystemTray);
    }

    [Fact]
    public async Task Settings_ReopenedHostAppliesOwnedConfigurationEvenWhenFileIsUnchanged()
    {
        using var temp = new TempDirectory();
        var runtime = temp.GetPath("runtime");
        var settings = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"),
            BackupRoot = temp.GetPath("backups"),
            BackupIntervalMinutes = 7,
        };
        var original = new AppSettingsService(runtime);
        var firstScheduler = await SchedulerDatabase.CreateOrOpenAsync(
            temp.GetPath("first-scheduler.db"));
        await original.SaveAndApplyAsync(settings, firstScheduler);

        var reopened = new AppSettingsService(runtime);
        var newScheduler = await SchedulerDatabase.CreateOrOpenAsync(
            temp.GetPath("new-scheduler.db"));
        await reopened.SaveAndApplyAsync(settings, newScheduler);

        Assert.True((await newScheduler.ReadBackupStateIfChangedAsync(-1)).AutomaticEnabled);
    }

    [Fact]
    public void Settings_WithoutSystemTrayOption_DefaultsToDisabled()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        Directory.CreateDirectory(service.RuntimeRoot);
        File.WriteAllText(service.SettingsPath, "[ui]\nlanguage = \"Korean\"\ntheme = \"System\"\n");

        Assert.False(service.Load().UseSystemTray);
    }

    [Fact]
    public async Task Settings_AddAlwaysIncludedDefaultsWithoutOverwritingExistingWorkerOptions()
    {
        using var temp = new TempDirectory();
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var settings = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"),
            BackupRoot = temp.GetPath("backups"),
        };
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var configurationPath = ComponentRuntimePaths.GetIdentityDefaultPath(
            settings.BackupRoot, "backup-worker", service.ConfigurationRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(configurationPath)!);
        const string original = "format_version = 1\n\n[storage]\nchecksum = \"none\"\ncompression = \"none\"\ncontent_deduplication = false\n\n[telemetry]\nenabled = false\nmode = \"off\"\nbatch_size = 16\nflush_interval_ms = 100\nretain_runs = 3\nmax_database_mib = 8\n";
        await File.WriteAllTextAsync(configurationPath, original);

        await service.SaveAndApplyAsync(settings, scheduler);

        var contents = await File.ReadAllTextAsync(configurationPath);
        Assert.Equal(original, contents);
        Assert.Contains("checksum = \"none\"", contents);
        Assert.Contains("enabled = false", contents);
        var effective = PzTools.Backup.Core.Configuration.BackupConfiguration.Parse(
            contents, settings.BackupRoot, configurationPath,
            new PzTools.Backup.Core.Configuration.BackupOptionOverrides
            {
                Sources = [new PzTools.Backup.Core.Configuration.BackupSourceOptions(
                    "test", settings.SavesRoot)],
            });
        Assert.Contains("players.db", effective.AlwaysIncludePaths!);
    }

    [Fact]
    public async Task ExistingComponentConfigIsNeverRewrittenOnStartup()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var identity = temp.GetPath("backups");
        var path = ComponentRuntimePaths.GetIdentityDefaultPath(
            identity, "maintenance-worker", service.ConfigurationRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        const string original = "[maintenance]\nretain_latest_revisions = 17\n";
        await File.WriteAllTextAsync(path, original);

        await service.EnsureComponentConfigurationAsync(
            identity, "maintenance-worker");

        Assert.Equal(original, await File.ReadAllTextAsync(path));
        Assert.False(Directory.Exists(Path.Combine(service.RuntimeRoot, "config-backups")));

        await service.EnsureComponentConfigurationAsync(
            identity, "maintenance-worker");
        Assert.Equal(original, await File.ReadAllTextAsync(path));
    }

    [Fact]
    public async Task ChangingAppLanguageDoesNotRewriteEditableToml()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var settings = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"),
            BackupRoot = temp.GetPath("backups"),
        };
        await service.SaveAndApplyAsync(settings, scheduler);
        var path = ComponentRuntimePaths.GetIdentityDefaultPath(
            settings.BackupRoot, "backup-worker", service.ConfigurationRoot);
        var before = await File.ReadAllTextAsync(path);

        await service.SaveAndApplyAsync(settings with { Language = SupportedLanguage.English },
            scheduler);

        Assert.Equal(before, await File.ReadAllTextAsync(path));
        Assert.StartsWith("# ", before);
        Assert.DoesNotMatch("[가-힣]", before);
    }

    [Fact]
    public async Task Settings_RejectPathChangingApplyDuringConflictingOperation()
    {
        using var temp = new TempDirectory();
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var service = new AppSettingsService(temp.GetPath("runtime"), () => true);

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.SaveAndApplyAsync(
            AppSettings.CreateDefault() with
            {
                SavesRoot = temp.GetPath("saves"),
                BackupRoot = temp.GetPath("backups"),
            },
            scheduler));
    }

    [Fact]
    public async Task Settings_CanDisableAutomationDespiteRunningOrStaleProgress()
    {
        using var temp = new TempDirectory();
        var busy = false;
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var service = new AppSettingsService(temp.GetPath("runtime"), () => busy);
        var initial = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups"),
            BackupIntervalMinutes = 1,
        };
        await service.SaveAndApplyAsync(initial, scheduler);
        busy = true;
        await service.SaveAndApplyAsync(initial with { AutomaticBackupEnabled = false }, scheduler);
        Assert.Equal(initial.BackupIntervalMinutes, service.Load().BackupIntervalMinutes);
        Assert.False(service.Load().AutomaticBackupEnabled);
        var disabled = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.False(disabled!.AutomaticEnabled);
        Assert.Equal(SchedulerMode.Paused, disabled.Mode);
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.SaveAndApplyAsync(
            service.Load() with { BackupRoot = temp.GetPath("other-backups") }, scheduler));
    }

    [Theory]
    [InlineData(1, false)]
    [InlineData(1, true)]
    [InlineData(15, true)]
    [InlineData(15, false)]
    public async Task Settings_CanChangeIntervalTogetherWithOtherPreferencesDuringBackup(int minutes, bool automaticEnabled)
    {
        using var temp = new TempDirectory();
        var busy = false;
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var service = new AppSettingsService(temp.GetPath("runtime"), () => busy);
        var initial = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups"),
        };
        await service.SaveAndApplyAsync(initial, scheduler);
        busy = true;
        var changed = initial with
        {
            BackupIntervalMinutes = minutes, AutomaticBackupEnabled = automaticEnabled, Theme = AppTheme.Dark,
            GameSaveCountdown = false, RetainedRevisions = 10, BackupOnDeath = true,
        };
        var before = DateTimeOffset.UtcNow;
        await service.SaveAndApplyAsync(changed, scheduler);
        Assert.Equal(changed, service.Load());
        var state = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.Equal(automaticEnabled, state.AutomaticEnabled);
        Assert.Equal(TimeSpan.FromMinutes(minutes), state.Interval);
        if (automaticEnabled) Assert.True(state.NextDueUtc >= before.AddMinutes(minutes));
        foreach (var unsafeChange in new[]
        {
            changed with { SavesRoot = temp.GetPath("other-saves") },
            changed with { BackupRoot = temp.GetPath("other-backups") },
        })
            await Assert.ThrowsAsync<InvalidOperationException>(() => service.SaveAndApplyAsync(unsafeChange, scheduler));
        Assert.Equal(changed, service.Load());
    }

    [Fact]
    public async Task Settings_ResetRestoresDefaultsAndArchivesEditedToml()
    {
        using var temp = new TempDirectory();
        var runtime = temp.GetPath("runtime");
        var backupRoot = temp.GetPath("backups");
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var service = new AppSettingsService(runtime);
        var settings = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"),
            BackupRoot = backupRoot,
        };

        await service.SaveAndApplyAsync(settings, scheduler);
        var backupConfig = ComponentRuntimePaths.GetIdentityDefaultPath(
            backupRoot, "backup-worker", service.ConfigurationRoot);
        var edited = (await File.ReadAllTextAsync(backupConfig))
            .Replace("verify_staged_copies = true", "verify_staged_copies = false");
        await File.WriteAllTextAsync(backupConfig, edited);
        await File.WriteAllTextAsync(service.LoggingConfigurationPath, "[logs\ninvalid");

        Assert.ThrowsAny<Exception>(service.ValidateEditableConfiguration);

        var archived = await service.ResetEditableConfigurationAsync();

        Assert.True(File.Exists(service.SettingsPath));
        Assert.Contains("verify_staged_copies = true",
            await File.ReadAllTextAsync(backupConfig));
        Assert.Contains("record_minimum_level = \"Information\"",
            await File.ReadAllTextAsync(service.LoggingConfigurationPath));
        Assert.Contains("verify_staged_copies = false",
            await File.ReadAllTextAsync(Path.Combine(archived,
                Path.GetRelativePath(service.ConfigurationRoot, backupConfig))));
        Assert.Equal("[logs\ninvalid", await File.ReadAllTextAsync(Path.Combine(
            archived, "app", "default.toml")));
        service.ValidateEditableConfiguration();
    }

    [Fact]
    public void AppHost_PublishesSettingsAsRevisionedView()
    {
        using var temp = new TempDirectory();
        var host = new AppHost(new AppHostPaths(
            temp.GetPath("runtime"), temp.Path, temp.GetPath("state.db"),
            temp.GetPath("scheduler.db")));
        var settings = AppSettings.CreateDefault() with
        {
            SavesRoot = temp.GetPath("saves"),
            BackupRoot = temp.GetPath("backups"),
            BackupIntervalMinutes = 7,
        };

        host.PublishSettings(settings);

        var view = host.Views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0);
        Assert.True(view.Modified);
        Assert.Equal(7, view.Snapshot!.BackupIntervalMinutes);
        Assert.Equal(Path.GetFullPath(settings.BackupRoot), view.Snapshot.BackupRoot);
    }

    [Fact]
    public void WorkerDirectoryResolver_DoesNotReuseUnrelatedPublication()
    {
        using var temp = new TempDirectory();
        var developmentOutput = temp.GetPath(
            "repository/src/PzTools.App/bin/x64/Debug/net10.0-windows/win-x64");
        var published = temp.GetPath("repository/artifacts/app");
        Directory.CreateDirectory(developmentOutput);
        Directory.CreateDirectory(published);
        foreach (var name in new[]
        {
            "PzTools.Backup.Scheduler.exe",
            "PzTools.State.Scheduler.exe",
            "PzTools.Backup.Runner.exe",
            "PzTools.Maintenance.Runner.exe",
            "PzTools.State.Runner.exe",
            "PzTools.Zomboid.Archive.Cli.exe",
        })
        {
            File.WriteAllText(Path.Combine(published, name), string.Empty);
        }

        Assert.Throws<DirectoryNotFoundException>(() => AppWorkerDirectoryResolver.Resolve(developmentOutput));
        Assert.Throws<DirectoryNotFoundException>(() => AppWorkerDirectoryResolver.Resolve(developmentOutput, published));
    }

    [Fact]
    public void WorkerDirectoryResolver_UsesCompleteBuildBundleAndRejectsMissingWorker()
    {
        using var temp = new TempDirectory();
        var workers = temp.GetPath("workers");
        Directory.CreateDirectory(workers);
        foreach (var name in new[] { "Backup.Scheduler", "State.Scheduler", "Backup.Runner",
                     "Maintenance.Runner", "State.Runner", "Zomboid.Archive.Cli", "Backup.Cli",
                     "Maintenance.Cli", "State.Collector.Cli", "State.Reactor.Cli", "Zomboid.Recovery.Cli", "Profiler.Cli" })
            File.WriteAllText(Path.Combine(workers, $"PzTools.{name}.exe"), "");
        Assert.Equal(workers, AppWorkerDirectoryResolver.Resolve(temp.Path));
        Assert.Equal(workers, AppWorkerDirectoryResolver.Resolve(temp.Path, workers));
        Assert.Equal(workers, AppWorkerDirectoryResolver.Resolve(workers));
        File.Delete(Path.Combine(workers, "PzTools.Backup.Cli.exe"));
        Assert.Throws<DirectoryNotFoundException>(() => AppWorkerDirectoryResolver.Resolve(temp.Path));
    }

    [Fact]
    public async Task ManualBackup_UsesValidatedChildEnvelopeOutcome()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        var launcher = new EnvelopeLauncher("backup-runner", ProcessOutcome.NoChange);
        var telemetry = BackupTelemetry(repository);
        var coordinator = new OperationCoordinator(
            repository, temp.Path, telemetry, launcher,
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));

        var result = await coordinator.BackupAsync("Sandbox/Save", source);

        Assert.Equal(ProcessOutcome.NoChange, result.Outcome);
        Assert.Contains("--save-game", launcher.LastArguments);
        Assert.Equal(ProcessExitCodes.Success, result.ExitCode);
    }

    [Fact]
    public async Task ManualBackup_RejectsMismatchedChildEnvelope()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        var telemetry = BackupTelemetry(repository);
        var coordinator = new OperationCoordinator(
            repository, temp.Path, telemetry,
            new EnvelopeLauncher("wrong-component", ProcessOutcome.Succeeded),
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));

        var result = await coordinator.BackupAsync("Sandbox/Save", source);

        Assert.Equal(ProcessOutcome.Failed, result.Outcome);
        Assert.Equal("process-contract-mismatch", result.Error);
    }

    [Fact]
    public async Task ManualBackup_LaunchFailureIsRecordedWithoutWorkerTelemetry()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var coordinator = new OperationCoordinator(repository, temp.Path, BackupTelemetry(repository),
            new NotStartedLauncher(), new RunIndexAllocator(temp.GetPath("control.db")),
            temp.GetPath("operations"), diagnostics: inbox);
        var result = await coordinator.BackupAsync("Sandbox/Save", temp.GetPath("source"));
        Assert.Equal(ProcessOutcome.Failed, result.Outcome);
        var log = Assert.Single((await inbox.ReadPageAsync(new(LogLevel.Warning, "Backup", "", 0))).Entries);
        Assert.Equal(result.RunIndex, log.RunIndex);
        Assert.Equal("launch-failed", LogDiagnostics.Parse(log.PayloadJson)?.FailureCode);
    }

    [Fact]
    public async Task LiveExport_UsesSourceCommandWithoutBackupRevision()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var launcher = new EnvelopeLauncher("archive-worker", ProcessOutcome.Succeeded);
        var coordinator = new OperationCoordinator(repository, temp.Path, BackupTelemetry(repository), launcher,
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));
        var source = temp.GetPath("source");
        var output = temp.GetPath("current.zip");

        var result = await coordinator.ExportLiveArchiveAsync(source, "Sandbox/Current", output);

        Assert.Equal(ProcessOutcome.Succeeded, result.Outcome);
        Assert.Equal("export-live", launcher.LastArguments[0]);
        Assert.Contains(source, launcher.LastArguments);
        Assert.Contains("Sandbox/Current", launcher.LastArguments);
        Assert.Contains(output, launcher.LastArguments);
        Assert.DoesNotContain("--repository", launcher.LastArguments);
        Assert.DoesNotContain("--revision", launcher.LastArguments);
    }

    [Fact]
    public async Task ImmediateRefresh_UsesStateRunnerAndValidatesEnvelope()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var launcher = new EnvelopeLauncher("state-runner", ProcessOutcome.Succeeded);
        var coordinator = new OperationCoordinator(repository, temp.Path, BackupTelemetry(repository), launcher,
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));
        await coordinator.RefreshStateAsync(temp.GetPath("state.db"), temp.GetPath("Saves"));
        Assert.Contains("--state-db", launcher.LastArguments);
        Assert.Contains(temp.GetPath("state.db"), launcher.LastArguments);
        Assert.Contains(temp.GetPath("Saves"), launcher.LastArguments);
        Assert.DoesNotContain("--interval-seconds", launcher.LastArguments);
        var invalid = new OperationCoordinator(repository, temp.Path, BackupTelemetry(repository),
            new EnvelopeLauncher("wrong-component", ProcessOutcome.Succeeded),
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));
        await Assert.ThrowsAsync<IOException>(() => invalid.RefreshStateAsync(temp.GetPath("state.db"), temp.GetPath("Saves")));
    }

    [Theory]
    [InlineData(ProcessOutcome.Succeeded, OperationStatus.Succeeded)]
    [InlineData(ProcessOutcome.Failed, OperationStatus.Failed)]
    public async Task Restore_UsesImportedSaveKeyWithIndependentRevisionNumbers(
        ProcessOutcome outcome, OperationStatus expectedStatus)
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var originalPath = temp.GetPath("Saves", "Sandbox", "Save");
        var importedPath = temp.GetPath("Saves", "Sandbox", "Save(1)");
        Directory.CreateDirectory(originalPath);
        Directory.CreateDirectory(importedPath);
        await File.WriteAllTextAsync(Path.Combine(originalPath, "keep.txt"), "original unchanged");
        await File.WriteAllTextAsync(Path.Combine(importedPath, "current.txt"), "before restore");
        long importedId;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var original = await repository.AddOrGetSourceAsync(lease, "Sandbox/Save", originalPath);
            var imported = await repository.AddOrGetSourceAsync(lease, "Sandbox/Save(1)", importedPath);
            importedId = imported.SourceId;
            Assert.NotEqual(original.SourceId, importedId);
            foreach (var (sourceId, directory) in new[]
            {
                (original.SourceId, "original-revision-1"),
                (original.SourceId, "original-revision-2"),
                (importedId, "imported-revision-1"),
            })
            {
                var run = await repository.StartRunAsync(lease, sourceId);
                await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(run.RunIndex, sourceId, null, [], [],
                    [new EntryVersionRegistration(directory, PzTools.Backup.Core.CatalogEntryKind.Directory, false, 0,
                        DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch,
                        FileAttributes.Directory, null, null, null)]));
            }
        }
        var telemetry = BackupTelemetry(repository);
        var launcher = new EnvelopeLauncher("restore-worker", outcome);
        var coordinator = new OperationCoordinator(repository, temp.Path, telemetry, launcher,
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));

        var result = await coordinator.RestoreAsync(importedId, 1, importedPath);

        Assert.Equal(outcome, result.Outcome);
        var arguments = launcher.LastArguments.ToList();
        Assert.Equal("restore", arguments[0]);
        Assert.Equal("Sandbox/Save(1)", arguments[arguments.IndexOf("--source-id") + 1]);
        Assert.Equal("1", arguments[arguments.IndexOf("--revision") + 1]);
        Assert.Equal(importedPath, arguments[arguments.IndexOf("--target") + 1]);
        var workflow = Assert.Single(telemetry.Snapshot(), entry => entry.Component == "restore-worker").CurrentWorkflow!;
        Assert.Equal(expectedStatus, workflow.Status);
        Assert.NotNull(workflow.CompletedUtc);

        if (outcome == ProcessOutcome.Succeeded)
        {
            // 실제 CLI와 동일한 키 조회를 거쳐 선택한 세이브만 교체합니다.
            var cliSource = await repository.GetSourceAsync(arguments[arguments.IndexOf("--source-id") + 1]);
            Assert.Equal(importedId, cliSource.SourceId);
            await new PzTools.Backup.Engine.SafeRevisionRestoreService().RestoreReplacingAsync(
                repository, cliSource.SourceId, 1, importedPath);
            Assert.True(Directory.Exists(Path.Combine(importedPath, "imported-revision-1")));
            Assert.False(File.Exists(Path.Combine(importedPath, "current.txt")));
            Assert.False(Directory.Exists(Path.Combine(importedPath, "original-revision-1")));
            Assert.False(Directory.Exists(Path.Combine(importedPath, "original-revision-2")));
        }
        Assert.Equal("original unchanged", await File.ReadAllTextAsync(Path.Combine(originalPath, "keep.txt")));
    }

    [Fact]
    public async Task Restore_MissingSourceEndsWorkflowBeforeLaunchingWorker()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var telemetry = BackupTelemetry(repository);
        var launcher = new EnvelopeLauncher("restore-worker", ProcessOutcome.Succeeded);
        var coordinator = new OperationCoordinator(repository, temp.Path, telemetry, launcher,
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));

        await Assert.ThrowsAsync<KeyNotFoundException>(() => coordinator.RestoreAsync(2, 1, temp.GetPath("target")));

        Assert.Empty(launcher.LastArguments);
        var workflow = Assert.Single(telemetry.Snapshot(), entry => entry.Component == "restore-worker").CurrentWorkflow!;
        Assert.Equal(OperationStatus.Failed, workflow.Status);
        Assert.NotNull(workflow.CompletedUtc);
    }

    [Fact]
    public async Task DeleteRevision_AllowsLatestAndRemovesAllUserRevisions()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            sourceId = (await repository.AddOrGetSourceAsync(lease, "Sandbox/Save", temp.GetPath("Saves/Sandbox/Save"))).SourceId;
            for (var revision = 1; revision <= 2; revision++)
            {
                var run = await repository.StartRunAsync(lease, sourceId);
                await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(run.RunIndex, sourceId, null, [], [],
                    [new EntryVersionRegistration("directory", PzTools.Backup.Core.CatalogEntryKind.Directory, false, 0,
                        DateTimeOffset.UnixEpoch.AddSeconds(revision), DateTimeOffset.UnixEpoch,
                        FileAttributes.Directory, null, null, null)]));
            }
        }
        var coordinator = new OperationCoordinator(repository, temp.Path, BackupTelemetry(repository),
            new EnvelopeLauncher("unused", ProcessOutcome.Succeeded),
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));
        await coordinator.DeleteRevisionAsync(sourceId, 1);
        Assert.False(coordinator.IsDeletionRunning);
        Assert.Equal(1, await repository.CountDeletedRevisionsAsync(sourceId));
        await Assert.ThrowsAsync<KeyNotFoundException>(() => repository.ReadRevisionEntriesAsync(sourceId, 1));
        await coordinator.DeleteRevisionAsync(sourceId, 2);
        Assert.False(coordinator.IsDeletionRunning);
        await Assert.ThrowsAsync<KeyNotFoundException>(() => repository.ReadRevisionEntriesAsync(sourceId, 2));
        Assert.Equal(2, await repository.CountDeletedRevisionsAsync(sourceId));
        Assert.Equal(2, (await repository.GetSourceStateAsync(sourceId)).CurrentRevision);
        Assert.Empty(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.DeleteRevisionAsync(sourceId, 2));
        Assert.False(coordinator.IsDeletionRunning);
    }

    [Fact]
    public async Task DeleteAllRevisions_LeavesCurrentSaveAndOtherSourcesUntouched()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var savePath = temp.GetPath("Saves/Sandbox/Save");
        Directory.CreateDirectory(savePath);
        var saveFile = Path.Combine(savePath, "players.db");
        await File.WriteAllTextAsync(saveFile, "current save");
        long sourceId;
        long otherId;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            sourceId = await RegisterDeletionTestSourceAsync(repository, lease, "Sandbox/Save", savePath);
            otherId = await RegisterDeletionTestSourceAsync(repository, lease, "Sandbox/Other",
                temp.GetPath("Saves/Sandbox/Other"));
        }
        var coordinator = new OperationCoordinator(repository, temp.Path, BackupTelemetry(repository),
            new EnvelopeLauncher("unused", ProcessOutcome.Succeeded),
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.DeleteAllRevisionsAsync(sourceId, "Sandbox/Other"));
        Assert.Equal(0, await repository.CountDeletedRevisionsAsync(sourceId));

        Assert.Equal(2, await coordinator.DeleteAllRevisionsAsync(sourceId, "Sandbox/Save"));

        Assert.False(coordinator.IsDeletionRunning);
        Assert.Equal("current save", await File.ReadAllTextAsync(saveFile));
        Assert.Equal(2, await repository.CountDeletedRevisionsAsync(sourceId));
        Assert.Equal(0, await repository.CountDeletedRevisionsAsync(otherId));
        Assert.Equal(2, (await repository.GetSourceStateAsync(sourceId)).CurrentRevision);
        var catalog = await repository.ReadCatalogIfChangedAsync(-1);
        Assert.Empty(Assert.Single(catalog.Sources, item => item.SourceId == sourceId).Revisions);
        Assert.Equal(2, Assert.Single(catalog.Sources, item => item.SourceId == otherId).Revisions.Count);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            coordinator.DeleteAllRevisionsAsync(sourceId, "Sandbox/Save"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task DeleteSave_DeletesSelectedFolderAndAllItsBackupsOnly(bool hasBackups)
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var root = temp.GetPath("Saves");
        var originalPath = Path.Combine(root, "Sandbox", "Save");
        var selectedPath = Path.Combine(root, "Sandbox", "Save(1)");
        foreach (var path in new[] { originalPath, selectedPath })
        {
            Directory.CreateDirectory(path);
            await File.WriteAllTextAsync(Path.Combine(path, "players.db"), "test player");
        }
        long originalId;
        long? selectedId = null;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            originalId = await RegisterDeletionTestSourceAsync(repository, lease, "Sandbox/Save", originalPath);
            if (hasBackups)
            {
                selectedId = await RegisterDeletionTestSourceAsync(repository, lease, "Sandbox/Save(1)", selectedPath);
                await repository.MarkRevisionDeletedAsync(lease, selectedId.Value, 1);
            }
        }
        var coordinator = new OperationCoordinator(repository, temp.Path, BackupTelemetry(repository),
            new EnvelopeLauncher("unused", ProcessOutcome.Succeeded),
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));

        var progress = new DeletionProgressRecorder(selectedPath);
        await coordinator.DeleteSaveAsync(root, "Sandbox/Save(1)", progress: progress);
        Assert.Equal(new[] { SaveDeletionPhase.Discovering, SaveDeletionPhase.Validating,
            SaveDeletionPhase.DeletingFiles, SaveDeletionPhase.DeletingBackups }, progress.Phases.Distinct());

        Assert.False(Directory.Exists(selectedPath));
        Assert.Equal("test player", await File.ReadAllTextAsync(Path.Combine(originalPath, "players.db")));
        Assert.False(coordinator.IsDeletionRunning);
        Assert.Equal(0, await repository.CountDeletedRevisionsAsync(originalId));
        var catalog = await repository.ReadCatalogIfChangedAsync(-1);
        Assert.Equal(2, Assert.Single(catalog.Sources, source => source.SourceId == originalId).Revisions.Count);
        if (selectedId is long id)
        {
            Assert.Equal(2, await repository.CountDeletedRevisionsAsync(id));
            Assert.Empty(Assert.Single(catalog.Sources, source => source.SourceId == id).Revisions);
            await Assert.ThrowsAsync<KeyNotFoundException>(() => repository.ReadRevisionEntriesAsync(id, 2));
            Assert.Equal(2, (await repository.GetSourceStateAsync(id)).CurrentRevision);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DeleteSave_FailureKeepsBackupRevisions(bool mismatchedSourcePath)
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var root = temp.GetPath("Saves");
        var selectedPath = Path.Combine(root, "Sandbox", "Save");
        Directory.CreateDirectory(selectedPath);
        var players = Path.Combine(selectedPath, "players.db");
        await File.WriteAllTextAsync(players, "test player");
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
            sourceId = await RegisterDeletionTestSourceAsync(repository, lease, "Sandbox/Save",
                mismatchedSourcePath ? temp.GetPath("OtherSaves", "Sandbox", "Save") : selectedPath);
        var before = await repository.ReadCatalogIfChangedAsync(-1);
        var coordinator = new OperationCoordinator(repository, temp.Path, BackupTelemetry(repository),
            new EnvelopeLauncher("unused", ProcessOutcome.Succeeded),
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));

        using (var locked = new FileStream(players, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
        {
            if (mismatchedSourcePath)
                await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.DeleteSaveAsync(root, "Sandbox/Save"));
            else
                await Assert.ThrowsAsync<IOException>(() => coordinator.DeleteSaveAsync(root, "Sandbox/Save"));
        }

        Assert.Equal("test player", await File.ReadAllTextAsync(players));
        Assert.False(coordinator.IsDeletionRunning);
        Assert.Equal(0, await repository.CountDeletedRevisionsAsync(sourceId));
        var after = await repository.ReadCatalogIfChangedAsync(-1);
        Assert.Equal(before.RepositoryChangeRevision, after.RepositoryChangeRevision);
        Assert.Equal(2, Assert.Single(after.Sources).Revisions.Count);
    }

    private sealed class DeletionProgressRecorder(string savePath) : IProgress<SaveDeletionProgress>
    {
        public List<SaveDeletionPhase> Phases { get; } = [];
        public void Report(SaveDeletionProgress value)
        {
            if (value.Phase == SaveDeletionPhase.DeletingBackups) Assert.False(Directory.Exists(savePath));
            if (value.Phase is SaveDeletionPhase.Discovering or SaveDeletionPhase.Validating)
                Assert.True(Directory.Exists(savePath));
            Phases.Add(value.Phase);
        }
    }

    private static async Task<long> RegisterDeletionTestSourceAsync(
        RepositoryDatabase repository, RepositoryWriterLease lease, string key, string path)
    {
        var source = await repository.AddOrGetSourceAsync(lease, key, path);
        for (var revision = 1; revision <= 2; revision++)
        {
            var run = await repository.StartRunAsync(lease, source.SourceId);
            await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(run.RunIndex, source.SourceId, null, [], [],
                [new EntryVersionRegistration("directory", PzTools.Backup.Core.CatalogEntryKind.Directory, false, 0,
                    DateTimeOffset.UnixEpoch.AddSeconds(revision), DateTimeOffset.UnixEpoch,
                    FileAttributes.Directory, null, null, null)]));
        }
        return source.SourceId;
    }

    [Fact]
    public async Task AppHost_StartsDespiteCorruptRestoreJournal_AndCleansOtherStaging()
    {
        using var temp = new TempDirectory();
        var paths = await PrepareHostPathsAsync(temp);
        var mode = temp.GetPath("saves/Sandbox");
        Directory.CreateDirectory(Path.Combine(mode, "Good"));
        var staging = Path.Combine(mode, $".Good.pztools-staging-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        var damaged = Path.Combine(mode, ".Bad.pztools-restore.json");
        await File.WriteAllTextAsync(damaged, "{\"Version\":99}");
        var launcher = new WaitingLauncher();
        await using var host = new AppHost(paths, launcher);
        await host.StartAsync();
        Assert.Equal(2, launcher.Executables.Count);
        foreach (var component in new[] { "backup-runner", "maintenance-runner" })
            Assert.True(Assert.Single(host.TelemetrySources.Snapshot(), source => source.Component == component).LogsOnly);
        Assert.False(Directory.Exists(staging));
        Assert.True(File.Exists(damaged));
    }

    [Fact]
    public async Task AppHost_RearmsPersistedPeriodicScheduleOnlyOncePerSession()
    {
        using var temp = new TempDirectory();
        var paths = await PrepareHostPathsAsync(temp);
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(paths.SchedulerDatabasePath);
        var settings = new AppSettingsService(paths.RuntimeRoot).Load() with
        { BackupIntervalMinutes = 1, PausePeriodicDuringGame = false };
        await new AppSettingsService(paths.RuntimeRoot).SaveAndApplyAsync(settings, scheduler);
        var target = new BackupTarget("A", "Sandbox/A", temp.GetPath("saves/Sandbox/A"));
        await scheduler.EnqueueTargetCommandAsync(new("activate", BackupTargetCommandKind.ActivateTarget, target));
        Assert.Null(await scheduler.PrepareBackupTickAsync(DateTimeOffset.UtcNow.AddHours(-1)));
        var previous = await scheduler.ReadBackupStateIfChangedAsync(-1);
        var launcher = new WaitingLauncher();
        await using var host = new AppHost(paths, launcher);
        var startedAt = DateTimeOffset.UtcNow;
        await host.StartAsync();
        var state = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.Equal(previous.Generation + 1, state.Generation);
        Assert.InRange(state.NextDueUtc, startedAt.AddMinutes(1), DateTimeOffset.UtcNow.AddMinutes(1));
        Assert.Null(await scheduler.PrepareBackupTickAsync(startedAt, preparationLead: TimeSpan.FromSeconds(8)));
        Assert.Equal(2, launcher.Executables.Count);

        await host.StartAsync();
        Assert.Equal(state, await scheduler.ReadBackupStateIfChangedAsync(-1));
    }

    [Fact]
    public async Task AppHost_StartsBothSchedulersAndStopsThemWithItsLifetime()
    {
        using var temp = new TempDirectory();
        var paths = await PrepareHostPathsAsync(temp);
        var launcher = new WaitingLauncher();
        var host = new AppHost(paths, launcher);

        await host.StartAsync();

        Assert.Equal(14, Directory.GetFiles(host.Settings.ConfigurationRoot,
            "default.toml", SearchOption.AllDirectories).Length);
        var backupConfig = await File.ReadAllTextAsync(
            ComponentRuntimePaths.GetIdentityDefaultPath(
                temp.GetPath("backups"), "backup-worker", host.Settings.ConfigurationRoot));
        Assert.Contains("verify_staged_copies", backupConfig);
        Assert.StartsWith("# ", backupConfig);
        Assert.DoesNotMatch("[가-힣]", backupConfig);
        Assert.Contains("mode = \"phase\"", backupConfig);
        var maintenanceConfig = await File.ReadAllTextAsync(
            ComponentRuntimePaths.GetIdentityDefaultPath(
                temp.GetPath("backups"), "maintenance-worker", host.Settings.ConfigurationRoot));
        // Unused pack space is reclaimed by default; the old merge-everything switch is gone.
        Assert.Contains("pack_reclamation_enabled = true", maintenanceConfig);
        Assert.DoesNotContain("enable_pack_compaction", maintenanceConfig);
        Assert.DoesNotContain("retain_latest_revisions", maintenanceConfig);

        Assert.False(Directory.Exists(temp.GetPath("saves")));
        Assert.Equal(2, launcher.Executables.Count);
        Assert.Contains(launcher.Executables, path => path.EndsWith(
            "PzTools.Backup.Scheduler.exe", StringComparison.OrdinalIgnoreCase));
        Assert.Contains(launcher.Executables, path => path.EndsWith(
            "PzTools.State.Scheduler.exe", StringComparison.OrdinalIgnoreCase));
        var status = host.Views.ReadIfChanged<SchedulerHostView>(
            AppHost.SchedulerHostsViewKey, 0).Snapshot!;
        Assert.All(status.Schedulers, item => Assert.Equal(
            SchedulerHostState.Running, item.State));

        await host.DisposeAsync();

        Assert.Equal(2, launcher.Cancelled);
    }

    [Fact]
    public async Task AppHost_ShutdownStopsProjectionsBeforeSchedulersFinishAndIsIdempotent()
    {
        using var temp = new TempDirectory();
        var paths = await PrepareHostPathsAsync(temp);
        var releaseSchedulers = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var projectionEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var projectionCancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var projections = new ProjectionHost();
        projections.AddLoop("shutdown-test", async token =>
        {
            projectionEntered.TrySetResult();
            try { await Task.Delay(Timeout.InfiniteTimeSpan, token); }
            finally { projectionCancelled.TrySetResult(); }
        }, TimeSpan.FromSeconds(1));
        var launcher = new WaitingLauncher(releaseSchedulers.Task);
        var host = new AppHost(paths, launcher, projections: projections);
        try
        {
            await host.StartAsync();
            await projectionEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var first = host.DisposeAsync().AsTask();
            Assert.Same(first, host.DisposeAsync().AsTask());
            await projectionCancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(first.IsCompleted);
            releaseSchedulers.TrySetResult();
            await first.WaitAsync(TimeSpan.FromSeconds(5));
            await host.DisposeAsync();
            Assert.Equal(2, launcher.Cancelled);
            Assert.All(projections.Statuses, item => Assert.Equal(ProjectorHealth.Stopped, item.Health));
        }
        finally
        {
            releaseSchedulers.TrySetResult();
            await host.DisposeAsync();
        }
    }

    [Fact]
    public async Task AppHost_BoundsSchedulerRestartAndPublishesFaulted()
    {
        using var temp = new TempDirectory();
        var paths = await PrepareHostPathsAsync(temp);
        var launcher = new FailingLauncher();
        var host = new AppHost(
            paths,
            launcher,
            restartDelay: _ => TimeSpan.Zero);

        await host.StartAsync();

        var status = host.Views.ReadIfChanged<SchedulerHostView>(
            AppHost.SchedulerHostsViewKey, 0).Snapshot!;
        Assert.Equal(2, status.Schedulers.Count);
        Assert.All(status.Schedulers, item =>
        {
            Assert.Equal(SchedulerHostState.Faulted, item.State);
            Assert.Equal(3, item.RestartCount);
        });
        Assert.Equal(8, launcher.Attempts);
        await host.DisposeAsync();
    }

    [Fact]
    public async Task AppHost_KeepsRetryingFaultedSchedulersUntilTheyRunAgain()
    {
        using var temp = new TempDirectory();
        var paths = await PrepareHostPathsAsync(temp);
        var launcher = new RecoveringLauncher(failuresPerExecutable: 6); // More than the restart bound.
        var host = new AppHost(paths, launcher, restartDelay: _ => TimeSpan.Zero,
            schedulerRecovery: TimeSpan.FromMilliseconds(20));
        try
        {
            await host.StartAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            // Both were reported Faulted on the way; only a later successful launch makes them Running.
            while (launcher.Running < 2 || host.Views.ReadIfChanged<SchedulerHostView>(AppHost.SchedulerHostsViewKey, 0)
                       .Snapshot!.Schedulers.Any(item => item.State != SchedulerHostState.Running))
                await Task.Delay(20, timeout.Token);
        }
        finally { await host.DisposeAsync(); }
    }

    [Fact]
    public async Task AppHost_BoundsThrownLauncherFailuresAndPublishesFaulted()
    {
        using var temp = new TempDirectory();
        var paths = await PrepareHostPathsAsync(temp);
        var launcher = new ThrowingLauncher();
        var host = new AppHost(
            paths,
            launcher,
            restartDelay: _ => TimeSpan.Zero);

        await host.StartAsync();

        var status = host.Views.ReadIfChanged<SchedulerHostView>(
            AppHost.SchedulerHostsViewKey, 0).Snapshot!;
        Assert.Equal(2, status.Schedulers.Count);
        Assert.All(status.Schedulers, item =>
        {
            Assert.Equal(SchedulerHostState.Faulted, item.State);
            Assert.Equal(3, item.RestartCount);
            Assert.Equal("launcher-IOException", item.Message);
        });
        Assert.Equal(8, launcher.Attempts);
        await host.DisposeAsync();
    }

    [Fact]
    public async Task ArchiveInspect_UsesValidatedCliEnvelopeResult()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var archivePath = temp.GetPath("save.zip");
        await File.WriteAllBytesAsync(archivePath, [1]);
        var expected = new ArchiveInspection(
            new ZomboidArchiveManifest(
                ZomboidArchiveService.FormatMarker,
                ZomboidArchiveService.CurrentVersion,
                "Sandbox/Save",
                "Sandbox",
                "Save",
                DateTimeOffset.UtcNow,
                1,
                2,
                DateTimeOffset.UtcNow),
            [1, 2, 3],
            123);
        var coordinator = new OperationCoordinator(
            repository,
            temp.Path,
            new TelemetrySourceCatalog(),
            new InspectEnvelopeLauncher(expected),
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"));

        var actual = await coordinator.InspectArchiveAsync(archivePath);

        Assert.Equal(expected.Manifest.SaveId, actual.Manifest.SaveId);
        Assert.Equal(expected.Thumbnail, actual.Thumbnail);
        Assert.Equal(expected.ArchiveBytes, actual.ArchiveBytes);
    }

    private static async Task<AppHostPaths> PrepareHostPathsAsync(TempDirectory temp)
    {
        var runtime = temp.GetPath("runtime");
        var statePath = temp.GetPath("state/state.db");
        var schedulerPath = temp.GetPath("scheduler/scheduler.db");
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(schedulerPath);
        await new AppSettingsService(runtime).SaveAndApplyAsync(
            AppSettings.CreateDefault() with
            {
                SavesRoot = temp.GetPath("saves"),
                BackupRoot = temp.GetPath("backups"),
            },
            scheduler);
        return new AppHostPaths(runtime, temp.Path, statePath, schedulerPath);
    }

    private static TelemetrySourceCatalog BackupTelemetry(RepositoryDatabase repository)
    {
        var catalog = new TelemetrySourceCatalog();
        catalog.Register(new TelemetrySourceRegistration(
            "backup-worker", "backup-worker", repository.RepositoryPath,
            Path.Combine(repository.RepositoryPath, "telemetry.db"),
            TelemetryDatabaseKind.Backup, true));
        return catalog;
    }

    private sealed class EnvelopeLauncher(
        string component,
        ProcessOutcome outcome) : IManagedProcessLauncher
    {
        public IReadOnlyList<string> LastArguments { get; private set; } = [];
        public Task<ManagedProcessExit> RunAsync(
            string executable,
            IReadOnlyList<string> arguments,
            Action<string>? standardOutput,
            Action<string>? standardError,
            CancellationToken cancellationToken)
        {
            LastArguments = arguments.ToArray();
            var index = arguments.ToList().IndexOf("--run-index");
            var runIndex = long.Parse(arguments[index + 1],
                System.Globalization.CultureInfo.InvariantCulture);
            standardOutput?.Invoke(ProcessResultJson.Serialize(
                ProcessResultEnvelope<object>.Success(
                    component, runIndex, outcome, DateTimeOffset.UtcNow)));
            return Task.FromResult(new ManagedProcessExit(
                true, ProcessExitCodes.FromOutcome(outcome), null));
        }
    }

    private sealed class WaitingLauncher(Task? shutdownRelease = null) : IManagedProcessLauncher
    {
        private readonly object gate = new();
        private int cancelled;
        public List<string> Executables { get; } = [];
        public int Cancelled => Volatile.Read(ref cancelled);

        public async Task<ManagedProcessExit> RunAsync(
            string executable,
            IReadOnlyList<string> arguments,
            Action<string>? standardOutput,
            Action<string>? standardError,
            CancellationToken cancellationToken)
        {
            lock (gate) Executables.Add(executable);
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                return new ManagedProcessExit(true, 0, null);
            }
            catch (OperationCanceledException)
            {
                Interlocked.Increment(ref cancelled);
                if (shutdownRelease is not null) await shutdownRelease;
                throw;
            }
        }
    }

    private sealed class NotStartedLauncher : IManagedProcessLauncher
    {
        public Task<ManagedProcessExit> RunAsync(string executable, IReadOnlyList<string> arguments,
            Action<string>? standardOutput, Action<string>? standardError, CancellationToken cancellationToken)
            => Task.FromResult(new ManagedProcessExit(false, null, "launch-failed"));
    }

    private sealed class FailingLauncher : IManagedProcessLauncher
    {
        private int attempts;
        public int Attempts => Volatile.Read(ref attempts);

        public Task<ManagedProcessExit> RunAsync(
            string executable,
            IReadOnlyList<string> arguments,
            Action<string>? standardOutput,
            Action<string>? standardError,
            CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref attempts);
            return Task.FromResult(new ManagedProcessExit(true, 1, "fixture-failure"));
        }
    }

    private sealed class RecoveringLauncher(int failuresPerExecutable) : IManagedProcessLauncher
    {
        private readonly System.Collections.Concurrent.ConcurrentDictionary<string, int> attempts = new();
        private int running;
        public int Running => Volatile.Read(ref running);

        public async Task<ManagedProcessExit> RunAsync(
            string executable,
            IReadOnlyList<string> arguments,
            Action<string>? standardOutput,
            Action<string>? standardError,
            CancellationToken cancellationToken)
        {
            if (attempts.AddOrUpdate(executable, 1, (_, count) => count + 1) <= failuresPerExecutable)
                return new ManagedProcessExit(true, 1, "fixture-failure");
            Interlocked.Increment(ref running);
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return new ManagedProcessExit(true, 0, null);
        }
    }

    private sealed class ThrowingLauncher : IManagedProcessLauncher
    {
        private int attempts;
        public int Attempts => Volatile.Read(ref attempts);

        public Task<ManagedProcessExit> RunAsync(
            string executable,
            IReadOnlyList<string> arguments,
            Action<string>? standardOutput,
            Action<string>? standardError,
            CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref attempts);
            return Task.FromException<ManagedProcessExit>(new IOException("fixture"));
        }
    }

    private sealed class InspectEnvelopeLauncher(ArchiveInspection result)
        : IManagedProcessLauncher
    {
        public Task<ManagedProcessExit> RunAsync(
            string executable,
            IReadOnlyList<string> arguments,
            Action<string>? standardOutput,
            Action<string>? standardError,
            CancellationToken cancellationToken)
        {
            var index = arguments.ToList().IndexOf("--run-index");
            var runIndex = long.Parse(arguments[index + 1],
                System.Globalization.CultureInfo.InvariantCulture);
            standardOutput?.Invoke(ProcessResultJson.Serialize(
                ProcessResultEnvelope<ArchiveInspection>.Success(
                    "archive-worker", runIndex, ProcessOutcome.Succeeded,
                    DateTimeOffset.UtcNow, result)));
            return Task.FromResult(new ManagedProcessExit(
                true, ProcessExitCodes.Success, null));
        }
    }
}
