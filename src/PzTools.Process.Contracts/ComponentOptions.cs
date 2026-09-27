namespace PzTools.Process.Contracts;

// Both preflight validation and worker entry points read these same typed options.
public sealed record StateSchedulerOptions(int IntervalSeconds, int WakeIntervalMs,
    int ConfirmationDelayMs, int CleanupIntervalSeconds)
{
    public ExtensionControlOptions Extensions { get; init; } = new();

    public static StateSchedulerOptions Read(ComponentConfiguration config)
    {
        config.ValidateSection("scheduler", "interval_seconds", "wake_interval_ms", "confirmation_delay_ms", "cleanup_interval_seconds");
        return new(config.GetInt32("scheduler", "interval_seconds", 3, 1, int.MaxValue),
            config.GetInt32("scheduler", "wake_interval_ms", 1000, 100, 5000),
            config.GetInt32("scheduler", "confirmation_delay_ms", 150, 50, 5000),
            config.GetInt32("scheduler", "cleanup_interval_seconds", 60, 10, 86400))
        {
            Extensions = ExtensionControlOptions.Read(config),
        };
    }
}

public sealed record ExtensionControlOptions(int ReconcileIntervalMs = 1000, int ConnectTimeoutSeconds = 20)
{
    public static ExtensionControlOptions Read(ComponentConfiguration config)
    {
        config.ValidateSection("extensions", "reconcile_interval_ms", "connect_timeout_seconds");
        return new(config.GetInt32("extensions", "reconcile_interval_ms", 1000, 250, 1000),
            config.GetInt32("extensions", "connect_timeout_seconds", 20, 5, 60));
    }
}

public sealed record BackupSchedulerOptions(int WakeIntervalMs, int PreparationLeadSeconds)
{
    public static BackupSchedulerOptions Read(ComponentConfiguration config)
    {
        config.ValidateSection("scheduler", "wake_interval_ms", "preparation_lead_seconds");
        return new(config.GetInt32("scheduler", "wake_interval_ms", 1000, 100, 5000),
            config.GetInt32("scheduler", "preparation_lead_seconds", 8, 5, 30));
    }
}

public sealed record MaintenanceWorkerOptions(int RetainLatestRevisions, int RevisionBatchSize, int WriterRetryDelayMs)
{
    public int RevisionCompactionMaxDelayMinutes { get; init; } = 60;
    public int HistoryRetentionDays { get; init; } = 90;
    public int HistoryMinimumRuns { get; init; } = 1000;
    public int DatabaseCleanupBatchSize { get; init; } = 1000;
    public bool VacuumEnabled { get; init; } = true;
    public int VacuumMinimumFreeMib { get; init; } = 4;
    public int VacuumMinimumFreePercent { get; init; } = 25;
    public int VacuumMaximumDatabaseMib { get; init; } = 256;

    public static MaintenanceWorkerOptions Read(ComponentConfiguration config)
    {
        config.ValidateSection("maintenance", "retain_latest_revisions", "revision_batch_size", "writer_retry_delay_ms",
            "revision_compaction_max_delay_minutes", "history_retention_days", "history_minimum_runs",
            "database_cleanup_batch_size", "vacuum_enabled", "vacuum_minimum_free_mib",
            "vacuum_minimum_free_percent", "vacuum_maximum_database_mib");
        return new(config.GetInt32("maintenance", "retain_latest_revisions", 100, 1, int.MaxValue),
            config.GetInt32("maintenance", "revision_batch_size", 20, 1, 1000),
            config.GetInt32("maintenance", "writer_retry_delay_ms", 200, 50, 5000))
        {
            RevisionCompactionMaxDelayMinutes = config.GetInt32("maintenance", "revision_compaction_max_delay_minutes", 60, 0, 10080),
            HistoryRetentionDays = config.GetInt32("maintenance", "history_retention_days", 90, 0, 3650),
            HistoryMinimumRuns = config.GetInt32("maintenance", "history_minimum_runs", 1000, 1, int.MaxValue),
            DatabaseCleanupBatchSize = config.GetInt32("maintenance", "database_cleanup_batch_size", 1000, 1, 10000),
            VacuumEnabled = config.GetBoolean("maintenance", "vacuum_enabled", true),
            VacuumMinimumFreeMib = config.GetInt32("maintenance", "vacuum_minimum_free_mib", 4, 1, int.MaxValue),
            VacuumMinimumFreePercent = config.GetInt32("maintenance", "vacuum_minimum_free_percent", 25, 1, 100),
            VacuumMaximumDatabaseMib = config.GetInt32("maintenance", "vacuum_maximum_database_mib", 256, 1, int.MaxValue),
        };
    }
}

