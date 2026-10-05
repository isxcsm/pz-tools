using Microsoft.UI.Xaml;
using PzTools.App.Core;

namespace PzTools.App;

/// <summary>Keep detailed diagnostics out of ordinary notifications and localize the next step.</summary>
internal static class UserFacingError
{
    private static readonly string[] AlreadyLocalizedKeys =
    [
        "HostNotReady", "WindowNotCreated", "StopPlayingToExport", "StopPlayingToHeal", "StopPlayingToRestore", "OperationBusy",
        "DeleteSaveUnavailable",
        "OperationError.Configuration", "OperationError.SettingsBusy", "OperationError.RestartFailed",
        "OperationError.SettingsReverted", "OperationError.SettingsRecoveryFailed",
        "OperationError.AccessDenied", "OperationError.FileMissing", "OperationError.FileInUse",
        "OperationError.DiskFull", "OperationError.RepositoryIncompatible", "OperationError.WorkersMissing",
    ];

    public static string FromException(Exception exception) => NamingTheFile(exception, Localized(exception));

    public static string FromConfigurationException(Exception exception)
    {
        var message = FromException(exception);
        return message == Localizer.Get(UserFacingErrorCatalog.Generic)
            ? Localizer.Get("OperationError.Configuration") : message;
    }

    private static string Localized(Exception exception)
    {
        foreach (var key in AlreadyLocalizedKeys)
        {
            var localized = Localizer.Get(key);
            if (exception.Message == localized) return localized;
            // AggregateException appends inner diagnostic messages to its Message.
            // Show only our known outer message, never that appended technical text.
            if (key == "OperationError.SettingsRecoveryFailed" && exception is AggregateException
                && exception.Message.StartsWith(localized + " (", StringComparison.Ordinal)) return localized;
        }
        return Localizer.Get(UserFacingErrorCatalog.FromException(exception));
    }

    // A settings check that found one file wrong says which, as the configuration folder shows it; the check's own
    // failure stays inside, also when the message was already put in the player's words on the way out.
    private static string NamingTheFile(Exception exception, string message) =>
        message == Localizer.Get("OperationError.Configuration")
        && UserFacingErrorCatalog.InvalidSettingsFile(exception,
            (Application.Current as App)?.Host?.Settings.ConfigurationRoot) is { } file
            ? Localizer.Format("OperationError.ConfigurationFileFormat", file) : message;

    public static string FromArchiveError(Exception exception) =>
        Localizer.Get(UserFacingErrorCatalog.FromArchiveError(exception));

    public static string FromProcessError(string? message) =>
        Localizer.Get(UserFacingErrorCatalog.FromProcessError(message));
}
