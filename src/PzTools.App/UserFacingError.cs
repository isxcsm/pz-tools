namespace PzTools.App;

/// <summary>진단용 예외/프로세스 문자열이 일반 알림에 그대로 노출되지 않게 합니다.</summary>
internal static class UserFacingError
{
    public static string FromException(Exception exception)
    {
        if (exception is UnauthorizedAccessException)
            return Localizer.Get("OperationError.AccessDenied");
        if (exception is FileNotFoundException or DirectoryNotFoundException)
            return Localizer.Get("OperationError.FileMissing");
        foreach (var key in new[]
                 {
                     "HostNotReady", "WindowNotCreated", "StopPlayingToExport",
                     "DeleteSaveUnavailable",
                 })
            if (exception.Message == Localizer.Get(key)) return exception.Message;
        return FromProcessError(exception.Message);
    }

    public static string FromArchiveError(Exception exception) =>
        Contains(exception.Message, "unsafe compression ratio")
            ? Localizer.Get("UnsafeArchiveCompression")
            : Localizer.Get("InvalidArchiveFormat");

    public static string FromProcessError(string? message)
    {
        if (Contains(message, "save-edit-")) return Localizer.Get("RecoveryError.PendingEdit");
        if (Contains(message, "recovery-inventory-")) return Localizer.Get("RecoveryError.Inventory");
        if (Contains(message, "recovery-save-busy")) return Localizer.Get("RecoveryError.Busy");
        if (Contains(message, "recovery-pending-journal")) return Localizer.Get("RecoveryError.Journal");
        if (Contains(message, "recovery-ambiguous-character") || Contains(message, "recovery-singleplayer-only"))
            return Localizer.Get("RecoveryError.Ambiguous");
        if (Contains(message, "recovery-")) return Localizer.Get("RecoveryError.Unsupported");
        if (Contains(message, "could not be captured stably"))
            return Localizer.Get("OperationError.SaveChanged");
        if (Contains(message, "access is denied") || Contains(message, "unauthorized"))
            return Localizer.Get("OperationError.AccessDenied");
        if ((Contains(message, "does not exist") || Contains(message, "not found"))
            && (Contains(message, "file") || Contains(message, "directory")
                || Contains(message, "folder") || Contains(message, "path")))
            return Localizer.Get("OperationError.FileMissing");
        return Localizer.Get("OperationError.Generic");
    }

    private static bool Contains(string? text, string value) =>
        text?.Contains(value, StringComparison.OrdinalIgnoreCase) == true;
}
