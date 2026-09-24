using PzTools.Process.Contracts;
namespace PzTools.Backup.Core.Configuration;

public sealed record BackupOptions(
    int FormatVersion,
    string RepositoryPath,
    IReadOnlyList<BackupSourceOptions> Sources,
    StorageOptions Storage,
    TelemetryOptions Telemetry,
    IReadOnlyList<string>? AlwaysIncludePaths = null,
    SupportedLanguage NameLanguage = SupportedLanguage.Korean,
    bool FullScanHashComparison = true,
    bool SaveGameBeforeBackup = true,
    BackupTuningOptions? Tuning = null,
    bool GameSaveCountdown = true)
{
    public BackupTuningOptions EffectiveTuning => Tuning ?? new();
}

public sealed record BackupSourceOptions(string Id, string Path);

public sealed record StorageOptions(
    ChecksumAlgorithm Checksum,
    CompressionAlgorithm Compression,
    bool ContentDeduplication,
    bool VerifyStagedCopies = true);

public sealed record TelemetryOptions(
    TelemetryMode Mode,
    int BatchSize,
    int FlushIntervalMilliseconds,
    int RetainRuns,
    int MaxDatabaseMib,
    bool Enabled = true);

public enum ChecksumAlgorithm
{
    Auto,
    None,
    XxHash64,
    Sha256,
}

public enum CompressionAlgorithm
{
    Auto,
    None,
    Brotli,
}

public enum TelemetryMode
{
    Off,
    Run,
    Phase,
    Raw,
}
