using System.Text;
using PzTools.Backup.Core.Configuration;
using PzTools.Process.Contracts;
using PzTools.Projections;
using PzTools.Scheduling;
using Tomlyn;
using Tomlyn.Model;

namespace PzTools.App.Core;

public enum AppTheme { System, Light, Dark }

public sealed record AppSettings(
    SupportedLanguage Language,
    AppTheme Theme,
    string SavesRoot,
    string BackupRoot,
    int BackupIntervalMinutes,
    int RetainedRevisions,
    bool BackupOnDeath,
    LogLevel LogMinimumLevel,
    int LogDisplayLimit,
    bool UseSystemTray = false,
    bool VerifyStagedCopies = true,
    LogLevel LogRecordMinimumLevel = LogLevel.Information,
    int LogMaxEntries = 100000,
    bool SaveGameBeforeBackup = true,
    bool GameSaveCountdown = true)
{
    public static AppSettings CreateDefault()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return new AppSettings(
            SupportedLanguage.Korean,
            AppTheme.System,
            Path.Combine(profile, "Zomboid", "Saves"),
            Path.Combine(profile, "Zomboid", "Backups"),
            5,
            20,
            false,
            LogLevel.Warning,
            1000);
    }

    public AppSettings Validate()
    {
        _ = LanguageCatalog.Get(Language);
        if (BackupIntervalMinutes is < 0 or > 60)
            throw new ArgumentOutOfRangeException(nameof(BackupIntervalMinutes));
        if (RetainedRevisions is < 1 or > 100)
            throw new ArgumentOutOfRangeException(nameof(RetainedRevisions));
        if (LogDisplayLimit is < 100 or > 10000)
            throw new ArgumentOutOfRangeException(nameof(LogDisplayLimit));
        if (!Enum.IsDefined(LogRecordMinimumLevel) || !Enum.IsDefined(LogMinimumLevel)
            || LogMinimumLevel < LogRecordMinimumLevel)
            throw new ArgumentOutOfRangeException(nameof(LogMinimumLevel));
        if (LogMaxEntries is < 10000 or > 500000)
            throw new ArgumentOutOfRangeException(nameof(LogMaxEntries));
        ArgumentException.ThrowIfNullOrWhiteSpace(SavesRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(BackupRoot);
        return this with
        {
            SavesRoot = Path.GetFullPath(SavesRoot),
            BackupRoot = Path.GetFullPath(BackupRoot),
        };
    }
}

public sealed class SettingsProjector(RevisionedViewStore views)
{
    public RevisionedView<SettingsView> Project(AppSettings settings)
    {
        var value = settings.Validate();
        return views.Publish(
            ViewKey.Settings,
            new SettingsView(
                LanguageCatalog.Get(value.Language).Tag,
                value.Theme.ToString(),
                value.SavesRoot,
                value.BackupRoot,
                value.BackupIntervalMinutes,
                value.RetainedRevisions,
                value.BackupOnDeath,
                value.LogMinimumLevel.ToString(),
                value.LogDisplayLimit,
                value.UseSystemTray,
                value.VerifyStagedCopies,
                value.LogRecordMinimumLevel.ToString(),
                value.LogMaxEntries,
                value.SaveGameBeforeBackup,
                value.GameSaveCountdown),
            comparer: EqualityComparer<SettingsView>.Default);
    }
}

public sealed class AppSettingsService
{
    private readonly Func<bool> hasConflictingOperation;
    private string? appliedBackupRoot;

    public AppSettingsService(
        string runtimeRoot,
        Func<bool>? hasConflictingOperation = null)
    {
        RuntimeRoot = Path.GetFullPath(runtimeRoot);
        SettingsPath = Path.Combine(RuntimeRoot, "settings.toml");
        ConfigurationRoot = Path.Combine(RuntimeRoot, "config");
        LoggingConfigurationPath = Path.Combine(ConfigurationRoot, "app", "default.toml");
        this.hasConflictingOperation = hasConflictingOperation ?? (() => false);
    }

    public string RuntimeRoot { get; }
    public string SettingsPath { get; }
    public string ConfigurationRoot { get; }
    public string LoggingConfigurationPath { get; }

