namespace PzTools.Backup.Storage.Repository;

public sealed class RepositoryBusyException : Exception
{
    public RepositoryBusyException(string repositoryPath, Exception? innerException = null)
        : base($"Repository '{repositoryPath}' already has an active writer.", innerException)
    {
    }
}
