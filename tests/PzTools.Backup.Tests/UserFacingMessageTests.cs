using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using PzTools.App.Core;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Tests;

public sealed class UserFacingMessageTests
{
    public static IEnumerable<object[]> Languages => LanguageCatalog.All.Select(x => new object[] { x.Tag });

    [Theory]
    [InlineData("repository-reset-required: incompatible schema", "OperationError.RepositoryIncompatible")]
    [InlineData("  REPOSITORY-RESET-REQUIRED", "OperationError.RepositoryIncompatible")]
    [InlineData("Application workers are missing. Missing: backup.exe", "OperationError.WorkersMissing")]
    [InlineData("The configured worker directory is incomplete: path", "OperationError.WorkersMissing")]
    [InlineData("Another operation is using this repository", "OperationError.FileInUse")]
    [InlineData("실행 중인 작업과 충돌하여 설정을 적용할 수 없습니다.", "OperationError.SettingsBusy")]
    [InlineData("Cannot start workers: invalid app runtime configuration. invalid value", "OperationError.Configuration")]
    [InlineData("설정 파일을 확인해 주세요: settings.toml", "OperationError.Configuration")]
    [InlineData("The source file could not be captured stably after 3 attempts.", "OperationError.SaveChanged")]
    [InlineData("save-edit-recovery-required: access is denied", "RecoveryError.PendingEdit")]
    [InlineData("recovery-inventory-unavailable: missing candidate", "RecoveryError.Inventory")]
    [InlineData("recovery-save-busy: in use", "RecoveryError.Busy")]
    [InlineData("recovery-pending-journal: pending changes", "RecoveryError.Journal")]
    [InlineData("recovery-ambiguous-character: two characters", "RecoveryError.Ambiguous")]
    [InlineData("recovery-singleplayer-only", "RecoveryError.Ambiguous")]
    [InlineData("recovery-unsupported-format: unknown version", "RecoveryError.Unsupported")]
    [InlineData("recovery-linked-path: unsafe path", "RecoveryError.Unsupported")]
    public void DiagnosticFailures_SelectSpecificActionableResource(string message, string key)
    {
        Assert.Equal(key, UserFacingErrorCatalog.FromProcessError(message));
        Assert.Equal(key, UserFacingErrorCatalog.FromException(new InvalidOperationException(message)));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Unrecognized failure containing confidential details")]
    [InlineData("C:\\games\\save-edit-review\\file.bin")]
    [InlineData("C:\\games\\recovery-save-busy\\file.bin")]
    [InlineData("repository-reset-required-other")]
    [InlineData("recovery-save-busyness")]
    [InlineData("recovery-new-failure")]
    public void UnknownMessagesAndUserPaths_AreNotTreatedAsDiagnosticCodes(string? message) =>
        Assert.Equal(UserFacingErrorCatalog.Generic, UserFacingErrorCatalog.FromProcessError(message));

    [Theory]
    [InlineData(5, "OperationError.AccessDenied")]
    [InlineData(32, "OperationError.FileInUse")]
    [InlineData(33, "OperationError.FileInUse")]
    [InlineData(39, "OperationError.DiskFull")]
    [InlineData(112, "OperationError.DiskFull")]
    [InlineData(1117, "OperationError.Generic")]
    public void Win32IoCodes_AreRecognizedWithoutParsingTranslatedExceptionText(int code, string key)
    {
        foreach (var tag in new[] { "ko-KR", "en-US", "ja-JP", "de-DE" })
        {
            var exception = new IOException($"{tag}: 상세 오류 / 詳細エラー / Fehlerdetails", unchecked((int)0x80070000) | code);
            Assert.Equal(key, UserFacingErrorCatalog.FromException(exception));
            Assert.Equal(key, UserFacingErrorCatalog.FromArchiveError(exception));
        }
    }

    [Fact]
    public void NonWin32Hresult_DoesNotMasqueradeAsFileContention() =>
        Assert.Equal(UserFacingErrorCatalog.Generic,
            UserFacingErrorCatalog.FromException(new IOException("details", unchecked((int)0x80130020))));

    [Fact]
    public void ArchiveErrors_PreserveAccessFailureMissingFileAndCancellation()
    {
        Assert.Equal("OperationError.AccessDenied", UserFacingErrorCatalog.FromArchiveError(new UnauthorizedAccessException("권한 없음")));
        Assert.Equal("OperationError.FileMissing", UserFacingErrorCatalog.FromArchiveError(new FileNotFoundException("없음")));
        Assert.Equal("OperationError.FileMissing", UserFacingErrorCatalog.FromException(new DirectoryNotFoundException("없음")));
        Assert.Equal("OperationCancelled", UserFacingErrorCatalog.FromArchiveError(new OperationCanceledException()));
        Assert.Equal("InvalidArchiveFormat", UserFacingErrorCatalog.FromArchiveError(new InvalidDataException("Invalid header")));
        Assert.Equal("UnsafeArchiveCompression", UserFacingErrorCatalog.FromArchiveError(new InvalidDataException("unsafe compression ratio")));
        Assert.Equal(UserFacingErrorCatalog.Generic, UserFacingErrorCatalog.FromArchiveError(new IOException("Unknown read failure")));
    }

    [Fact]
    public void ContextOverridesInnerError_AndMultipleFailuresDoNotInviteBlindRetry()
    {
        var denied = new UnauthorizedAccessException("access is denied");
        Assert.Equal("OperationError.AccessDenied", UserFacingErrorCatalog.FromException(new InvalidOperationException("wrapped", denied)));
        Assert.Equal("RecoveryError.PendingEdit", UserFacingErrorCatalog.FromException(new InvalidOperationException("save-edit-pending", denied)));
        Assert.Equal(UserFacingErrorCatalog.Generic, UserFacingErrorCatalog.FromException(new AggregateException(denied, new IOException())));
        Assert.Equal("OperationError.Configuration", UserFacingErrorCatalog.FromConfigurationError(new InvalidDataException("ui.language value is invalid")));
        Assert.Equal("OperationError.AccessDenied", UserFacingErrorCatalog.FromConfigurationError(denied));
        Assert.Equal("OperationError.WorkersMissing", UserFacingErrorCatalog.FromException(
            new DirectoryNotFoundException("The configured worker directory is incomplete: private path")));
    }

    [Theory]
    [MemberData(nameof(Languages))]
    public void EveryNewMessageExists_FormatsAndKeepsBackupDistinctFromGameSave(string tag)
    {
        var resources = ReadResources(tag);
        var language = LanguageCatalog.All.Single(x => x.Tag == tag);
        foreach (var key in new[] { "OperationError.FileInUse", "OperationError.DiskFull", "OperationError.WorkersMissing",
            "OperationError.RepositoryIncompatible", "OperationError.SettingsBusy", "OperationError.Configuration",
            "OperationError.RestartFailed", "OperationError.SettingsReverted", "OperationError.SettingsRecoveryFailed",
            "SettingEnabled", "SettingDisabled", "BackupDeduplicationPhase", "LogPhase.deduplication" })
        {
            Assert.False(string.IsNullOrWhiteSpace(resources[key]), $"{tag}/{key}");
            Assert.Equal(0, CompositeFormat.Parse(resources[key]).MinimumArgumentCount);
        }
        Assert.NotEqual(resources["SettingEnabled"], resources["SettingDisabled"]);
        Assert.Equal(language.AutomaticBackupName, resources["AutomaticSaveLabel"]);
        Assert.Equal(resources["BackupDeduplicationPhase"], resources["LogPhase.deduplication"]);
        Assert.NotEqual(language.SaveCompleted, language.AutomaticBackupName);
        Assert.Equal(1, CompositeFormat.Parse(language.SaveCountdown).MinimumArgumentCount);
        Assert.Equal(2, CompositeFormat.Parse(resources["ConfirmRestoreBody"]).MinimumArgumentCount);
        var rendered = string.Format(CultureInfo.GetCultureInfo(tag), resources["ConfirmRestoreBody"], "SAVE_MARKER", "BACKUP_MARKER");
        Assert.Contains("SAVE_MARKER", rendered);
        Assert.Contains("BACKUP_MARKER", rendered);
    }

    [Theory]
    [InlineData("en-US", "will be lost", "reopen PZ Tools", "will roll back automatically", "will retry automatically")]
    [InlineData("ko-KR", "사라집니다", "PZ Tools", "자동으로 되돌", "자동으로 재시도")]
    public void SafetyCopy_DoesNotPromiseAutomaticRecoveryOrRetry(string tag, string loss, string reopen, string rollback, string retry)
    {
        var resources = ReadResources(tag);
        Assert.Contains(loss, resources["ConfirmRestoreBody"]);
        Assert.Contains(reopen, resources["ConfirmRestoreBody"]);
        Assert.DoesNotContain(rollback, resources["ConfirmRestoreBody"]);
        Assert.DoesNotContain(retry, resources["OperationError.SaveChanged"]);
    }

    [Fact]
    public void SwitchLabelsAndPageCulture_AreRefreshedWhenAppLanguageChanges()
    {
        var app = Path.Combine(Root(), "src", "PzTools.App");
        var settings = File.ReadAllText(Path.Combine(app, "SettingsPage.xaml.cs"));
        foreach (var name in new[] { "SystemTrayToggle", "GameSaveToggle", "GameSaveCountdownToggle", "DeathBackupToggle" })
            Assert.Contains(name, settings[settings.IndexOf("foreach (var toggle", StringComparison.Ordinal)..]);
        Assert.Contains("toggle.OnContent = Localizer.Get(\"SettingEnabled\")", settings);
        Assert.Contains("toggle.OffContent = Localizer.Get(\"SettingDisabled\")", settings);
        foreach (var page in new[] { "SettingsPage", "MainWindowShell", "LogsPage" })
            Assert.Contains("Language = Localizer.Culture.Name;", File.ReadAllText(Path.Combine(app, page + ".xaml.cs")));
        Assert.DoesNotContain("한국어 또는 영어", File.ReadAllText(Path.Combine(app, "SettingsPage.xaml")));
    }

    [Fact]
    public void LiteralResourceReferencesResolveInEverySupportedLocale()
    {
        var app = Path.Combine(Root(), "src", "PzTools.App");
        var keys = Directory.EnumerateFiles(app, "*.cs").SelectMany(path =>
            Regex.Matches(File.ReadAllText(path), "Localizer\\.(?:Get|Format)\\(\"([^\"]+)\"")
                .Select(match => match.Groups[1].Value)).Distinct().ToArray();
        foreach (var language in LanguageCatalog.All)
        {
            var resources = ReadResources(language.Tag);
            foreach (var key in keys) Assert.True(resources.ContainsKey(key), $"{language.Tag}/{key}");
        }
    }

    private static Dictionary<string, string> ReadResources(string tag) => XDocument.Load(
        Path.Combine(Root(), "src", "PzTools.App", "Strings", tag, "Resources.resw")).Root!.Elements("data")
        .ToDictionary(x => x.Attribute("name")!.Value, x => x.Element("value")!.Value);

    private static string Root()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "PzTools.sln"))) return dir.FullName;
        throw new DirectoryNotFoundException("Repository source is required for localization tests.");
    }
}
