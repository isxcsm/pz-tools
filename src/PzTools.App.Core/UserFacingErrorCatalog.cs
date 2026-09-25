namespace PzTools.App.Core;

/// <summary>Maps diagnostic failures to resource keys, without displaying raw paths or exception text.</summary>
public static class UserFacingErrorCatalog
{
    public const string Generic = "OperationError.Generic";

    public static string FromException(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        if (exception is OperationCanceledException) return "OperationCancelled";
        if (exception is AggregateException) return Generic;
        // Preserve the outer operation's meaning before looking at a nested I/O error.
        // In particular, pending edits must never invite the user to load the save.
        var messageKey = FromProcessError(exception.Message);
        if (messageKey != Generic) return messageKey;
        if (exception is UnauthorizedAccessException) return "OperationError.AccessDenied";
        if (exception is FileNotFoundException or DirectoryNotFoundException) return "OperationError.FileMissing";
        if (exception is IOException && ((uint)exception.HResult & 0xffff0000U) == 0x80070000U)
        {
            var key = (exception.HResult & 0xffff) switch
            {
                5 => "OperationError.AccessDenied",
                32 or 33 => "OperationError.FileInUse",
                39 or 112 => "OperationError.DiskFull",
                _ => Generic,
            };
            if (key != Generic) return key;
        }
        // Multi-error operations can have partial effects; do not pick one inner
        // error and imply that retrying the entire operation is safe.
        if (exception.InnerException is { } inner)
            return FromException(inner);
        return Generic;
    }

    public static string FromArchiveError(Exception exception)
    {
        var key = FromException(exception);
        if (key != Generic) return key; // Missing files/permissions are not archive corruption.
        if (Contains(exception.Message, "unsafe compression ratio")) return "UnsafeArchiveCompression";
        return exception is InvalidDataException or FormatException ? "InvalidArchiveFormat" : Generic;
    }

    public static string FromConfigurationError(Exception exception)
    {
        var key = FromException(exception);
        return key == Generic ? "OperationError.Configuration" : key;
    }

    public static string FromProcessError(string? message)
    {
        if (HasCodePrefix(message, "save-edit-")) return "RecoveryError.PendingEdit";
        if (HasCodePrefix(message, "recovery-inventory-")) return "RecoveryError.Inventory";
        if (HasCodePrefix(message, "recovery-save-busy")) return "RecoveryError.Busy";
        if (HasCodePrefix(message, "recovery-pending-journal")) return "RecoveryError.Journal";
        if (HasCodePrefix(message, "recovery-ambiguous-character") || HasCodePrefix(message, "recovery-singleplayer-only"))
            return "RecoveryError.Ambiguous";
        if (HasCodePrefix(message, "recovery-invalid-database") || HasCodePrefix(message, "recovery-linked-path")
            || HasCodePrefix(message, "recovery-no-character") || HasCodePrefix(message, "recovery-validation-failed")
            || HasCodePrefix(message, "recovery-unsupported-format") || HasCodePrefix(message, "recovery-unsupported-dictionary"))
            return "RecoveryError.Unsupported";
        if (HasCodePrefix(message, "repository-reset-required")) return "OperationError.RepositoryIncompatible";
        if (Starts(message, "Application workers are missing.") || Starts(message, "The configured worker directory is incomplete:"))
            return "OperationError.WorkersMissing";
        if (Starts(message, "Another operation is using ")) return "OperationError.FileInUse";
        if (Starts(message, "실행 중인 작업과 충돌하여 설정을 적용할 수 없습니다.")) return "OperationError.SettingsBusy";
        if (Starts(message, "Cannot start workers: invalid app runtime configuration.") || Starts(message, "설정 파일을 확인해 주세요:"))
            return "OperationError.Configuration";
        if (Contains(message, "could not be captured stably")) return "OperationError.SaveChanged";
        if (Contains(message, "access is denied") || Contains(message, "unauthorized")) return "OperationError.AccessDenied";
        if ((Contains(message, "does not exist") || Contains(message, "not found"))
            && (Contains(message, "file") || Contains(message, "directory") || Contains(message, "folder") || Contains(message, "path")))
            return "OperationError.FileMissing";
        return Generic;
    }

    // Codes are diagnostic prefixes, not arbitrary substrings of user-chosen paths.
    // Existing worker messages begin with these codes, optionally after whitespace.
    private static bool HasCodePrefix(string? message, string prefix)
    {
        var value = message?.TrimStart();
        if (value is null || !value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return false;
        return prefix.EndsWith('-') || value.Length == prefix.Length
            || value[prefix.Length] is ':' or ' ' or '\r' or '\n';
    }
    private static bool Starts(string? text, string value) => text?.TrimStart().StartsWith(value, StringComparison.OrdinalIgnoreCase) == true;
    private static bool Contains(string? text, string value) => text?.Contains(value, StringComparison.OrdinalIgnoreCase) == true;
}
