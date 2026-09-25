from pathlib import Path
import html
import json
import re
import subprocess

BASE = '68f4767b0250d8bef4d65e750e7718a8ab6b5f44'
R = Path('.')
# No source archive/export: modify only the user's requested branch files.
subprocess.run(['git', 'diff', '--exit-code', BASE, '--', 'src', 'tests', 'docs', 'README.md'], check=True)
changed = set()
def edit(path, old, new, count=1):
    p = R/path
    text = p.read_text(encoding='utf-8-sig')
    assert text.count(old) == count, (path, text.count(old), old[:80])
    p.write_text(text.replace(old, new), encoding='utf-8')
    changed.add(path)

p='src/PzTools.App.Core/AppSettings.cs'
edit(p,'    bool GameSaveCountdown = true)','    bool GameSaveCountdown = true,\n    bool AutomaticBackupEnabled = true)')
edit(p,'BackupIntervalMinutes is < 0 or > 60','BackupIntervalMinutes is < 1 or > 60')
edit(p,'                value.GameSaveCountdown),','                value.GameSaveCountdown,\n                value.AutomaticBackupEnabled),')
edit(p,'        var loaded = new AppSettings(','        var (automaticEnabled, intervalMinutes) = ReadBackupSchedule(model, defaults);\n        var loaded = new AppSettings(')
edit(p,'            checked((int)GetInt64(model, "backup", "interval_minutes", defaults.BackupIntervalMinutes)),','            intervalMinutes,')
edit(p,'                GetBoolean(backupConfig, "capture", "game_save_countdown", true)));','                GetBoolean(backupConfig, "capture", "game_save_countdown", true)),\n            automaticEnabled);')
edit(p,'                settings.BackupIntervalMinutes > 0,\n                TimeSpan.FromMinutes(Math.Max(1, settings.BackupIntervalMinutes)),','                settings.AutomaticBackupEnabled,\n                TimeSpan.FromMinutes(settings.BackupIntervalMinutes),')
edit(p,'        + $"interval_minutes = {value.BackupIntervalMinutes}{Environment.NewLine}"','        + $"automatic_enabled = {value.AutomaticBackupEnabled.ToString().ToLowerInvariant()}{Environment.NewLine}"\n        + $"interval_minutes = {value.BackupIntervalMinutes}{Environment.NewLine}"')
edit(p,'    private static TomlTable Section(TomlTable root, string name) =>','''    private static (bool Enabled, int Minutes) ReadBackupSchedule(TomlTable root, AppSettings defaults)
    {
        var backup = Section(root, "backup");
        var minutes = defaults.BackupIntervalMinutes;
        if (backup.TryGetValue("interval_minutes", out var interval))
        {
            if (interval is not long number || number is < 0 or > 60)
                throw new InvalidDataException("backup.interval_minutes must be an integer from 1 to 60.");
            minutes = (int)number;
        }
        if (!backup.TryGetValue("automatic_enabled", out var enabled))
        {
            // A prior interval of zero was an explicit opt-out. Never silently enable it.
            // There is no remembered positive value in that file; use the default cadence.
            // Loading does not rewrite the file. The next save persists the separate fields.
            return minutes == 0 ? (false, defaults.BackupIntervalMinutes)
                : (defaults.AutomaticBackupEnabled, minutes);
        }
        if (enabled is not bool flag)
            throw new InvalidDataException("backup.automatic_enabled must be a boolean.");
        if (minutes < 1)
            throw new InvalidDataException("backup.interval_minutes must be an integer from 1 to 60.");
        return (flag, minutes);
    }

    private static TomlTable Section(TomlTable root, string name) =>''')
edit('src/PzTools.Projections/ViewModels.cs','    bool GameSaveCountdown = true);','    bool GameSaveCountdown = true,\n    bool AutomaticBackupEnabled = true);')
p='src/PzTools.App/SettingsPage.xaml'
edit(p,'          <toolkit:SettingsCard x:Name="IntervalSettingCard"\n                                Header="백업 간격" Description="0분은 자동 백업을 끕니다.">','''          <toolkit:SettingsCard x:Name="AutomaticBackupSettingCard" Header="자동 백업">
            <toolkit:SettingsCard.HeaderIcon><SymbolIcon Symbol="Sync" /></toolkit:SettingsCard.HeaderIcon>
            <ToggleSwitch x:Name="AutomaticBackupToggle" Toggled="AutomaticBackupToggle_Toggled" />
          </toolkit:SettingsCard>
          <toolkit:SettingsCard x:Name="IntervalSettingCard"
                                Header="백업 간격" Description="1~60분. 자동 백업을 꺼도 간격은 유지됩니다.">''')
