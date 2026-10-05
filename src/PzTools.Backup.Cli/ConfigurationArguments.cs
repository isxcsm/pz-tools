using PzTools.Process.Contracts;
using System.Globalization;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Cli;

internal sealed record ConfigurationArguments(
    string RepositoryPath,
    string? ConfigPath,
    BackupOptionOverrides Overrides)
{
    /// <param name="requireRepository">
    /// For a command that writes: a backup creates the backup folder it is given, so one in whatever folder
    /// the command happened to run from is never assumed. Reading the settings may default to it.
    /// </param>
    public static ConfigurationArguments Parse(string[] arguments, bool requireRepository = false)
    {
        string? repositoryPath = null;
        string? configPath = null;
        var sources = new List<BackupSourceOptions>();
        ChecksumAlgorithm? checksum = null;
        CompressionAlgorithm? compression = null;
        bool? contentDeduplication = null;
        bool? verifyStagedCopies = null;
        bool? fullScanHashComparison = null;
        bool? saveGameBeforeBackup = null;
        SupportedLanguage? nameLanguage = null;
        TelemetryMode? telemetryMode = null;
        bool? telemetryEnabled = null;
        int? telemetryBatchSize = null;
        int? telemetryFlushMilliseconds = null;
        int? telemetryRetainRuns = null;
        int? telemetryMaxDatabaseMib = null;
        var alwaysIncludePaths = new List<string>();

        for (var index = 0; index < arguments.Length; index++)
        {
            var name = arguments[index];
            var value = ReadValue(arguments, ref index, name);
            switch (name)
            {
                case "--repository":
                    if (repositoryPath is not null)
                        throw new BackupConfigurationException("Option '--repository' may be specified only once.");
                    repositoryPath = string.IsNullOrWhiteSpace(value)
                        ? throw new BackupConfigurationException("Option '--repository' requires a value.") : value;
                    break;
                case "--config":
                    configPath = value;
                    break;
                case "--source":
                    sources.Add(ParseSource(value));
                    break;
                case "--checksum":
                    checksum = ParseChecksum(value);
                    break;
                case "--compression":
                    compression = ParseCompression(value);
                    break;
                case "--content-deduplication":
                    contentDeduplication = ParseBoolean(value, name);
                    break;
                case "--verify-staged-copies":
                    verifyStagedCopies = ParseBoolean(value, name);
                    break;
                case "--full-scan-hash-comparison":
                    fullScanHashComparison = ParseBoolean(value, name);
                    break;
                case "--save-game-before-backup":
                    saveGameBeforeBackup = ParseBoolean(value, name);
                    break;
                case "--name-language":
                    nameLanguage = LanguageCatalog.TryParse(value, out var parsed) ? parsed
                        : throw new BackupConfigurationException("--name-language must be a supported language code.");
                    break;
                case "--telemetry-mode":
                    telemetryMode = ParseTelemetryMode(value);
                    break;
                case "--telemetry-enabled":
                    telemetryEnabled = ParseBoolean(value, name);
                    break;
                case "--telemetry-batch-size":
                    telemetryBatchSize = ParseInt32(value, name);
                    break;
                case "--telemetry-flush-ms":
                    telemetryFlushMilliseconds = ParseInt32(value, name);
                    break;
                case "--telemetry-retain-runs":
                    telemetryRetainRuns = ParseInt32(value, name);
                    break;
                case "--telemetry-max-database-mib":
                    telemetryMaxDatabaseMib = ParseInt32(value, name);
                    break;
                case "--always-include":
                    alwaysIncludePaths.Add(value);
                    break;
                default:
                    throw new BackupConfigurationException($"Unknown option '{name}'.");
            }
        }

        if (repositoryPath is null && requireRepository)
            throw new BackupConfigurationException("backup requires --repository <path>.");
        return new ConfigurationArguments(
            repositoryPath ?? Environment.CurrentDirectory,
            configPath,
            new BackupOptionOverrides
            {
                Sources = sources.Count == 0 ? null : sources,
                Checksum = checksum,
                Compression = compression,
                ContentDeduplication = contentDeduplication,
                VerifyStagedCopies = verifyStagedCopies,
                FullScanHashComparison = fullScanHashComparison,
                SaveGameBeforeBackup = saveGameBeforeBackup,
                NameLanguage = nameLanguage,
                TelemetryMode = telemetryMode,
                TelemetryEnabled = telemetryEnabled,
                TelemetryBatchSize = telemetryBatchSize,
                TelemetryFlushIntervalMilliseconds = telemetryFlushMilliseconds,
                TelemetryRetainRuns = telemetryRetainRuns,
                TelemetryMaxDatabaseMib = telemetryMaxDatabaseMib,
                AlwaysIncludePaths = alwaysIncludePaths.Count == 0 ? null : alwaysIncludePaths,
            });
    }

    private static string ReadValue(string[] arguments, ref int index, string name)
    {
        if (!name.StartsWith("--", StringComparison.Ordinal))
        {
            throw new BackupConfigurationException($"Expected an option, found '{name}'.");
        }

        if (++index >= arguments.Length)
        {
            throw new BackupConfigurationException($"Option '{name}' requires a value.");
        }

        return arguments[index];
    }

    private static BackupSourceOptions ParseSource(string value)
    {
        var separator = value.IndexOf('=');
        if (separator <= 0 || separator == value.Length - 1)
        {
            throw new BackupConfigurationException(
                "--source must use the form <id>=<path>.");
        }

        return new BackupSourceOptions(value[..separator], value[(separator + 1)..]);
    }

    private static ChecksumAlgorithm ParseChecksum(string value) => value switch
    {
        "auto" => ChecksumAlgorithm.Auto,
        "none" => ChecksumAlgorithm.None,
        "xxhash64" => ChecksumAlgorithm.XxHash64,
        "sha256" => ChecksumAlgorithm.Sha256,
        _ => throw new BackupConfigurationException($"Unknown checksum '{value}'."),
    };

    private static CompressionAlgorithm ParseCompression(string value) => value switch
    {
        "auto" => CompressionAlgorithm.Auto,
        "none" => CompressionAlgorithm.None,
        "brotli" => CompressionAlgorithm.Brotli,
        _ => throw new BackupConfigurationException($"Unknown compression '{value}'."),
    };

    private static TelemetryMode ParseTelemetryMode(string value) => value switch
    {
        "off" => TelemetryMode.Off,
        "run" => TelemetryMode.Run,
        "phase" => TelemetryMode.Phase,
        "raw" => TelemetryMode.Raw,
        _ => throw new BackupConfigurationException($"Unknown telemetry mode '{value}'."),
    };

    private static bool ParseBoolean(string value, string name)
    {
        return bool.TryParse(value, out var result)
            ? result
            : throw new BackupConfigurationException($"{name} must be true or false.");
    }

    private static int ParseInt32(string value, string name)
    {
        return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var result)
            ? result
            : throw new BackupConfigurationException($"{name} must be a 32-bit integer.");
    }
}
