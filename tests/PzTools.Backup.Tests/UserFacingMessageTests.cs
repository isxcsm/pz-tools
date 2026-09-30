using System.Globalization;
using System.Text;
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
    [InlineData("backup-data-damaged: Object 1 checksum does not match.", "OperationError.BackupDamaged")]
    [InlineData("The current save changed during export. Stop playing and try again.", "OperationError.ExportSaveChanged")]
    [InlineData("The save is currently in use and cannot be restored.", "OperationError.FileInUse")]
    [InlineData("The save cannot be opened for an exclusive restore.", "OperationError.FileInUse")]
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
    [InlineData("backup-data-damaged-elsewhere")]
    [InlineData("recovery-save-busyness")]
    [InlineData("recovery-new-failure")]
    public void UnknownMessagesAndUserPaths_AreNotTreatedAsDiagnosticCodes(string? message) =>
        Assert.Equal(UserFacingErrorCatalog.Generic, UserFacingErrorCatalog.FromProcessError(message));

    // A logged failure is explained from its code, type and Windows error number; its message may be in
    // whatever language Windows used, as the Korean ones below are.
    [Theory]
    [InlineData(null, "UnauthorizedAccessException", "액세스가 거부되었습니다.", "0x80070005", "OperationError.AccessDenied")]
    [InlineData(null, "IOException", "다른 프로세스가 파일을 사용 중이기 때문에 액세스할 수 없습니다.", "0x80070020", "OperationError.FileInUse")]
    [InlineData(null, "IOException", "디스크 공간이 부족합니다.", "0x80070070", "OperationError.DiskFull")]
    [InlineData(null, "DirectoryNotFoundException", "경로의 일부를 찾을 수 없습니다.", "0x80070003", "OperationError.FileMissing")]
    [InlineData("profile-game-not-running", "GameSaveException", "No game.", "0x80131500", "ProfileError.GameNotRunning")]
    [InlineData("backup-data-damaged", "InvalidDataException", "backup-data-damaged: pack 3", "0x80131501", "OperationError.BackupDamaged")]
    [InlineData("launch-blocked", null, "Windows application control refused to start these components.", null, "OperationError.BlockedByPolicy")]
    [InlineData(null, "InvalidOperationException", "Something unexpected.", "0x80131509", "OperationError.Generic")]
    [InlineData(null, null, "No details.", null, "OperationError.Generic")]
    public void LoggedFailures_AreExplainedWithoutReadingTheirWording(string? code, string? type, string message, string? hResult, string key) =>
        Assert.Equal(key, UserFacingErrorCatalog.FromDiagnostics(code, type, message, hResult));

    // Starting a worker that Windows refuses: a Win32Exception, whose HResult is only E_FAIL and whose number says why.
    [Theory]
    [InlineData("5", "OperationError.AccessDenied")]
    [InlineData("2", "OperationError.FileMissing")]
    [InlineData("4551", "OperationError.BlockedByPolicy")]
    [InlineData("1234", "OperationError.Generic")]
    public void Win32Failures_AreExplainedByTheirOwnNumber(string native, string key) =>
        Assert.Equal(key, UserFacingErrorCatalog.FromDiagnostics("orphan-cleanup-launch-failed", "Win32Exception",
            "액세스가 거부되었습니다.", "0x80004005", native));

    [Fact]
    public void Win32Failures_KeepTheirNumberInTheLog()
    {
        var payload = PzTools.Process.Contracts.FailureTelemetry.FromException("launch-failed", new System.ComponentModel.Win32Exception(5));
        var diagnostics = PzTools.Projections.LogDiagnostics.Parse(payload)!;
        Assert.Equal(("5", "0x80004005"), (diagnostics.NativeErrorCode, diagnostics.HResult));
        Assert.Equal("OperationError.AccessDenied", UserFacingErrorCatalog.FromDiagnostics(diagnostics.FailureCode,
            diagnostics.ExceptionType, diagnostics.Message, diagnostics.HResult, diagnostics.NativeErrorCode));
    }

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