edit(p,'x:Name="IntervalSlider" Minimum="0"','x:Name="IntervalSlider" Minimum="1"')
edit(p,'x:Name="IntervalNumber" Grid.Column="1" Minimum="0"','x:Name="IntervalNumber" Grid.Column="1" Minimum="1"')
p='src/PzTools.App/SettingsPage.xaml.cs'
edit(p,'GameSaveCountdownToggle, DeathBackupToggle }','GameSaveCountdownToggle, AutomaticBackupToggle, DeathBackupToggle }')
edit(p,'        IntervalSettingCard.Header = Localizer.Get("IntervalSetting.Header");','''        AutomaticBackupSettingCard.Header = Localizer.Get("AutomaticBackupSetting.Header");
        AutomaticBackupSettingCard.Description = Localizer.Get("AutomaticBackupSetting.Description");
        IntervalSettingCard.Header = Localizer.Get("IntervalSetting.Header");''')
edit(p,'            Localizer.Get("AutomaticBackupSettings.Description");','            Localizer.Get("IntervalSetting.Description");')
edit(p,'        DeathBackupSettingCard.Header = Localizer.Get("DeathBackupSetting.Header");','        DeathBackupSettingCard.Header = Localizer.Get("DeathBackupSetting.Header");\n        DeathBackupSettingCard.Description = Localizer.Get("DeathBackupSetting.Description");')
edit(p,'        SetInputName(IntervalSlider, IntervalSettingCard.Header);','        SetInputName(AutomaticBackupToggle, AutomaticBackupSettingCard.Header);\n        SetInputName(IntervalSlider, IntervalSettingCard.Header);')
edit(p,'            IntervalSlider.Value = IntervalNumber.Value = value.BackupIntervalMinutes;','            AutomaticBackupToggle.IsOn = value.AutomaticBackupEnabled;\n            IntervalSlider.Value = IntervalNumber.Value = value.BackupIntervalMinutes;')
edit(p,'            DeathBackupToggle.IsOn = value.BackupOnDeath;','            DeathBackupToggle.IsOn = value.BackupOnDeath;\n            DeathBackupToggle.IsEnabled = value.AutomaticBackupEnabled;')
edit(p,'        GameSaveCountdownToggle.IsOn);','        GameSaveCountdownToggle.IsOn,\n        AutomaticBackupToggle.IsOn);')
edit(p,'        Synchronize(() => IntervalNumber.Value = Math.Round(e.NewValue));','        Synchronize(() => IntervalNumber.Value = Math.Clamp(Math.Round(e.NewValue), 1, 60));')
edit(p,'        Synchronize(() => IntervalSlider.Value = Math.Round(args.NewValue));','''        var minutes = Math.Clamp(Math.Round(args.NewValue), 1, 60);
        Synchronize(() => IntervalSlider.Value = IntervalNumber.Value = minutes);''')
edit(p,'    private void SettingChanged(object sender, object e)','''    private async void AutomaticBackupToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (DeathBackupToggle is not null)
            DeathBackupToggle.IsEnabled = AutomaticBackupToggle.IsOn;
        if (loading || !IsLoaded) return;
        // A pause switch must not be lost when navigating away before numeric debounce fires.
        requestedApply++;
        applyTimer.Stop();
        await ApplyPendingSettingsAsync();
    }

    private void SettingChanged(object sender, object e)''')
edit(p,'        if (GameSaveCountdownToggle is not null)\n            GameSaveCountdownToggle.IsEnabled = GameSaveToggle.IsOn;','''        if (GameSaveCountdownToggle is not null)
            GameSaveCountdownToggle.IsEnabled = GameSaveToggle.IsOn;
        if (AutomaticBackupToggle is not null && DeathBackupToggle is not null)
            DeathBackupToggle.IsEnabled = AutomaticBackupToggle.IsOn;''')
