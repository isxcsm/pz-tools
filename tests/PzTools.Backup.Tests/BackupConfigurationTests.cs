using PzTools.Backup.Core.Configuration;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Tests;

public sealed class BackupConfigurationTests
{
    [Fact]
    public void GameSaveCountdown_DefaultRoundtripAndAppOverrideAreIndependentOfSaving()
    {
        using var temp = new TempDirectory();
        var repository = temp.GetPath("repository");
        var config = temp.GetPath("default.toml");
        const string basic = "format_version = 1\n[[sources]]\nid = 'test'\npath = 'world'\n";
        Assert.True(BackupConfiguration.Parse(basic, repository, config).GameSaveCountdown);
        var options = BackupConfiguration.Parse(basic + "[capture]\ngame_save_countdown = false\n", repository, config);
        Assert.False(options.GameSaveCountdown);
        Assert.True(options.SaveGameBeforeBackup);
        Assert.False(BackupConfiguration.Parse(BackupConfiguration.Serialize(options), repository, config).GameSaveCountdown);
        var appSettings = temp.GetPath("settings.toml");
        File.WriteAllText(appSettings, "[backup]\ngame_save_countdown = true\n");
        Assert.True(BackupConfiguration.Parse(BackupConfiguration.Serialize(options), repository, config,
            appSettingsPath: appSettings).GameSaveCountdown);
        Assert.Throws<BackupConfigurationException>(() => BackupConfiguration.Parse(
            basic + "[capture]\ngame_save_countdown = 'false'\n", repository, config));
    }

