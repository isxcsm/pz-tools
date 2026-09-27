namespace PzTools.Backup.Storage.Repository;

public sealed class RepositoryWriterLease : IDisposable, IAsyncDisposable
{
    private readonly FileStream lockStream;
    private int disposed;

    private RepositoryWriterLease(string repositoryPath, FileStream lockStream)
    {
        RepositoryPath = repositoryPath;
        this.lockStream = lockStream;
    }

    public string RepositoryPath { get; }

    public bool IsHeld => Volatile.Read(ref disposed) == 0;

    public static RepositoryWriterLease Acquire(string repositoryPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(repositoryPath);

        var absolutePath = Path.GetFullPath(repositoryPath);
        Directory.CreateDirectory(absolutePath);
        var lockPath = Path.Combine(absolutePath, ".writer.lock");

        try
        {
            var stream = new FileStream(
                lockPath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None,
                bufferSize: 1,
                FileOptions.WriteThrough);
            return new RepositoryWriterLease(absolutePath, stream);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new RepositoryBusyException(absolutePath, exception);
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        lockStream.Dispose();
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }

    internal void EnsureHeldFor(string repositoryPath)
    {
        ObjectDisposedException.ThrowIf(!IsHeld, this);
        if (!StringComparer.OrdinalIgnoreCase.Equals(RepositoryPath, repositoryPath))
        {
            throw new ArgumentException(
                "The writer lease belongs to another repository.",
                nameof(repositoryPath));
        }
    }
}