p='tests/PzTools.Backup.Tests/AppCoreTests.cs'
edit(p,'    [InlineData(0, 100)]','    [InlineData(1, 100)]')
edit(p,'            BackupIntervalMinutes = 0,','            BackupIntervalMinutes = 17,\n            AutomaticBackupEnabled = false,')
edit(p,'initial with { BackupIntervalMinutes = 0 }','initial with { AutomaticBackupEnabled = false }')
edit(p,'        Assert.Equal(0, service.Load().BackupIntervalMinutes);','        Assert.Equal(initial.BackupIntervalMinutes, service.Load().BackupIntervalMinutes);\n        Assert.False(service.Load().AutomaticBackupEnabled);')
edit(p,'    [InlineData(0)]\n    [InlineData(1)]\n    [InlineData(15)]\n    public async Task Settings_CanChangeIntervalTogetherWithOtherPreferencesDuringBackup(int minutes)','    [InlineData(1, false)]\n    [InlineData(1, true)]\n    [InlineData(15, true)]\n    [InlineData(15, false)]\n    public async Task Settings_CanChangeIntervalTogetherWithOtherPreferencesDuringBackup(int minutes, bool automaticEnabled)')
edit(p,'            BackupIntervalMinutes = minutes, Theme = AppTheme.Dark,','            BackupIntervalMinutes = minutes, AutomaticBackupEnabled = automaticEnabled, Theme = AppTheme.Dark,')
edit(p,'        Assert.Equal(minutes > 0, state.AutomaticEnabled);\n        Assert.Equal(TimeSpan.FromMinutes(Math.Max(1, minutes)), state.Interval);\n        if (minutes > 0) Assert.True(state.NextDueUtc >= before.AddMinutes(minutes));','        Assert.Equal(automaticEnabled, state.AutomaticEnabled);\n        Assert.Equal(TimeSpan.FromMinutes(minutes), state.Interval);\n        if (automaticEnabled) Assert.True(state.NextDueUtc >= before.AddMinutes(minutes));')
p='tests/PzTools.Backup.Tests/LocalizationTests.cs'
edit(p,'            BackupIntervalMinutes = 0, RetainedRevisions = 37,','            BackupIntervalMinutes = 17, AutomaticBackupEnabled = false, RetainedRevisions = 37,')
edit(p,'        Assert.Equal(settings, loaded);','        Assert.Equal(settings, loaded);\n        Assert.False(loaded.AutomaticBackupEnabled);\n        Assert.Equal(17, loaded.BackupIntervalMinutes);')
new_test='tests/PzTools.Backup.Tests/AutomaticBackupToggleTests.cs'
assert not Path(new_test).exists()
Path(new_test).write_bytes(Path('.github/AutomaticBackupToggleTests.cs').read_bytes())
changed.add(new_test)

languages=json.loads(Path('.github/automatic-backup-toggle-locales.json').read_text(encoding='utf-8'))
assert len(languages)==18
for tag, (title, description, interval, death, guide) in languages.items():
    p=R/'src/PzTools.App/Strings'/tag/'Resources.resw'
    s=p.read_text(encoding='utf-8')
    def row(key,val): return f'  <data name="{key}" xml:space="preserve"><value>{html.escape(val, quote=False)}</value></data>'
    s,n=re.subn(r'  <data name="AutomaticBackupSettings.Description"[^\n]+',lambda _:row('AutomaticBackupSetting.Header',title)+'\n'+row('AutomaticBackupSetting.Description',description),s); assert n==1,tag
    s,n=re.subn(r'  <data name="IntervalSetting.Description"[^\n]+',lambda _:row('IntervalSetting.Description',interval),s); assert n==1,tag
    s,n=re.subn(r'(  <data name="DeathBackupSetting.Header"[^\n]+)',lambda m:m[0]+'\n'+row('DeathBackupSetting.Description',death),s); assert n==1,tag
    p.write_text(s,encoding='utf-8');changed.add(p.as_posix())
    p=R/('README.md' if tag=='en-US' else f'docs/{tag}/README.md')
    s=p.read_text(encoding='utf-8'); lines=s.splitlines(keepends=True)
    hits=[i for i,line in enumerate(lines) if '`0`' in line]; assert len(hits)==1,(tag,hits)
    i=hits[0]
    if tag=='th-TH':
        old='ช่วงเวลา `0` ปิดการสำรองอัตโนมัติ'
        assert lines[i].count(old)==1
        lines[i]=lines[i].replace(old,guide)
    else:
        lines[i],n=re.subn(r'[^.。!?\n]*`0`[^.。!?\n]*[.。!?]',lambda m:' '+guide,lines[i],count=1); assert n==1,tag
    p.write_text(''.join(lines),encoding='utf-8');changed.add(p.as_posix())

