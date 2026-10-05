using PzTools.Process.Contracts;
namespace PzTools.Backup.Core.Configuration;

public sealed record BackupOptions(
    int FormatVersion,
    string RepositoryPath,
    IReadOnlyList<BackupSourceOptions> Sources,
    StorageOptions Storage,
    TelemetryOptions Telemetry,
    IReadOnlyList<string>? AlwaysIncludePaths = null,
    SupportedLanguage NameLanguage = SupportedLanguage.English,
    bool FullScanHashComparison = true,
    bool SaveGameBeforeBackup = true,
    BackupTuningOptions? Tuning = null,
    bool GameSaveCountdown = true)
{
    public BackupTuningOptions EffectiveTuning => Tuning ?? new();
}

public sealed record BackupSourceOptions(string Id, string Path);

/// <param name="CompressionLevel">Brotli quality for new data, 1 (fastest) to 11. On a save's files, 3
/// stored 12% less than 1 for 2.5 times the CPU; above 5 the size barely moved while the time kept growing.</param>
public sealed record StorageOptions(
    ChecksumAlgorithm Checksum,
    CompressionAlgorithm Compression,
    bool ContentDeduplication,
    bool VerifyStagedCopies = true,
    int CompressionLevel = StorageOptions.DefaultCompressionLevel)
{
    public const int DefaultCompressionLevel = 3;
    public const int MinimumCompressionLevel = 1;
    public const int MaximumCompressionLevel = 11;
}

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
