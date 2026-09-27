namespace PzTools.Backup.Core.Configuration;

public sealed class BackupConfigurationException : Exception
{
    public BackupConfigurationException(string message)
        : base(message)
    {
    }

    public BackupConfigurationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
