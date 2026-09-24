using PzTools.Process.Contracts;
using Tomlyn.Model;

namespace PzTools.Backup.Core.Configuration;

public sealed record BackupTuningOptions(
    int CaptureAttempts = 5,
    int CaptureRetryDelayMs = 200,
    int CopyBufferKib = 128,
    int ProgressIntervalMs = 250,
    int ScanBatchSize = 512,
    int JournalBatchSize = 4096,
    int HeartbeatIntervalMs = 2000,
    int GameConnectionTimeoutSeconds = 30,
    int GameCompletionTimeoutSeconds = 150,
    int GameQueueTimeoutSeconds = 15)
{
    public static BackupTuningOptions Read(ComponentConfiguration configuration) => new(
        configuration.GetInt32("runtime", "capture_attempts", 5, 1, 20),
        configuration.GetInt32("runtime", "capture_retry_delay_ms", 200, 10, 5000),
        configuration.GetInt32("runtime", "copy_buffer_kib", 128, 16, 4096),
        configuration.GetInt32("runtime", "progress_interval_ms", 250, 50, 2000),
        configuration.GetInt32("runtime", "scan_batch_size", 512, 1, 16384),
        configuration.GetInt32("runtime", "journal_batch_size", 4096, 1, 65536),
        configuration.GetInt32("runtime", "heartbeat_interval_ms", 2000, 250, 4000),
        configuration.GetInt32("runtime", "game_connection_timeout_seconds", 30, 5, 120),
        configuration.GetInt32("runtime", "game_completion_timeout_seconds", 150, 30, 600),
        configuration.GetInt32("runtime", "game_queue_timeout_seconds", 15, 1, 60));

    public TomlTable ToTable() => new()
    {
        ["capture_attempts"] = CaptureAttempts,
        ["capture_retry_delay_ms"] = CaptureRetryDelayMs,
        ["copy_buffer_kib"] = CopyBufferKib,
        ["progress_interval_ms"] = ProgressIntervalMs,
        ["scan_batch_size"] = ScanBatchSize,
        ["journal_batch_size"] = JournalBatchSize,
        ["heartbeat_interval_ms"] = HeartbeatIntervalMs,
        ["game_connection_timeout_seconds"] = GameConnectionTimeoutSeconds,
        ["game_completion_timeout_seconds"] = GameCompletionTimeoutSeconds,
        ["game_queue_timeout_seconds"] = GameQueueTimeoutSeconds,
    };

    public void Validate()
    {
        if (CaptureAttempts is < 1 or > 20 || CaptureRetryDelayMs is < 10 or > 5000
            || CopyBufferKib is < 16 or > 4096 || ProgressIntervalMs is < 50 or > 2000
            || ScanBatchSize is < 1 or > 16384 || JournalBatchSize is < 1 or > 65536
            || HeartbeatIntervalMs is < 250 or > 4000 || GameConnectionTimeoutSeconds is < 5 or > 120
            || GameCompletionTimeoutSeconds is < 30 or > 600 || GameQueueTimeoutSeconds is < 1 or > 60)
            throw new InvalidDataException("Backup runtime settings are outside the documented ranges.");
        if (GameCompletionTimeoutSeconds < GameQueueTimeoutSeconds + 20)
            throw new InvalidDataException("runtime.game_completion_timeout_seconds must exceed game_queue_timeout_seconds by at least 20 seconds.");
    }
}