    [Fact]
    public void CompressionLevel_DefaultsTo3_RoundTrips_AndStaysInBrotliRange()
    {
        using var temp = new TempDirectory();
        var repository = temp.GetPath("repository");
        var config = temp.GetPath("default.toml");
        const string basic = "format_version = 1\n[[sources]]\nid = 'test'\npath = 'world'\n";
        Assert.Equal(3, BackupConfiguration.Parse(basic, repository, config).Storage.CompressionLevel);
        var options = BackupConfiguration.Parse(basic + "[storage]\ncompression_level = 5\n", repository, config);
        Assert.Equal(5, options.Storage.CompressionLevel);
        Assert.Equal(5, BackupConfiguration.Parse(BackupConfiguration.Serialize(options), repository, config).Storage.CompressionLevel);
        foreach (var invalid in new[] { "0", "12", "'3'" })
            Assert.Throws<BackupConfigurationException>(() => BackupConfiguration.Parse(
                basic + $"[storage]\ncompression_level = {invalid}\n", repository, config));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void GameSavePreference_UsesDefaultTomlAppAndCliPrecedence(bool configured)
    {
        using var temp = new TempDirectory();
        const string basic = "format_version = 1\n[[sources]]\nid = 'main'\npath = 'source'\n";
        var repository = temp.GetPath("repository");
        var config = temp.GetPath("default.toml");
        Assert.True(BackupConfiguration.Parse(basic, repository, config).SaveGameBeforeBackup);
        var text = basic + $"[capture]\nsave_game_before_backup = {configured.ToString().ToLowerInvariant()}\n";
        var options = BackupConfiguration.Parse(text, repository, config);
        Assert.Equal(configured, options.SaveGameBeforeBackup);
        Assert.Equal(configured, BackupConfiguration.Parse(BackupConfiguration.Serialize(options),
            repository, config).SaveGameBeforeBackup);
        var appSettings = temp.GetPath("settings.toml");
        File.WriteAllText(appSettings, "[ui]\nlanguage = 'English'\n");
        Assert.Equal(configured, BackupConfiguration.Parse(text, repository, config,
            appSettingsPath: appSettings).SaveGameBeforeBackup);
        File.WriteAllText(appSettings,
            $"[backup]\nsave_game_before_backup = {(!configured).ToString().ToLowerInvariant()}\n");
        Assert.Equal(!configured, BackupConfiguration.Parse(text, repository, config,
            appSettingsPath: appSettings).SaveGameBeforeBackup);
        Assert.Equal(configured, BackupConfiguration.Parse(text, repository, config,
            new BackupOptionOverrides { SaveGameBeforeBackup = configured }, appSettings).SaveGameBeforeBackup);
        File.WriteAllText(appSettings, "[backup]\nsave_game_before_backup = 'false'\n");
        Assert.Throws<BackupConfigurationException>(() => BackupConfiguration.Parse(text,
            repository, config, appSettingsPath: appSettings));
        Assert.Throws<BackupConfigurationException>(() => BackupConfiguration.Parse(
            basic + "[capture]\nsave_game_before_backup = 0\n", repository, config));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Parse_FullScanHashComparisonRoundTripsAndAllowsExplicitOverride(bool enabled)
    {
        using var temp = new TempDirectory();
        var text = $$"""
            format_version = 1
            [capture]
            full_scan_hash_comparison = {{enabled.ToString().ToLowerInvariant()}}
            [[sources]]
            id = "main"
            path = "source"
            """;
        var repository = temp.GetPath("repository");
        var path = temp.GetPath("config.toml");
        var options = BackupConfiguration.Parse(text, repository, path);
        Assert.Equal(enabled, options.FullScanHashComparison);
        Assert.Equal(enabled, BackupConfiguration.Parse(
            BackupConfiguration.Serialize(options), repository, path).FullScanHashComparison);
        Assert.Equal(!enabled, BackupConfiguration.Parse(text, repository, path,
            new BackupOptionOverrides { FullScanHashComparison = !enabled }).FullScanHashComparison);
        Assert.Throws<BackupConfigurationException>(() => BackupConfiguration.Parse(
            text.Replace($"full_scan_hash_comparison = {enabled.ToString().ToLowerInvariant()}",
                "full_scan_hash_comparison = 1"), repository, path));
    }

    [Fact]
    public void Parse_AppliesDefaultsAndResolvesRelativeSourceFromConfigDirectory()
    {
        using var temp = new TempDirectory();
        var repository = temp.GetPath("repository");
        var config = temp.GetPath("configuration", "custom.toml");

        var options = BackupConfiguration.Parse(
            """
            format_version = 1

            [[sources]]
            id = "main"
            path = "../source"
            """,
            repository,
            config);

        Assert.Equal(Path.GetFullPath(repository), options.RepositoryPath);
        Assert.Equal(temp.GetPath("source"), Assert.Single(options.Sources).Path);
        Assert.Equal(ChecksumAlgorithm.Auto, options.Storage.Checksum);
        Assert.Equal(CompressionAlgorithm.Auto, options.Storage.Compression);
        Assert.False(options.Storage.ContentDeduplication);
        Assert.True(options.Storage.VerifyStagedCopies);
        Assert.True(options.FullScanHashComparison);
        Assert.True(options.Telemetry.Enabled);
        Assert.Equal(TelemetryMode.Raw, options.Telemetry.Mode);
    }

    [Fact]
    public void Load_UsesBackupWorkerIdentityDefault()
    {
        using var temp = new TempDirectory();
        var repository = temp.GetPath("repository");
        var source = temp.GetPath("source");
        var configurationRoot = temp.GetPath("config");
        var configuration = ComponentRuntimePaths.GetIdentityDefaultPath(
            repository, "backup-worker", configurationRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(configuration)!);
        File.WriteAllText(
            configuration,
            $$"""
            format_version = 1

            [[sources]]
            id = "main"
            path = "{{source.Replace('\\', '/')}}"

            [telemetry]
            enabled = false
            """);

        var options = BackupConfiguration.Load(repository,
            configurationRoot: configurationRoot);

        Assert.False(options.Telemetry.Enabled);
        Assert.Equal(Path.GetFullPath(source), Assert.Single(options.Sources).Path);
    }

    [Fact]
    public void Parse_ExplicitFalseAndZeroOverridesToml()
    {
        using var temp = new TempDirectory();

        var options = BackupConfiguration.Parse(
            """
            format_version = 1

            [[sources]]
            id = "main"
            path = "source"

            [storage]
            checksum = "sha256"
            content_deduplication = true
            verify_staged_copies = true

            [telemetry]
            retain_runs = 50
            max_database_mib = 50
            """,
            temp.GetPath("repository"),
            temp.GetPath("configuration", "pztools.toml"),
            new BackupOptionOverrides
            {
                ContentDeduplication = false,
                VerifyStagedCopies = false,
                TelemetryRetainRuns = 0,
                TelemetryMaxDatabaseMib = 0,
            });

        Assert.False(options.Storage.ContentDeduplication);
        Assert.False(options.Storage.VerifyStagedCopies);
        Assert.Equal(0, options.Telemetry.RetainRuns);
        Assert.Equal(0, options.Telemetry.MaxDatabaseMib);
    }

    [Fact]
    public void Parse_RejectsUnknownKeys()
    {
        using var temp = new TempDirectory();

        var exception = Assert.Throws<BackupConfigurationException>(() =>
            BackupConfiguration.Parse(
                """
                format_version = 1
                surprise = true

                [[sources]]
                id = "main"
                path = "source"
                """,
                temp.GetPath("repository"),
                temp.GetPath("configuration", "pztools.toml")));

        Assert.Contains("root.surprise", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Parse_RejectsDeduplicationWithoutStrongIdentity()
    {
        using var temp = new TempDirectory();

        var exception = Assert.Throws<BackupConfigurationException>(() =>
            BackupConfiguration.Parse(
                """
                format_version = 1

                [[sources]]
                id = "main"
                path = "source"

                [storage]
                checksum = "xxhash64"
                content_deduplication = true
                """,
                temp.GetPath("repository"),
                temp.GetPath("configuration", "pztools.toml")));

        Assert.Contains("sha256", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Parse_RejectsRepositoryInsideSource()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("source");

        var exception = Assert.Throws<BackupConfigurationException>(() =>
            BackupConfiguration.Parse(
                $$"""
                format_version = 1

                [[sources]]
                id = "main"
                path = "{{source.Replace("\\", "\\\\", StringComparison.Ordinal)}}"
                """,
                Path.Combine(source, "repository"),
                temp.GetPath("configuration", "pztools.toml")));

        Assert.Contains("overlaps repository", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Serialize_CanBeParsedAgain()
    {
        using var temp = new TempDirectory();
        var repository = temp.GetPath("repository");
        var config = temp.GetPath("configuration", "pztools.toml");
        var original = BackupConfiguration.Parse(
            """
            format_version = 1

            [[sources]]
            id = "main"
            path = "source"

            [storage]
            checksum = "sha256"
            compression = "brotli"
            content_deduplication = true
            verify_staged_copies = false

            [telemetry]
            mode = "phase"
            batch_size = 8
            flush_interval_ms = 10
            retain_runs = 0
            max_database_mib = 0

            [naming]
            language = "English"
            """,
            repository,
            config);

        var serialized = BackupConfiguration.Serialize(original);
        Assert.Equal(SupportedLanguage.English, original.NameLanguage);
        var reparsed = BackupConfiguration.Parse(serialized, repository, config);

        Assert.Equivalent(original, reparsed, strict: true);
    }

    [Theory]
    [InlineData("batch_size", 0)]
    [InlineData("batch_size", 4097)]
    [InlineData("flush_interval_ms", 9)]
    [InlineData("flush_interval_ms", 10001)]
    public void Parse_RejectsTelemetryBufferSettingsOutsideSafeRange(string key, int value)
    {
        using var temp = new TempDirectory();
        var text = $"format_version = 1\n[[sources]]\nid = \"main\"\npath = \"source\"\n"
            + $"[telemetry]\n{key} = {value}\n";

        Assert.Throws<BackupConfigurationException>(() => BackupConfiguration.Parse(
            text, temp.GetPath("repository"), temp.GetPath("config.toml")));
    }
}
