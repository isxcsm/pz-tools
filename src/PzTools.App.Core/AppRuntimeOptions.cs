using PzTools.Process.Contracts;

namespace PzTools.App.Core;

// Read once per app start. These are advanced defaults, not UI-owned preferences.
public sealed record AppRuntimeOptions(
    int ProjectionIntervalMs = 1000,
    int TelemetryPagesPerRefresh = 8,
    int TelemetryStaleSeconds = 10,
    int TelemetryReadGraceMs = 2000,
    int SuccessCardSeconds = 5,
    int FailureCardSeconds = 10,
    int ThumbnailCacheMib = 64,
    int ThumbnailMaximumMib = 16,
    int StateRefreshTimeoutSeconds = 30,
    int StateRefreshAttempts = 20,
    int StateRefreshRetryMs = 250,
    int SchedulerRestartAttempts = 3,
    int SchedulerRestartBaseMs = 1000,
    int ShutdownGraceMs = 2000,
    int ThumbnailReadConcurrency = 4,
    int ExportProgressIntervalMs = 350,
    int DetailProgressDelayMs = 120,
    int SettingsDebounceMs = 450,
    int LogFilterDebounceMs = 180,
    int CharacterMetadataBatchSize = 8,
    int CharacterMetadataRetrySeconds = 60,
    int TelemetryReadTimeoutSeconds = 1,
    ProfilerRuntimeOptions? Profiler = null,
    HotKeyRuntimeOptions? HotKeys = null)
{
    public ProfilerRuntimeOptions ProfilerOptions => Profiler ?? new();
    public HotKeyRuntimeOptions HotKeyOptions => HotKeys ?? new();

    public static AppRuntimeOptions Read(ComponentConfiguration config)
    {
        config.ValidateSections("logs", "runtime", "profiler", "hotkeys");
        config.ValidateSection("profiler", "general_limit_minutes", "detailed_limit_minutes", "rolling_max_megabytes");
        config.ValidateSection("hotkeys", "sounds", "game_notices", "backup_pause_minutes");
        config.ValidateSection("runtime",
            "projection_interval_ms",
            "telemetry_pages_per_refresh",
            "telemetry_stale_seconds",
            "telemetry_read_grace_ms",
            "success_card_seconds",
            "failure_card_seconds",
            "thumbnail_cache_mib",
            "thumbnail_maximum_mib",
            "state_refresh_timeout_seconds",
            "state_refresh_attempts",
            "state_refresh_retry_ms",
            "scheduler_restart_attempts",
            "scheduler_restart_base_ms",
            "shutdown_grace_ms",
            "thumbnail_read_concurrency",
            "export_progress_interval_ms",
            "detail_progress_delay_ms",
            "settings_debounce_ms",
            "log_filter_debounce_ms",
            "character_metadata_batch_size",
            "character_metadata_retry_seconds",
            "telemetry_read_timeout_seconds");
        return new(
            config.GetInt32("runtime", "projection_interval_ms", 1000, 100, 5000),
            config.GetInt32("runtime", "telemetry_pages_per_refresh", 8, 1, 128),
            config.GetInt32("runtime", "telemetry_stale_seconds", 10, 10, 300),
            config.GetInt32("runtime", "telemetry_read_grace_ms", 2000, 500, 30000),
            config.GetInt32("runtime", "success_card_seconds", 5, 1, 60),
            config.GetInt32("runtime", "failure_card_seconds", 10, 1, 120),
            config.GetInt32("runtime", "thumbnail_cache_mib", 64, 16, 512),
            config.GetInt32("runtime", "thumbnail_maximum_mib", 16, 1, 64),
            config.GetInt32("runtime", "state_refresh_timeout_seconds", 30, 5, 120),
            config.GetInt32("runtime", "state_refresh_attempts", 20, 1, 100),
            config.GetInt32("runtime", "state_refresh_retry_ms", 250, 50, 2000),
            config.GetInt32("runtime", "scheduler_restart_attempts", 3, 0, 10),
            config.GetInt32("runtime", "scheduler_restart_base_ms", 1000, 100, 10000),
            config.GetInt32("runtime", "shutdown_grace_ms", 2000, 100, 10000),
            config.GetInt32("runtime", "thumbnail_read_concurrency", 4, 1, 16),
            config.GetInt32("runtime", "export_progress_interval_ms", 350, 100, 5000),
            config.GetInt32("runtime", "detail_progress_delay_ms", 120, 10, 2000),
            config.GetInt32("runtime", "settings_debounce_ms", 450, 100, 2000),
            config.GetInt32("runtime", "log_filter_debounce_ms", 180, 50, 2000),
            config.GetInt32("runtime", "character_metadata_batch_size", 8, 1, 128),
            config.GetInt32("runtime", "character_metadata_retry_seconds", 60, 10, 3600),
            config.GetInt32("runtime", "telemetry_read_timeout_seconds", 1, 1, 5),
            new ProfilerRuntimeOptions(
                config.GetInt32("profiler", "general_limit_minutes", 30, 1, 30),
                config.GetInt32("profiler", "detailed_limit_minutes", 10, 1, 30),
                config.GetInt32("profiler", "rolling_max_megabytes", 256, 64, 2048)),
            new HotKeyRuntimeOptions(
                config.GetBoolean("hotkeys", "sounds", true),
                config.GetBoolean("hotkeys", "game_notices", true),
                config.GetInt32("hotkeys", "backup_pause_minutes", 30, 5, 240)));
    }
}

/// <summary>
/// The recorder's limits: a forgotten recording ends by itself (Detailed writes about ten times as much), and the
/// game holds at most this much of the last minutes on disk.
/// </summary>
public sealed record ProfilerRuntimeOptions(int GeneralLimitMinutes = 30, int DetailedLimitMinutes = 10, int RollingMaxMegabytes = 256);

/// <summary>How a hotkey answers from inside the game: a sound, a note over the player, and how long a pause lasts.</summary>
public sealed record HotKeyRuntimeOptions(bool Sounds = true, bool GameNotices = true, int BackupPauseMinutes = 30);
