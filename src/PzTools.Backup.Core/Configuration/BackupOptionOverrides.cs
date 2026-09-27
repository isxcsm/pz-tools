using PzTools.Process.Contracts;
namespace PzTools.Backup.Core.Configuration;

public sealed record BackupOptionOverrides
{
    public IReadOnlyList<BackupSourceOptions>? Sources { get; init; }

    public ChecksumAlgorithm? Checksum { get; init; }

    public CompressionAlgorithm? Compression { get; init; }

    public bool? ContentDeduplication { get; init; }

    public bool? VerifyStagedCopies { get; init; }
    public SupportedLanguage? NameLanguage { get; init; }

    public TelemetryMode? TelemetryMode { get; init; }

    public bool? TelemetryEnabled { get; init; }

    public int? TelemetryBatchSize { get; init; }

    public int? TelemetryFlushIntervalMilliseconds { get; init; }

    public int? TelemetryRetainRuns { get; init; }

    public int? TelemetryMaxDatabaseMib { get; init; }

    public IReadOnlyList<string>? AlwaysIncludePaths { get; init; }

    public bool? FullScanHashComparison { get; init; }
    public bool? SaveGameBeforeBackup { get; init; }
}
