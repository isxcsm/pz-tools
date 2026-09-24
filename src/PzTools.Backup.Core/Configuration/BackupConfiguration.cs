using Tomlyn;
using Tomlyn.Model;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Core.Configuration;

public static class BackupConfiguration
{
    public const int CurrentFormatVersion = 1;
    private static readonly StorageOptions DefaultStorage = new(
        ChecksumAlgorithm.Auto,
        CompressionAlgorithm.Auto,
        ContentDeduplication: false);

    private static readonly TelemetryOptions DefaultTelemetry = new(
        TelemetryMode.Raw,
        BatchSize: 256,
        FlushIntervalMilliseconds: 250,
        RetainRuns: 1_000,
        MaxDatabaseMib: 256);

    public static BackupOptions Load(
        string repositoryPath,
        string? configPath = null,
        BackupOptionOverrides? overrides = null,
        string? appSettingsPath = null,
        string? configurationRoot = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);

        var absoluteRepositoryPath = Path.GetFullPath(repositoryPath);
        var absoluteConfigPath = Path.GetFullPath(configPath
            ?? ComponentRuntimePaths.GetIdentityDefaultPath(
                absoluteRepositoryPath, "backup-worker", configurationRoot));

        string text;
        try
        {
            text = File.ReadAllText(absoluteConfigPath);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new BackupConfigurationException(
                $"Cannot read configuration '{absoluteConfigPath}'.",
                exception);
        }

