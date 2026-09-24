using PzTools.Backup.Storage.Packs;

namespace PzTools.Backup.Storage.Repository;

public sealed class RevisionFileReader(RepositoryDatabase repository)
{
    public async Task CopyToAsync(
        RevisionFileLocator locator,
        Stream destination,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(locator);
        ArgumentNullException.ThrowIfNull(destination);
        var packPath = ResolvePackPath(locator.PackRelativePath);
        await using var reader = await PackReader.OpenForLocatedReadsAsync(
            packPath, locator.PackId, cancellationToken);
        await reader.CopyObjectAtAsync(
            locator.ObjectId, locator.PackOffset, destination, cancellationToken);
    }

    public async Task<byte[]> ReadBytesAsync(
        RevisionFileLocator locator,
        long maximumBytes,
        CancellationToken cancellationToken = default)
    {
        if (maximumBytes <= 0) throw new ArgumentOutOfRangeException(nameof(maximumBytes));
        if (locator.OriginalLength > maximumBytes)
            throw new InvalidDataException(
                $"Revision file is {locator.OriginalLength} bytes, above the {maximumBytes} byte limit.");
        using var memory = new MemoryStream(
            locator.OriginalLength > int.MaxValue ? 0 : checked((int)locator.OriginalLength));
        await CopyToAsync(locator, memory, cancellationToken);
        if (memory.Length != locator.OriginalLength)
            throw new InvalidDataException("Revision file length does not match repository metadata.");
        return memory.ToArray();
    }

    public async Task<TemporaryRevisionFile> MaterializeTemporaryAsync(
        RevisionFileLocator locator,
        string temporaryDirectory,
        CancellationToken cancellationToken = default)
    {
        var directory = Path.GetFullPath(temporaryDirectory);
        Directory.CreateDirectory(directory);
        var finalPath = Path.Combine(directory, $"pztools-{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                finalPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await CopyToAsync(locator, stream, cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }
            File.SetAttributes(finalPath, FileAttributes.ReadOnly);
            return new TemporaryRevisionFile(finalPath);
        }
        catch
        {
            if (File.Exists(finalPath)) File.Delete(finalPath);
            throw;
        }
    }

    private string ResolvePackPath(string relativePath)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(repository.RepositoryPath));
        var path = Path.GetFullPath(Path.Combine(
            root, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        var relative = Path.GetRelativePath(root, path);
        if (Path.IsPathFullyQualified(relative)
            || relative == ".."
            || relative.StartsWith($"..{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
            throw new InvalidDataException("Pack path escapes the repository root.");
        return path;
    }
}

public sealed class TemporaryRevisionFile(string path) : IAsyncDisposable, IDisposable
{
    private string? path = path;
    public string Path => path ?? throw new ObjectDisposedException(nameof(TemporaryRevisionFile));

    public void Dispose()
    {
        var current = Interlocked.Exchange(ref path, null);
        if (current is null || !File.Exists(current)) return;
        File.SetAttributes(current, FileAttributes.Normal);
        File.Delete(current);
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }
}