    public async Task<string> ResetEditableConfigurationAsync(
        CancellationToken cancellationToken = default)
    {
        var root = Path.GetFullPath(ConfigurationRoot);
        if (!StringComparer.OrdinalIgnoreCase.Equals(
            Path.GetDirectoryName(root), RuntimeRoot))
            throw new InvalidOperationException("설정 폴더 경로가 앱 데이터 폴더를 벗어났습니다.");
        var backups = Path.Combine(RuntimeRoot, "config-backups");
        var archived = Path.Combine(backups,
            $"config-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(backups);
        if (Directory.Exists(root)) Directory.Move(root, archived);
        try
        {
            var user = File.Exists(SettingsPath)
                ? TomlSerializer.Deserialize<TomlTable>(File.ReadAllText(SettingsPath)) ?? []
                : new TomlTable();
            var repository = GetString(user, "paths", "backup_root",
                AppSettings.CreateDefault().BackupRoot);
            var defaults = AppSettings.CreateDefault();
            await EnsureLoggingConfigurationAsync(defaults, cancellationToken);
            await EnsureBackupWorkerConfigurationAsync(repository, true, cancellationToken);
            return archived;
        }
        catch
        {
            if (Directory.Exists(root))
            {
                var failed = Path.Combine(backups,
                    $"failed-reset-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}");
                Directory.Move(root, failed);
            }
            if (Directory.Exists(archived)) Directory.Move(archived, root);
            throw;
        }
    }

    public void ValidateEditableConfiguration()
    {
        if (!Directory.Exists(ConfigurationRoot)) return;
        foreach (var directory in Directory.EnumerateDirectories(
            ConfigurationRoot, "*", SearchOption.TopDirectoryOnly))
        {
            var path = Path.Combine(directory, "default.toml");
            if (!File.Exists(path)) continue;
            try
            {
                _ = TomlSerializer.Deserialize<TomlTable>(File.ReadAllText(path))
                    ?? throw new InvalidDataException("파일이 비어 있습니다.");
                _ = ComponentConfiguration.Load(RuntimeRoot, Path.GetFileName(directory),
                    appSettingsPath: SettingsPath, configurationRoot: ConfigurationRoot);
            }
            catch (Exception exception) when (exception is TomlException or InvalidDataException)
            {
                throw new InvalidDataException($"설정 파일을 확인해 주세요: {path}", exception);
            }
        }
        var settings = Load();
        _ = AppRuntimeOptions.Read(ComponentConfiguration.Load(RuntimeRoot, "app", configurationRoot: ConfigurationRoot));
        var backupPath = ComponentRuntimePaths.GetIdentityDefaultPath(
            settings.BackupRoot, "backup-worker", ConfigurationRoot);
        if (File.Exists(backupPath))
        {
            _ = BackupConfiguration.Parse(
                File.ReadAllText(backupPath), settings.BackupRoot, backupPath,
                new BackupOptionOverrides
                {
                    Sources = [new BackupSourceOptions("validation",
                        Path.Combine(Path.GetDirectoryName(settings.BackupRoot)!,
                            "pztools-validation-source"))],
                });
        }
    }

    public AppSettings Load()
    {
        var model = File.Exists(SettingsPath)
            ? TomlSerializer.Deserialize<TomlTable>(File.ReadAllText(SettingsPath))
                ?? throw new InvalidDataException("앱 설정 파일이 비어 있습니다.")
            : new TomlTable();
        var logging = File.Exists(LoggingConfigurationPath)
            ? TomlSerializer.Deserialize<TomlTable>(File.ReadAllText(LoggingConfigurationPath))
                ?? throw new InvalidDataException("로그 설정 파일이 비어 있습니다.")
            : model;
        if (File.Exists(LoggingConfigurationPath)) ValidateLoggingDocument(logging);
        var defaults = AppSettings.CreateDefault();
        var configuredBackupRoot = GetString(model, "paths", "backup_root", defaults.BackupRoot);
        var backupConfigPath = ComponentRuntimePaths.GetIdentityDefaultPath(
            configuredBackupRoot, "backup-worker", ConfigurationRoot);
        var backupConfig = File.Exists(backupConfigPath)
            ? TomlSerializer.Deserialize<TomlTable>(File.ReadAllText(backupConfigPath))
                ?? throw new InvalidDataException("백업 설정 파일이 비어 있습니다.")
            : model;
        var loaded = new AppSettings(
            LanguageCatalog.Parse(GetString(model, "ui", "language", LanguageCatalog.Get(defaults.Language).Tag)),
            ParseEnum(GetString(model, "ui", "theme", "System"), defaults.Theme),
            GetString(model, "paths", "saves_root", defaults.SavesRoot),
            configuredBackupRoot,
            checked((int)GetInt64(model, "backup", "interval_minutes", defaults.BackupIntervalMinutes)),
            checked((int)GetInt64(model, "backup", "retained_revisions", defaults.RetainedRevisions)),
            GetBoolean(model, "backup", "backup_on_death", false),
            ParseEnum(GetString(model, "logs", "minimum_level", defaults.LogMinimumLevel.ToString()),
                defaults.LogMinimumLevel),
            checked((int)GetInt64(model, "logs", "display_limit", defaults.LogDisplayLimit)),
            GetBoolean(model, "ui", "system_tray", false),
            File.Exists(backupConfigPath)
                ? GetBoolean(backupConfig, "storage", "verify_staged_copies", true)
                : GetBoolean(model, "backup", "verify_staged_copies", true),
            GetRecordMinimumLevel(logging, defaults.LogRecordMinimumLevel),
            GetLogMaxEntries(logging, defaults.LogMaxEntries),
            GetBoolean(model, "backup", "save_game_before_backup",
                GetBoolean(backupConfig, "capture", "save_game_before_backup", true)),
            GetBoolean(model, "backup", "game_save_countdown",
                GetBoolean(backupConfig, "capture", "game_save_countdown", true)));
        // 기존 설정의 추적 표시값은 새 기록 하한보다 낮을 수 있습니다.
        return (loaded with { LogMinimumLevel =
            (LogLevel)Math.Max((int)loaded.LogMinimumLevel, (int)loaded.LogRecordMinimumLevel) }).Validate();
    }

    public async Task<AppSettings> SaveLogOptionsAsync(
        LogLevel minimumLevel, int displayLimit, CancellationToken cancellationToken = default)
    {
        if (!Enum.IsDefined(minimumLevel)) throw new ArgumentOutOfRangeException(nameof(minimumLevel));
        var settings = (Load() with { LogMinimumLevel = minimumLevel, LogDisplayLimit = displayLimit }).Validate();
        // 표시 전용 변경에서는 백업 설정과 스케줄러를 건드리지 않습니다.
        await AtomicTextFile.WriteAsync(SettingsPath, Serialize(settings), cancellationToken);
        return settings;
    }

    public async Task SaveAndApplyAsync(
        AppSettings settings,
        SchedulerDatabase scheduler,
        CancellationToken cancellationToken = default)
    {
        settings = settings.Validate();
        var current = Load();
        if (appliedBackupRoot is not null && settings == current with
            {
                LogMinimumLevel = settings.LogMinimumLevel,
                LogDisplayLimit = settings.LogDisplayLimit,
                LogRecordMinimumLevel = settings.LogRecordMinimumLevel,
                LogMaxEntries = settings.LogMaxEntries,
                SaveGameBeforeBackup = settings.SaveGameBeforeBackup,
                GameSaveCountdown = settings.GameSaveCountdown,
            })
        {
            // These settings do not change the running job or scheduler. The next worker
            // reads the saved game-save preference when it starts.
            await AtomicTextFile.WriteAsync(SettingsPath, Serialize(settings), cancellationToken);
            return;
        }
        // Running workers retain their options. Only switching data roots requires
        // them to stop; UI preferences and future scheduling can change together.
        var requiresIdle = appliedBackupRoot is null
            || !StringComparer.OrdinalIgnoreCase.Equals(current.SavesRoot, settings.SavesRoot)
            || !StringComparer.OrdinalIgnoreCase.Equals(current.BackupRoot, settings.BackupRoot);
        if (requiresIdle && hasConflictingOperation())
            throw new InvalidOperationException("실행 중인 작업과 충돌하여 설정을 적용할 수 없습니다.");
        var effectiveBackupRoot = appliedBackupRoot ?? settings.BackupRoot;
        Directory.CreateDirectory(RuntimeRoot);
        var backupConfigurationPath = ComponentRuntimePaths.GetIdentityDefaultPath(
            effectiveBackupRoot, "backup-worker", ConfigurationRoot);
        var snapshots = new[]
        {
            FileSnapshot.Capture(SettingsPath),
            FileSnapshot.Capture(backupConfigurationPath),
            FileSnapshot.Capture(LoggingConfigurationPath),
        };
        try
        {
            await EnsureLoggingConfigurationAsync(settings, cancellationToken);
            await EnsureBackupWorkerConfigurationAsync(
                effectiveBackupRoot, settings.VerifyStagedCopies, cancellationToken);
            await AtomicTextFile.WriteAsync(
                SettingsPath, Serialize(settings), cancellationToken);

            // Scheduler configuration is the final commit point. Its own update is transactional,
            // and no fallible write follows it.
            await scheduler.ConfigureBackupAsync(
                effectiveBackupRoot,
                settings.BackupIntervalMinutes > 0,
                TimeSpan.FromMinutes(Math.Max(1, settings.BackupIntervalMinutes)),
                DateTimeOffset.UtcNow,
                cancellationToken);
            appliedBackupRoot ??= settings.BackupRoot;
        }
        catch (Exception applyFailure)
        {
            var rollbackFailures = new List<Exception>();
            foreach (var snapshot in snapshots.Reverse())
            {
                try { await snapshot.RestoreAsync(); }
                catch (Exception rollbackFailure) { rollbackFailures.Add(rollbackFailure); }
            }
            if (rollbackFailures.Count > 0)
            {
                throw new AggregateException(
                    "설정 적용과 변경 전 파일 복구가 모두 실패했습니다.",
                    new[] { applyFailure }.Concat(rollbackFailures));
            }
            throw;
        }
    }

    private static string Serialize(AppSettings value) =>
        $"[ui]{Environment.NewLine}"
        + $"language = \"{LanguageCatalog.Get(value.Language).Tag}\"{Environment.NewLine}"
        + $"theme = \"{value.Theme}\"{Environment.NewLine}"
        + $"system_tray = {value.UseSystemTray.ToString().ToLowerInvariant()}{Environment.NewLine}{Environment.NewLine}"
        + $"[paths]{Environment.NewLine}"
        + $"saves_root = {Quote(value.SavesRoot)}{Environment.NewLine}"
        + $"backup_root = {Quote(value.BackupRoot)}{Environment.NewLine}{Environment.NewLine}"
        + $"[backup]{Environment.NewLine}"
        + $"interval_minutes = {value.BackupIntervalMinutes}{Environment.NewLine}"
        + $"retained_revisions = {value.RetainedRevisions}{Environment.NewLine}"
        + $"backup_on_death = {value.BackupOnDeath.ToString().ToLowerInvariant()}{Environment.NewLine}"
        + $"save_game_before_backup = {value.SaveGameBeforeBackup.ToString().ToLowerInvariant()}{Environment.NewLine}"
        + $"game_save_countdown = {value.GameSaveCountdown.ToString().ToLowerInvariant()}{Environment.NewLine}"
        + Environment.NewLine
        + $"[logs]{Environment.NewLine}"
        + $"minimum_level = \"{value.LogMinimumLevel}\"{Environment.NewLine}"
        + $"display_limit = {value.LogDisplayLimit}{Environment.NewLine}";

    private async Task EnsureLoggingConfigurationAsync(
        AppSettings settings, CancellationToken cancellationToken)
    {
        var template = EditableConfigurationTemplates.Read("app")
            .Replace("record_minimum_level = \"Information\"",
                $"record_minimum_level = \"{settings.LogRecordMinimumLevel}\"",
                StringComparison.Ordinal)
            .Replace("max_entries = 100000", $"max_entries = {settings.LogMaxEntries}",
                StringComparison.Ordinal);
        await EditableConfigurationTemplates.EnsureAsync(LoggingConfigurationPath,
            template, cancellationToken);
    }

    public Task EnsureComponentConfigurationAsync(
        string identity, string component,
        CancellationToken cancellationToken = default)
    {
        var path = ComponentRuntimePaths.GetIdentityDefaultPath(
            identity, component, ConfigurationRoot);
        return EditableConfigurationTemplates.EnsureAsync(path,
            EditableConfigurationTemplates.Read(component), cancellationToken);
    }

    private async Task EnsureBackupWorkerConfigurationAsync(
        string repositoryRoot,
        bool initialVerifyStagedCopies,
        CancellationToken cancellationToken)
    {
        var path = ComponentRuntimePaths.GetIdentityDefaultPath(
            repositoryRoot, "backup-worker", ConfigurationRoot);
        var template = EditableConfigurationTemplates.Read("backup-worker")
            .Replace("verify_staged_copies = true",
                $"verify_staged_copies = {initialVerifyStagedCopies.ToString().ToLowerInvariant()}",
                StringComparison.Ordinal);
        await EditableConfigurationTemplates.EnsureAsync(path, template,
            cancellationToken);
    }

    private static string Quote(string value) =>
        $"\"{value.Replace("\\", "\\\\").Replace("\"", "\\\"")}\"";

    private static T ParseEnum<T>(string value, T fallback) where T : struct, Enum =>
        Enum.TryParse<T>(value, true, out var parsed) ? parsed : fallback;

    private static LogLevel ParseLogLevel(string value) =>
        Enum.TryParse<LogLevel>(value, true, out var parsed) && Enum.IsDefined(parsed)
            ? parsed : throw new InvalidDataException(
                "logs.record_minimum_level은 Trace, Information, Warning, Error, Critical 중 하나여야 합니다.");

    private static LogLevel GetRecordMinimumLevel(TomlTable root, LogLevel fallback)
    {
        if (!Section(root, "logs").TryGetValue("record_minimum_level", out var value))
            return fallback;
        return value is string text ? ParseLogLevel(text)
            : throw new InvalidDataException("logs.record_minimum_level은 문자열이어야 합니다.");
    }

    private static int GetLogMaxEntries(TomlTable root, int fallback)
    {
        if (!Section(root, "logs").TryGetValue("max_entries", out var value)) return fallback;
        return value is long number && number is >= 10000 and <= 500000
            ? checked((int)number)
            : throw new InvalidDataException("logs.max_entries는 10000~500000 사이의 정수여야 합니다.");
    }

    private static void ValidateLoggingDocument(TomlTable root)
    {
        if (root.Keys.Any(key => key is not ("logs" or "runtime")))
            throw new InvalidDataException("App advanced settings support only [logs] and [runtime].");
        if (!root.TryGetValue("logs", out var section) || section is not TomlTable logs)
            throw new InvalidDataException("앱 고급 설정에 [logs] 섹션이 필요합니다.");
        if (logs.Keys.Any(key => key is not ("record_minimum_level" or "max_entries")))
            throw new InvalidDataException(
                "[logs]에 알 수 없는 항목이 있습니다. record_minimum_level과 max_entries만 사용할 수 있습니다.");
    }

    private static TomlTable Section(TomlTable root, string name) =>
        root.TryGetValue(name, out var value) && value is TomlTable table
            ? table : [];
    private static string GetString(TomlTable root, string section, string key, string fallback) =>
        Section(root, section).TryGetValue(key, out var value) && value is string text
            ? text : fallback;
    private static long GetInt64(TomlTable root, string section, string key, long fallback) =>
        Section(root, section).TryGetValue(key, out var value) && value is long number
            ? number : fallback;
    private static bool GetBoolean(TomlTable root, string section, string key, bool fallback) =>
        Section(root, section).TryGetValue(key, out var value) && value is bool boolean
            ? boolean : fallback;

    private sealed record FileSnapshot(string Path, byte[]? Contents)
    {
        public static FileSnapshot Capture(string path)
        {
            var absolute = System.IO.Path.GetFullPath(path);
            return new FileSnapshot(
                absolute,
                File.Exists(absolute) ? File.ReadAllBytes(absolute) : null);
        }

        public async Task RestoreAsync()
        {
            if (Contents is null)
            {
                if (File.Exists(Path)) File.Delete(Path);
                return;
            }

            await AtomicTextFile.WriteBytesAsync(Path, Contents, CancellationToken.None);
        }
    }
}

internal static class AtomicTextFile
{
    public static async Task CreateIfAbsentAsync(
        string path,
        string contents,
        CancellationToken cancellationToken)
    {
        var absolute = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(absolute)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                16 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            await using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                await writer.WriteAsync(contents.AsMemory(), cancellationToken);
                await writer.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }
            try { File.Move(temporary, absolute); }
            catch (IOException) when (File.Exists(absolute)) { }
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public static async Task WriteAsync(
        string path,
        string contents,
        CancellationToken cancellationToken)
    {
        var absolute = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(absolute)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                16 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            await using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                await writer.WriteAsync(contents.AsMemory(), cancellationToken);
                await writer.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, absolute, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public static async Task WriteBytesAsync(
        string path,
        ReadOnlyMemory<byte> contents,
        CancellationToken cancellationToken)
    {
        var absolute = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(absolute)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                16 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(contents, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, absolute, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