        return Parse(text, absoluteRepositoryPath, absoluteConfigPath, overrides,
            appSettingsPath);
    }

    public static BackupOptions Parse(
        string text,
        string repositoryPath,
        string configPath,
        BackupOptionOverrides? overrides = null,
        string? appSettingsPath = null)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(configPath);

        TomlTable root;
        try
        {
            root = TomlSerializer.Deserialize<TomlTable>(text)
                ?? throw new BackupConfigurationException("The TOML document is empty.");
        }
        catch (TomlException exception)
        {
            throw new BackupConfigurationException("Invalid TOML configuration.", exception);
        }

        EnsureOnlyKeys(root, ["format_version", "sources", "capture", "storage", "telemetry", "naming", "runtime"], "root");
        if (root.TryGetValue("runtime", out var runtimeValue))
        {
            if (runtimeValue is not TomlTable runtimeTable)
                throw new BackupConfigurationException("runtime must be a table.");
            EnsureOnlyKeys(runtimeTable, new BackupTuningOptions().ToTable().Keys.ToArray(), "runtime");
        }
        BackupTuningOptions tuning;
        try { tuning = BackupTuningOptions.Read(ComponentConfiguration.Parse(text)); }
        catch (InvalidDataException exception) { throw new BackupConfigurationException(exception.Message, exception); }

        var formatVersion = GetRequiredInt32(root, "format_version", "root");
        if (formatVersion != CurrentFormatVersion)
        {
            throw new BackupConfigurationException(
                $"Unsupported configuration format_version {formatVersion}; expected {CurrentFormatVersion}.");
        }

        var configDirectory = Path.GetDirectoryName(Path.GetFullPath(configPath))
            ?? throw new BackupConfigurationException("The configuration path has no parent directory.");
        var sources = ParseSources(root, configDirectory);
        var storage = ParseStorage(root);
        var telemetry = ParseTelemetry(root);
        var alwaysInclude = ParseAlwaysInclude(root);
        var fullScanHashComparison = root.TryGetValue("capture", out var captureValue)
            && captureValue is TomlTable captureTable
                ? GetBoolean(captureTable, "full_scan_hash_comparison", true, "capture")
                : true;
        var nameLanguage = ParseNameLanguage(root);
        var saveGameBeforeBackup = root.TryGetValue("capture", out var gameCaptureValue)
            && gameCaptureValue is TomlTable gameCapture
                ? GetBoolean(gameCapture, "save_game_before_backup", true, "capture") : true;
        var gameSaveCountdown = gameCaptureValue is TomlTable noticeCapture
            ? GetBoolean(noticeCapture, "game_save_countdown", true, "capture") : true;
        if (appSettingsPath is not null && File.Exists(appSettingsPath))
        {
            var app = TomlSerializer.Deserialize<TomlTable>(File.ReadAllText(appSettingsPath))
                ?? throw new BackupConfigurationException("The app settings document is empty.");
            if (app.TryGetValue("backup", out var backupValue) && backupValue is TomlTable backup)
            {
                saveGameBeforeBackup = GetBoolean(backup, "save_game_before_backup", saveGameBeforeBackup, "backup");
                gameSaveCountdown = GetBoolean(backup, "game_save_countdown", gameSaveCountdown, "backup");
            }
            if (app.TryGetValue("ui", out var uiValue) && uiValue is TomlTable ui
                && ui.TryGetValue("language", out var languageValue))
            {
                nameLanguage = languageValue is string language
                    && LanguageCatalog.TryParse(language, out var parsed)
                    ? parsed
                    : throw new BackupConfigurationException("ui.language must be a supported language code.");
            }
        }

        if (overrides is not null)
        {
            sources = overrides.Sources is null
                ? sources
                : NormalizeSources(overrides.Sources, Environment.CurrentDirectory);
            storage = storage with
            {
                Checksum = overrides.Checksum ?? storage.Checksum,
                Compression = overrides.Compression ?? storage.Compression,
                ContentDeduplication = overrides.ContentDeduplication
                    ?? storage.ContentDeduplication,
                VerifyStagedCopies = overrides.VerifyStagedCopies
                    ?? storage.VerifyStagedCopies,
            };
            telemetry = telemetry with
            {
                Enabled = overrides.TelemetryEnabled ?? telemetry.Enabled,
                Mode = overrides.TelemetryMode ?? telemetry.Mode,
                BatchSize = overrides.TelemetryBatchSize ?? telemetry.BatchSize,
                FlushIntervalMilliseconds = overrides.TelemetryFlushIntervalMilliseconds
                    ?? telemetry.FlushIntervalMilliseconds,
                RetainRuns = overrides.TelemetryRetainRuns ?? telemetry.RetainRuns,
                MaxDatabaseMib = overrides.TelemetryMaxDatabaseMib
                    ?? telemetry.MaxDatabaseMib,
            };
            alwaysInclude = overrides.AlwaysIncludePaths ?? alwaysInclude;
            fullScanHashComparison = overrides.FullScanHashComparison ?? fullScanHashComparison;
            saveGameBeforeBackup = overrides.SaveGameBeforeBackup ?? saveGameBeforeBackup;
            nameLanguage = overrides.NameLanguage ?? nameLanguage;
        }

        var options = new BackupOptions(
            formatVersion,
            Path.GetFullPath(repositoryPath),
            sources,
            storage,
            telemetry,
            NormalizeAlwaysInclude(alwaysInclude),
            nameLanguage,
            fullScanHashComparison,
            saveGameBeforeBackup,
            tuning,
            gameSaveCountdown);
        Validate(options);
        return options;
    }

    public static string Serialize(BackupOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        var sourceTables = new TomlTableArray();
        foreach (var source in options.Sources)
        {
            sourceTables.Add(new TomlTable
            {
                ["id"] = source.Id,
                ["path"] = source.Path,
            });
        }

        var alwaysInclude = new TomlArray();
        foreach (var path in options.AlwaysIncludePaths ?? []) alwaysInclude.Add(path);
        var root = new TomlTable
        {
            ["format_version"] = options.FormatVersion,
            ["sources"] = sourceTables,
            ["runtime"] = options.EffectiveTuning.ToTable(),
            ["capture"] = new TomlTable
            {
                ["always_include"] = alwaysInclude,
                ["full_scan_hash_comparison"] = options.FullScanHashComparison,
                ["save_game_before_backup"] = options.SaveGameBeforeBackup,
                ["game_save_countdown"] = options.GameSaveCountdown,
            },
            ["storage"] = new TomlTable
            {
                ["checksum"] = ToConfigName(options.Storage.Checksum),
                ["compression"] = ToConfigName(options.Storage.Compression),
                ["content_deduplication"] = options.Storage.ContentDeduplication,
                ["verify_staged_copies"] = options.Storage.VerifyStagedCopies,
            },
            ["telemetry"] = new TomlTable
            {
                ["enabled"] = options.Telemetry.Enabled,
                ["mode"] = ToConfigName(options.Telemetry.Mode),
                ["batch_size"] = options.Telemetry.BatchSize,
                ["flush_interval_ms"] = options.Telemetry.FlushIntervalMilliseconds,
                ["retain_runs"] = options.Telemetry.RetainRuns,
                ["max_database_mib"] = options.Telemetry.MaxDatabaseMib,
            },
            ["naming"] = new TomlTable
            {
                ["language"] = LanguageCatalog.Get(options.NameLanguage).Tag,
            },
        };

        return TomlSerializer.Serialize(root);
    }

    public static void Validate(BackupOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        try { options.EffectiveTuning.Validate(); }
        catch (InvalidDataException exception) { throw new BackupConfigurationException(exception.Message, exception); }

        if (options.FormatVersion != CurrentFormatVersion)
        {
            throw new BackupConfigurationException(
                $"Unsupported configuration format_version {options.FormatVersion}.");
        }

        if (!Enum.IsDefined(options.NameLanguage))
            throw new BackupConfigurationException("Unsupported backup naming language.");

        if (options.Sources.Count == 0)
        {
            throw new BackupConfigurationException("At least one source is required.");
        }

        if (options.Storage.ContentDeduplication
            && options.Storage.Checksum != ChecksumAlgorithm.Sha256)
        {
            throw new BackupConfigurationException(
                "Content deduplication requires checksum = 'sha256'.");
        }

        if (options.Telemetry.BatchSize is < 1 or > 4096)
            throw new BackupConfigurationException(
                "telemetry.batch_size must be between 1 and 4096.");
        if (options.Telemetry.FlushIntervalMilliseconds is < 10 or > 10000)
            throw new BackupConfigurationException(
                "telemetry.flush_interval_ms must be between 10 and 10000.");
        ValidateNonNegative(options.Telemetry.RetainRuns, "telemetry.retain_runs");
        ValidateNonNegative(
            options.Telemetry.MaxDatabaseMib,
            "telemetry.max_database_mib");
        _ = NormalizeAlwaysInclude(options.AlwaysIncludePaths ?? []);

        var sourceIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < options.Sources.Count; index++)
        {
            var source = options.Sources[index];
            if (string.IsNullOrWhiteSpace(source.Id))
            {
                throw new BackupConfigurationException($"sources[{index}].id cannot be empty.");
            }

            if (!sourceIds.Add(source.Id))
            {
                throw new BackupConfigurationException($"Duplicate source id '{source.Id}'.");
            }

            if (!Path.IsPathFullyQualified(source.Path))
            {
                throw new BackupConfigurationException(
                    $"Source '{source.Id}' does not have an absolute path.");
            }

            if (PathsOverlap(options.RepositoryPath, source.Path))
            {
                throw new BackupConfigurationException(
                    $"Source '{source.Id}' overlaps repository '{options.RepositoryPath}'.");
            }
        }

        for (var left = 0; left < options.Sources.Count; left++)
        {
            for (var right = left + 1; right < options.Sources.Count; right++)
            {
                if (PathsOverlap(options.Sources[left].Path, options.Sources[right].Path))
                {
                    throw new BackupConfigurationException(
                        $"Sources '{options.Sources[left].Id}' and "
                        + $"'{options.Sources[right].Id}' overlap.");
                }
            }
        }
    }

    private static IReadOnlyList<string> ParseAlwaysInclude(TomlTable root)
    {
        if (!root.TryGetValue("capture", out var value)) return ["players.db", "vehicles.db", "thumb.png"];
        if (value is not TomlTable capture)
            throw new BackupConfigurationException("capture must be a table.");
        EnsureOnlyKeys(capture, ["always_include", "full_scan_hash_comparison", "save_game_before_backup", "game_save_countdown"], "capture");
        if (!capture.TryGetValue("always_include", out var paths))
            return ["players.db", "vehicles.db", "thumb.png"];
        if (paths is not TomlArray array || array.Any(item => item is not string))
            throw new BackupConfigurationException(
                "capture.always_include must be an array of strings.");
        return array.Cast<string>().ToArray();
    }

    private static IReadOnlyList<string> NormalizeAlwaysInclude(IEnumerable<string> values)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in values)
        {
            if (string.IsNullOrWhiteSpace(value))
                throw new BackupConfigurationException(
                    "capture.always_include cannot contain an empty path.");
            string normalized;
            try { normalized = PzTools.Backup.Core.BackupPath.NormalizeRelative(value); }
            catch (ArgumentException exception)
            {
                throw new BackupConfigurationException(
                    $"Invalid capture.always_include path '{value}'.", exception);
            }
            result.Add(normalized);
        }
        return result.Order(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static IReadOnlyList<BackupSourceOptions> ParseSources(
        TomlTable root,
        string configDirectory)
    {
        if (!root.TryGetValue("sources", out var value) || value is not TomlTableArray sourceTables)
        {
            return [];
        }

        var sources = new List<BackupSourceOptions>(sourceTables.Count);
        for (var index = 0; index < sourceTables.Count; index++)
        {
            var table = sourceTables[index];
            EnsureOnlyKeys(table, ["id", "path"], $"sources[{index}]");
            sources.Add(new BackupSourceOptions(
                GetRequiredString(table, "id", $"sources[{index}]"),
                GetRequiredString(table, "path", $"sources[{index}]")));
        }

        return NormalizeSources(sources, configDirectory);
    }

    private static IReadOnlyList<BackupSourceOptions> NormalizeSources(
        IReadOnlyList<BackupSourceOptions> sources,
        string baseDirectory)
    {
        return sources
            .Select(source => source with
            {
                Path = Path.GetFullPath(source.Path, baseDirectory),
            })
            .ToArray();
    }

    private static StorageOptions ParseStorage(TomlTable root)
    {
        if (!root.TryGetValue("storage", out var value))
        {
            return DefaultStorage;
        }

        if (value is not TomlTable table)
        {
            throw new BackupConfigurationException("storage must be a TOML table.");
        }

        EnsureOnlyKeys(
            table,
            ["checksum", "compression", "content_deduplication", "verify_staged_copies"],
            "storage");
        return new StorageOptions(
            GetEnum(table, "checksum", DefaultStorage.Checksum, ParseChecksum),
            GetEnum(table, "compression", DefaultStorage.Compression, ParseCompression),
            GetBoolean(
                table,
                "content_deduplication",
                DefaultStorage.ContentDeduplication,
                "storage"),
            GetBoolean(
                table,
                "verify_staged_copies",
                DefaultStorage.VerifyStagedCopies,
                "storage"));
    }

    private static TelemetryOptions ParseTelemetry(TomlTable root)
    {
        if (!root.TryGetValue("telemetry", out var value))
        {
            return DefaultTelemetry;
        }

        if (value is not TomlTable table)
        {
            throw new BackupConfigurationException("telemetry must be a TOML table.");
        }

        EnsureOnlyKeys(
            table,
            ["enabled", "mode", "batch_size", "flush_interval_ms", "retain_runs", "max_database_mib"],
            "telemetry");
        return new TelemetryOptions(
            GetEnum(table, "mode", DefaultTelemetry.Mode, ParseTelemetryMode),
            GetInt32(table, "batch_size", DefaultTelemetry.BatchSize, "telemetry"),
            GetInt32(
                table,
                "flush_interval_ms",
                DefaultTelemetry.FlushIntervalMilliseconds,
                "telemetry"),
            GetInt32(table, "retain_runs", DefaultTelemetry.RetainRuns, "telemetry"),
            GetInt32(
                table,
                "max_database_mib",
                DefaultTelemetry.MaxDatabaseMib,
                "telemetry"),
            GetBoolean(table, "enabled", DefaultTelemetry.Enabled, "telemetry"));
    }

    private static SupportedLanguage ParseNameLanguage(TomlTable root)
    {
        if (!root.TryGetValue("naming", out var value)) return SupportedLanguage.Korean;
        if (value is not TomlTable table)
            throw new BackupConfigurationException("naming must be a TOML table.");
        EnsureOnlyKeys(table, ["language"], "naming");
        return GetEnum(table, "language", SupportedLanguage.Korean,
            text => LanguageCatalog.TryParse(text, out var parsed)
                ? parsed
                : throw new BackupConfigurationException($"Unknown naming language '{text}'."));
    }

    private static TEnum GetEnum<TEnum>(
        TomlTable table,
        string key,
        TEnum defaultValue,
        Func<string, TEnum> parser)
        where TEnum : struct, Enum
    {
        if (!table.TryGetValue(key, out var value))
        {
            return defaultValue;
        }

        if (value is not string text)
        {
            throw new BackupConfigurationException($"{key} must be a string.");
        }

        return parser(text);
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

    private static string ToConfigName<TEnum>(TEnum value)
        where TEnum : struct, Enum
    {
        return value switch
        {
            ChecksumAlgorithm.XxHash64 => "xxhash64",
            ChecksumAlgorithm.Sha256 => "sha256",
            TelemetryMode.Run => "run",
            _ => value.ToString().ToLowerInvariant(),
        };
    }

    private static string GetRequiredString(TomlTable table, string key, string context)
    {
        if (!table.TryGetValue(key, out var value) || value is not string text)
        {
            throw new BackupConfigurationException($"{context}.{key} must be a string.");
        }

        return text;
    }

    private static int GetRequiredInt32(TomlTable table, string key, string context)
    {
        if (!table.TryGetValue(key, out var value))
        {
            throw new BackupConfigurationException($"{context}.{key} is required.");
        }

        return ConvertToInt32(value, $"{context}.{key}");
    }

    private static int GetInt32(
        TomlTable table,
        string key,
        int defaultValue,
        string context)
    {
        return table.TryGetValue(key, out var value)
            ? ConvertToInt32(value, $"{context}.{key}")
            : defaultValue;
    }

    private static int ConvertToInt32(object? value, string name)
    {
        if (value is long number && number is >= int.MinValue and <= int.MaxValue)
        {
            return (int)number;
        }

        throw new BackupConfigurationException($"{name} must be a 32-bit integer.");
    }

    private static bool GetBoolean(
        TomlTable table,
        string key,
        bool defaultValue,
        string context)
    {
        if (!table.TryGetValue(key, out var value))
        {
            return defaultValue;
        }

        if (value is not bool result)
        {
            throw new BackupConfigurationException($"{context}.{key} must be a boolean.");
        }

        return result;
    }

    private static void EnsureOnlyKeys(
        TomlTable table,
        string[] allowed,
        string context)
    {
        foreach (var key in table.Keys)
        {
            if (!allowed.Contains(key))
            {
                throw new BackupConfigurationException(
                    $"Unknown configuration key '{context}.{key}'.");
            }
        }
    }

    private static bool PathsOverlap(string left, string right)
    {
        var normalizedLeft = Path.TrimEndingDirectorySeparator(Path.GetFullPath(left));
        var normalizedRight = Path.TrimEndingDirectorySeparator(Path.GetFullPath(right));
        return IsSameOrChild(normalizedLeft, normalizedRight)
            || IsSameOrChild(normalizedRight, normalizedLeft);
    }

    private static bool IsSameOrChild(string candidate, string parent)
    {
        if (StringComparer.OrdinalIgnoreCase.Equals(candidate, parent))
        {
            return true;
        }

        return candidate.StartsWith(
            parent + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase);
    }

    private static void ValidateNonNegative(int value, string name)
    {
        if (value < 0)
        {
            throw new BackupConfigurationException($"{name} cannot be negative.");
        }
    }
}