public sealed record ArchiveWorkerOptions(int PlayersDatabaseMib, int ThumbnailMib, int MaximumEntries,
    long MaximumSingleFileBytes, long MinimumFreeSpaceReserveBytes, int MinimumFreeSpaceReservePercent)
{
    public static ArchiveWorkerOptions Read(ComponentConfiguration config)
    {
        config.ValidateSection("preview", "players_database_mib", "thumbnail_mib");
        config.ValidateSection("archive", "maximum_entries", "maximum_single_file_bytes",
            "minimum_free_space_reserve_bytes", "minimum_free_space_reserve_percent");
        var result = new ArchiveWorkerOptions(
            config.GetInt32("preview", "players_database_mib", 64, 1, 1024),
            config.GetInt32("preview", "thumbnail_mib", 16, 1, 64),
            config.GetInt32("archive", "maximum_entries", 1_000_000, 1, int.MaxValue),
            config.GetInt64("archive", "maximum_single_file_bytes", 64L * 1024 * 1024 * 1024),
            config.GetInt64("archive", "minimum_free_space_reserve_bytes", 5L * 1024 * 1024 * 1024),
            config.GetInt32("archive", "minimum_free_space_reserve_percent", 10, 0, 100));
        if (result.MaximumSingleFileBytes <= 0 || result.MinimumFreeSpaceReserveBytes < 0)
            throw new InvalidDataException("Archive file size must be positive and free-space reserve must not be negative.");
        return result;
    }
}

public sealed record TelemetryRuntimeOptions(bool Enabled, int RetainRuns, int MaxDatabaseMib,
    int ProgressFlushIntervalMs, int HeartbeatIntervalMs)
{
    public static TelemetryRuntimeOptions Read(ComponentConfiguration config) => new(
        config.GetBoolean("telemetry", "enabled", true),
        config.GetInt32("telemetry", "retain_runs", 100, 0, int.MaxValue),
        config.GetInt32("telemetry", "max_database_mib", 64, 0, int.MaxValue),
        config.GetInt32("telemetry", "progress_flush_interval_ms", 100, 25, 2000),
        config.GetInt32("telemetry", "heartbeat_interval_ms", 5000, 250, 5000));
}

public static class ComponentOptions
{
    public static void Validate(string component, ComponentConfiguration config)
    {
        // These have their own complete schemas in App.Core and Backup.Core.
        if (component is "app" or "backup-worker") return;
        string[] sections = component switch
        {
            "state-scheduler" => ["scheduler", "extensions", "telemetry"],
            "backup-scheduler" => ["scheduler", "telemetry"],
            "maintenance-worker" => ["maintenance", "telemetry"],
            "archive-worker" => ["archive", "preview", "telemetry"],
            "state-reactor" => ["state", "telemetry"],
            "backup-runner" or "maintenance-runner" or "state-runner" or "state-collector"
                or "restore-worker" or "character-recovery" => ["telemetry"],
            _ => [],
        };
        if (sections.Length == 0) return;
        config.ValidateSections(sections);
        config.ValidateSection("telemetry", "enabled", "retain_runs", "max_database_mib",
            "progress_flush_interval_ms", "heartbeat_interval_ms");
        _ = TelemetryRuntimeOptions.Read(config);
        switch (component)
        {
            case "state-scheduler": _ = StateSchedulerOptions.Read(config); break;
            case "backup-scheduler": _ = BackupSchedulerOptions.Read(config); break;
            case "maintenance-worker": _ = MaintenanceWorkerOptions.Read(config); break;
            case "archive-worker": _ = ArchiveWorkerOptions.Read(config); break;
            case "state-reactor":
                config.ValidateSection("state", "backup_on_death");
                _ = config.GetBoolean("state", "backup_on_death", false);
                break;
        }
    }
}
