using Microsoft.Data.Sqlite;
using PzTools.App.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Process.Contracts;
using PzTools.Projections;
using PzTools.Scheduling;

namespace PzTools.Backup.Tests;

public sealed class AutomaticBackupToggleTests
{
    [Fact]
    public void DefaultsKeepAutomationOnAndFiveMinuteInterval()
    {
        using var temp = new TempDirectory();
        var settings = new AppSettingsService(temp.GetPath("runtime")).Load();
        Assert.True(settings.AutomaticBackupEnabled);
        Assert.Equal(5, settings.BackupIntervalMinutes);
        Assert.True(settings.SaveGameBeforeBackup);
    }

    [Theory]
    [InlineData(false, 1)]
    [InlineData(false, 60)]
    [InlineData(true, 1)]
    [InlineData(true, 60)]
    public async Task SwitchAndPositiveIntervalRoundTripIndependently(bool enabled, int minutes)
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var settings = Settings(temp) with { AutomaticBackupEnabled = enabled, BackupIntervalMinutes = minutes };
        await service.SaveAndApplyAsync(settings, scheduler);
        Assert.Equal(settings, new AppSettingsService(service.RuntimeRoot).Load());
        var state = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.Equal(enabled, state.AutomaticEnabled);
        Assert.Equal(TimeSpan.FromMinutes(minutes), state.Interval);
        Assert.Contains($"automatic_enabled = {enabled.ToString().ToLowerInvariant()}", File.ReadAllText(service.SettingsPath));
        Assert.Contains($"interval_minutes = {minutes}", File.ReadAllText(service.SettingsPath));
        var views = new RevisionedViewStore();
        new SettingsProjector(views).Project(settings);
        var view = views.ReadIfChanged<SettingsView>(ViewKey.Settings, 0).Snapshot!;
        Assert.Equal(enabled, view.AutomaticBackupEnabled);
        Assert.Equal(minutes, view.BackupIntervalMinutes);
        var worker = BackupConfiguration.Load(settings.BackupRoot,
            overrides: new() { Sources = [new("test", settings.SavesRoot)] },
            appSettingsPath: service.SettingsPath, configurationRoot: service.ConfigurationRoot);
        Assert.True(worker.SaveGameBeforeBackup);
    }

    [Theory]
    [InlineData(0, false)]
    [InlineData(0, true)]
    [InlineData(-1, false)]
    [InlineData(61, true)]
    public void ModelRejectsInvalidIntervalsEvenWhenOff(int minutes, bool enabled) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => (AppSettings.CreateDefault() with
        { AutomaticBackupEnabled = enabled, BackupIntervalMinutes = minutes }).Validate());

    [Theory]
    [InlineData("automatic_enabled = 'false'\ninterval_minutes = 5")]
    [InlineData("automatic_enabled = 0\ninterval_minutes = 5")]
    [InlineData("automatic_enabled = false\ninterval_minutes = 0")]
    [InlineData("automatic_enabled = true\ninterval_minutes = 0")]
    [InlineData("automatic_enabled = false\ninterval_minutes = 1.5")]
    [InlineData("automatic_enabled = false\ninterval_minutes = '5'")]
    [InlineData("automatic_enabled = false\ninterval_minutes = 61")]
    public void InvalidSavedSettingsNeverSilentlyEnableAutomation(string document)
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        Directory.CreateDirectory(service.RuntimeRoot);
        var original = "[backup]\n" + document + "\n";
        File.WriteAllText(service.SettingsPath, original);
        Assert.Throws<InvalidDataException>(() => service.Load());
        Assert.Equal(original, File.ReadAllText(service.SettingsPath));
    }

    [Fact]
    public async Task PreviousZeroPreferenceStaysOff_AndOnlyNextSaveWritesSeparateFields()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        Directory.CreateDirectory(service.RuntimeRoot);
        const string original = "[backup]\ninterval_minutes = 0\nbackup_on_death = true\n";
        File.WriteAllText(service.SettingsPath, original);
        var settings = service.Load();
        Assert.False(settings.AutomaticBackupEnabled);
        Assert.Equal(AppSettings.CreateDefault().BackupIntervalMinutes, settings.BackupIntervalMinutes);
        Assert.True(settings.BackupOnDeath);
        Assert.Equal(original, File.ReadAllText(service.SettingsPath));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        settings = settings with { SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups") };
        await service.SaveAndApplyAsync(settings, scheduler);
        Assert.Equal(settings, service.Load());
        Assert.False((await scheduler.ReadBackupStateIfChangedAsync(-1)).AutomaticEnabled);
        Assert.Contains("automatic_enabled = false", File.ReadAllText(service.SettingsPath));
        Assert.Contains("interval_minutes = 5", File.ReadAllText(service.SettingsPath));
    }

    [Fact]
    public async Task OffKeepsIntervalDeathAndSavePreferences_AndDropsQueuedAutomaticWork()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var settings = Settings(temp);
        await service.SaveAndApplyAsync(settings, scheduler);
        var target = Target(temp);
        var now = DateTimeOffset.UtcNow;
        await scheduler.EnqueueTargetCommandAsync(new("active", BackupTargetCommandKind.ActivateTarget, target));
        await scheduler.PrepareBackupTickAsync(now);
        var prior = (await scheduler.PrepareBackupTickAsync(now.AddMinutes(17)))!;
        await scheduler.EnqueueTargetCommandAsync(new("death", BackupTargetCommandKind.RunOnceNow, target));
        Assert.Equal(BackupAdmissionKind.RunOnce, (await scheduler.PrepareBackupTickAsync(now))!.Kind);
        var off = settings with { AutomaticBackupEnabled = false };
        await service.SaveAndApplyAsync(off, scheduler);
        Assert.Equal(off, service.Load());
        var stopped = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.Equal(TimeSpan.FromMinutes(17), stopped.Interval);
        Assert.Equal(0, stopped.PendingRuns);
        Assert.False(stopped.AutomaticEnabled);
        Assert.Null(await scheduler.PrepareBackupTickAsync(now.AddDays(1)));
        await scheduler.FinishBackupTickAsync(prior, true, 1, ProcessOutcome.Succeeded, now.AddMinutes(18));
        Assert.False((await scheduler.ReadBackupStateIfChangedAsync(-1)).AutomaticEnabled);
        var views = new RevisionedViewStore();
        await new SchedulerProjector(scheduler, views).ProjectOnceAsync();
        Assert.Null(views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!.NextDueUtc);
        await service.SaveLogOptionsAsync(LogLevel.Warning, 1200);
        Assert.False(service.Load().AutomaticBackupEnabled);
        Assert.Equal(17, service.Load().BackupIntervalMinutes);
        Assert.True(service.Load().BackupOnDeath);
        Assert.True(service.Load().SaveGameBeforeBackup);
    }

    [Fact]
    public async Task IntervalCanChangeWhileOff_ReenableStartsFreshInterval_NotImmediateOrQueuedDeath()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var settings = Settings(temp);
        await service.SaveAndApplyAsync(settings, scheduler);
        var target = Target(temp);
        await scheduler.EnqueueTargetCommandAsync(new("active", BackupTargetCommandKind.ActivateTarget, target));
        await scheduler.PrepareBackupTickAsync(DateTimeOffset.UtcNow);
        await service.SaveAndApplyAsync(settings with { AutomaticBackupEnabled = false }, scheduler);
        var off = new AppSettingsService(service.RuntimeRoot).Load() with { BackupIntervalMinutes = 23 };
        await service.SaveAndApplyAsync(off, scheduler);
        Assert.False(service.Load().AutomaticBackupEnabled);
        Assert.Equal(23, service.Load().BackupIntervalMinutes);
        Assert.Null(await scheduler.PrepareBackupTickAsync(DateTimeOffset.UtcNow.AddDays(1)));
        await scheduler.EnqueueTargetCommandAsync(new("death-while-off", BackupTargetCommandKind.RunOnceNow, target));
        var before = DateTimeOffset.UtcNow;
        await service.SaveAndApplyAsync(service.Load() with { AutomaticBackupEnabled = true }, scheduler);
        var after = DateTimeOffset.UtcNow;
        var state = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.True(state.AutomaticEnabled);
        Assert.Equal(0, state.PendingRuns);
        Assert.InRange(state.NextDueUtc, before.AddMinutes(23), after.AddMinutes(23));
        Assert.Null(await scheduler.PrepareBackupTickAsync(state.NextDueUtc.AddTicks(-1)));
        Assert.Equal(BackupAdmissionKind.Periodic, (await scheduler.PrepareBackupTickAsync(state.NextDueUtc))!.Kind);
        Assert.Equal(23, service.Load().BackupIntervalMinutes);
    }

    [Fact]
    public async Task EnablingOrEditingWhileOfflineCannotCreateCountdownOrBackup()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        await service.SaveAndApplyAsync(Settings(temp) with { AutomaticBackupEnabled = false }, scheduler);
        await service.SaveAndApplyAsync(service.Load() with { AutomaticBackupEnabled = true, BackupIntervalMinutes = 1 }, scheduler);
        Assert.Null(await scheduler.PrepareBackupTickAsync(DateTimeOffset.UtcNow.AddDays(1)));
        Assert.Null((await scheduler.ReadBackupStateIfChangedAsync(-1)).CurrentTarget);
        var views = new RevisionedViewStore();
        await new SchedulerProjector(scheduler, views, requireActiveState: true).ProjectOnceAsync();
        Assert.Null(views.ReadIfChanged<ScheduleStatusView>(ViewKey.ScheduleStatus, 0).Snapshot!.NextDueUtc);
    }

    [Fact]
    public async Task FailedSchedulerUpdateRestoresSavedSwitchAndInterval()
    {
        using var temp = new TempDirectory();
        var service = new AppSettingsService(temp.GetPath("runtime"));
        var scheduler = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var settings = Settings(temp);
        await service.SaveAndApplyAsync(settings, scheduler);
        var original = File.ReadAllBytes(service.SettingsPath);
        await using (var connection = new SqliteConnection($"Data Source={scheduler.DatabasePath};Pooling=False"))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "CREATE TRIGGER reject_toggle BEFORE UPDATE OF automatic_enabled ON backup_scheduler_control BEGIN SELECT RAISE(ABORT,'fixture rollback'); END;";
            await command.ExecuteNonQueryAsync();
        }
        await Assert.ThrowsAsync<SqliteException>(() => service.SaveAndApplyAsync(
            settings with { AutomaticBackupEnabled = false, BackupIntervalMinutes = 23 }, scheduler));
        Assert.Equal(original, File.ReadAllBytes(service.SettingsPath));
        Assert.Equal(settings, service.Load());
        var state = await scheduler.ReadBackupStateIfChangedAsync(-1);
        Assert.True(state.AutomaticEnabled);
        Assert.Equal(TimeSpan.FromMinutes(17), state.Interval);
    }

    private static AppSettings Settings(TempDirectory temp) => AppSettings.CreateDefault() with
    {
        SavesRoot = temp.GetPath("saves"), BackupRoot = temp.GetPath("backups"),
        BackupIntervalMinutes = 17, BackupOnDeath = true,
    };
    private static BackupTarget Target(TempDirectory temp) => new("Sandbox/Save", "Sandbox/Save", temp.GetPath("saves/Save"));
}