p='docs/ui-ux-contract.md'
edit(p,'| 백업 | 자동 백업 간격 | 0~60 slider와 NumberBox | 5분 |','| 백업 | 자동 백업 | ToggleSwitch | 켜짐 |\n| 백업 | 자동 백업 간격 | 1~60 slider와 NumberBox | 5분 |')
edit(p,'간격 0은 periodic, final과 death-triggered run을 포함한 모든 자동 백업을 끕니다.\n수동 백업은 계속 사용할 수 있습니다.','자동 백업 토글은 정기·사망 시 자동 실행을 함께 켜거나 끕니다. 꺼도 간격과 사망 시\n백업 선택은 유지합니다. 간격은 꺼진 상태에서도 편집할 수 있고, 다시 켜면 새 간격을\n시작합니다. 사망 시 백업 토글만 비활성화하여 종속 관계를 표시합니다. 수동 백업과\n이미 시작된 백업, 필수 save(true)는 이 토글을 바꿔도 영향을 받지 않습니다.')
edit(p,'| 백업 | 백업 개수 | 1~100 slider와 NumberBox | 100 |','| 백업 | 백업 개수 | 1~100 slider와 NumberBox | 20 |')
p='docs/implementation-roadmap.md'
edit(p,'간격 0에서는\n  State 명령이 target을 갱신할 수 있지만 periodic, final과 death run을 admission하지','토글이 꺼져 있으면\n  State 명령이 target을 갱신할 수 있지만 periodic과 death run을 admission하지')
edit(p,'- 자동 백업 간격은 0~60분 정수이며 기본값은 5분입니다. 0은 자동 백업\n  비활성화입니다.\n- 간격 0은 periodic, final과 death-triggered backup을 포함한 모든 자동 실행보다\n  우선합니다. 수동 백업은 계속 사용할 수 있습니다.','- 자동 백업은 별도 토글이며 기본값은 켜짐입니다. 간격은 1~60분 정수이며 기본값은\n  5분입니다. 꺼도 간격과 사망 시 백업 설정을 보존합니다.\n- 토글 꺼짐은 periodic과 death-triggered backup을 포함한 모든 자동 실행보다\n  우선합니다. 수동 백업과 이미 시작된 백업은 계속 사용할 수 있습니다.')
edit(p,'backup_root, interval_minutes,','backup_root, automatic_enabled, interval_minutes,')
edit(p,'interval 0~60, retention','automatic enabled toggle, interval 1~60, retention')
p='docs/configuration.md'
edit(p,'## 백업 worker 설정','''`[backup].automatic_enabled`는 자동 백업 토글이며 기본값은 `true`입니다.
`interval_minutes`는 이 토글과 독립적인 1~60분 정수(기본 5)입니다. 토글을 꺼도
간격·사망 시 백업 선택을 저장하며, 간격을 편집하는 것만으로 자동 백업이 켜지지 않습니다.
다시 켜면 현재 플레이 상태를 확인하고 새 간격부터 시작합니다. 수동 백업과 이미
시작된 백업은 중단하지 않으며 `save_game_before_backup`도 변경하지 않습니다.
토글이 없던 이전 설정에서 `interval_minutes = 0`은 명시적인 비활성 선택이므로
꺼짐을 유지하고 잃어버린 간격 대신 기본값 5분을 표시합니다. 읽기만으로 파일을
변경하지 않으며 다음 설정 저장부터 두 필드를 기록합니다. 별도 토글이 있는 새
설정에서 간격 0이나 잘못된 자료형은 오류로 처리합니다. 백업 저장소 변환은 없습니다.

## 백업 worker 설정''')
assert all(p.startswith(('src/','tests/','docs/')) or p=='README.md' for p in changed)
subprocess.run(['git', 'diff', '--check'],check=True)
subprocess.run(['git', 'add', '--', *sorted(changed)],check=True)
print('Prepared',len(changed),'settings, localization, documentation and regression files.')
