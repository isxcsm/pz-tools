using PzTools.Backup.Core.Configuration;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Backup.Cli;

internal sealed record OnceBackupArguments(
    string SourceId,
    long? RunIndex,
    long? Revision,
    string? ControlDatabasePath,
    bool SaveGame,
    ConfigurationArguments Configuration,
    DateTimeOffset? ScheduledUtc = null,
    bool RequireActiveGame = false,
    RuntimeSaveTicket? RuntimeTicket = null, string? RuntimeAuthority = null, long? RuntimeGeneration = null,
    string? GameVersion = null)
{
    // Recover only an unambiguous caller identity for errors raised while
    // parsing other options. Full argument validation still happens in Parse.
    public static long? ReadFailureRunIndex(string[] arguments)
    {
        var indices = arguments.Select((value, index) => (value, index))
            .Where(item => item.value == "--run-index").Select(item => item.index).ToArray();
        return indices.Length == 1 && indices[0] + 1 < arguments.Length
            && long.TryParse(arguments[indices[0] + 1], System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var value) && value > 0
                ? value : null;
    }

    public static OnceBackupArguments Parse(string[] arguments)
    {
        string? sourceId = null;
        long? runIndex = null;
        long? revision = null;
        string? controlDatabasePath = null;
        var saveGame = false;
        var requireActiveGame = false;
        DateTimeOffset? scheduledUtc = null;
        RuntimeSaveTicket? runtimeTicket = null;
        string? runtimeAuthority = null;
        long? runtimeGeneration = null;
        string? gameVersion = null;
        var configurationArguments = new List<string>();
        for (var index = 0; index < arguments.Length; index++)
        {
            if (arguments[index] == "--game-version")
            {
                if (gameVersion is not null || ++index >= arguments.Length || string.IsNullOrWhiteSpace(arguments[index])
                    || arguments[index].Length > 80 || arguments[index].Any(char.IsControl))
                    throw new BackupConfigurationException("--game-version requires one value of at most 80 printable characters.");
                gameVersion = arguments[index].Trim(); continue;
            }
            if (arguments[index] == "--runtime-authority")
            {
                if (runtimeAuthority is not null || ++index >= arguments.Length || !Path.IsPathFullyQualified(arguments[index]))
                    throw new BackupConfigurationException("--runtime-authority requires one absolute scheduler path.");
                runtimeAuthority = arguments[index]; continue;
            }
            if (arguments[index] == "--runtime-generation")
            {
                if (runtimeGeneration is not null || ++index >= arguments.Length || !long.TryParse(arguments[index],
                    System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var value))
                    throw new BackupConfigurationException("--runtime-generation requires one nonnegative generation.");
                runtimeGeneration = value; continue;
            }
            if (arguments[index] == "--runtime-ticket")
            {
                if (runtimeTicket is not null || ++index >= arguments.Length)
                    throw new BackupConfigurationException("--runtime-ticket requires one typed execution ticket.");
                try { runtimeTicket = RuntimeSaveTicket.Parse(arguments[index]); }
                catch (Exception error) when (error is InvalidDataException or FormatException or OverflowException)
                { throw new BackupConfigurationException("Invalid runtime execution ticket."); }
                continue;
            }
            if (arguments[index] == "--require-active-game")
            {
                if (requireActiveGame) throw new BackupConfigurationException("--require-active-game may be specified only once.");
                requireActiveGame = true;
                continue;
            }
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
                    || !long.TryParse(arguments[index], System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var value)
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

        if ((runtimeTicket is null) != (runtimeAuthority is null) || (runtimeTicket is null) != (runtimeGeneration is null)
            || runtimeTicket is not null && (!saveGame || !requireActiveGame || scheduledUtc is not null))
            throw new BackupConfigurationException("Guarded runtime backups require --save-game and --require-active-game, without a UTC deadline.");
        return new OnceBackupArguments(
            sourceId,
            runIndex,
            revision,
            controlDatabasePath,
            saveGame,
            ConfigurationArguments.Parse(configurationArguments.ToArray()), scheduledUtc, requireActiveGame, runtimeTicket, runtimeAuthority, runtimeGeneration, gameVersion);
    }
}
