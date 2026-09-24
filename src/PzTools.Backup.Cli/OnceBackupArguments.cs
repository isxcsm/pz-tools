using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Cli;

internal sealed record OnceBackupArguments(
    string SourceId,
    long? RunIndex,
    long? Revision,
    string? ControlDatabasePath,
    bool SaveGame,
    ConfigurationArguments Configuration,
    DateTimeOffset? ScheduledUtc = null)
{
    public static OnceBackupArguments Parse(string[] arguments)
    {
        string? sourceId = null;
        long? runIndex = null;
        long? revision = null;
        string? controlDatabasePath = null;
        var saveGame = false;
        DateTimeOffset? scheduledUtc = null;
        var configurationArguments = new List<string>();
        for (var index = 0; index < arguments.Length; index++)
        {
            if (arguments[index] == "--scheduled-utc")
            {
                if (scheduledUtc is not null || ++index >= arguments.Length
                    || !DateTimeOffset.TryParseExact(arguments[index], "O", System.Globalization.CultureInfo.InvariantCulture,
                        System.Globalization.DateTimeStyles.None, out var due))
                    throw new BackupConfigurationException("--scheduled-utc requires one ISO 8601 timestamp.");
                scheduledUtc = due;
                continue;
            }
            if (arguments[index] == "--save-game")
            {
                if (saveGame) throw new BackupConfigurationException("--save-game may be specified only once.");
                saveGame = true;
                continue;
            }
            if (arguments[index] == "--source-id")
            {
                if (sourceId is not null)
                {
                    throw new BackupConfigurationException("--source-id may be specified only once.");
                }

                if (++index >= arguments.Length || string.IsNullOrWhiteSpace(arguments[index]))
                {
                    throw new BackupConfigurationException("--source-id requires a value.");
                }

                sourceId = arguments[index];
                continue;
            }

            if (arguments[index] is "--run-index" or "--revision")
            {
                var option = arguments[index];
                if (++index >= arguments.Length
                    || !long.TryParse(arguments[index], out var value)
                    || value <= 0)
                {
                    throw new BackupConfigurationException($"{option} requires a positive integer.");
                }

                if (option == "--run-index")
                {
                    if (runIndex is not null)
                    {
                        throw new BackupConfigurationException("--run-index may be specified only once.");
                    }

                    runIndex = value;
                }
                else
                {
                    if (revision is not null)
                    {
                        throw new BackupConfigurationException("--revision may be specified only once.");
                    }

                    revision = value;
                }

                continue;
            }

            if (arguments[index] == "--control-db")
            {
                if (controlDatabasePath is not null)
                    throw new BackupConfigurationException("--control-db may be specified only once.");
                if (++index >= arguments.Length || string.IsNullOrWhiteSpace(arguments[index]))
                    throw new BackupConfigurationException("--control-db requires a value.");
                controlDatabasePath = arguments[index];
                continue;
            }

            configurationArguments.Add(arguments[index]);
        }

        if (sourceId is null)
        {
            throw new BackupConfigurationException("backup requires --source-id <id>.");
        }

        return new OnceBackupArguments(
            sourceId,
            runIndex,
            revision,
            controlDatabasePath,
            saveGame,
            ConfigurationArguments.Parse(configurationArguments.ToArray()), scheduledUtc);
    }
}
