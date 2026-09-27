using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed class PackCompactor
{
    public async Task<PackCompactionResult> CompactAsync(
        RepositoryDatabase repository,
        RepositoryWriterLease lease,
        long maximumSourcePackBytes,
        CancellationToken cancellationToken = default)
        => await CompactCoreAsync(
            repository, lease, createdRunIndex: null, maximumSourcePackBytes, cancellationToken);

    public async Task<PackCompactionResult> CompactAsync(
        RepositoryDatabase repository,
        RepositoryWriterLease lease,
        long createdRunIndex,
        long maximumSourcePackBytes,
        CancellationToken cancellationToken = default)
        => await CompactCoreAsync(
            repository, lease, createdRunIndex, maximumSourcePackBytes, cancellationToken);

    private static async Task<PackCompactionResult> CompactCoreAsync(
        RepositoryDatabase repository,
        RepositoryWriterLease lease,
        long? createdRunIndex,
        long maximumSourcePackBytes,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(lease);
        if (maximumSourcePackBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumSourcePackBytes));
        }

        var packs = (await repository.ReadPacksAsync(cancellationToken))
            .Where(item => item.Status == "Committed" && item.ByteLength <= maximumSourcePackBytes)
            .ToArray();
        if (packs.Length < 2)
        {
            return new PackCompactionResult(0, 0, NewPackId: null, []);
        }

        var objects = await repository.ReadCompactionObjectsAsync(
            packs.Select(item => item.PackId).ToArray(),
            cancellationToken);
        if (objects.Count == 0)
        {
            return new PackCompactionResult(0, 0, NewPackId: null, []);
        }

        var runIndex = createdRunIndex ?? packs.Max(item => item.CreatedRunIndex);
        await using var writer = await PackWriter.CreateAsync(
            repository.RepositoryPath,
            runIndex,
            cancellationToken);
        var readers = new Dictionary<Guid, PackReader>();
        try
        {
            var relocated = new List<StoredObjectRegistration>(objects.Count);
            foreach (var item in objects)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!readers.TryGetValue(item.PackId, out var reader))
                {
                    reader = await PackReader.OpenForLocatedReadsAsync(
                        ResolveRepositoryPath(repository.RepositoryPath, item.PackRelativePath),
                        item.PackId,
                        cancellationToken);
                    readers.Add(item.PackId, reader);
                }

                var descriptor = await reader.RepackObjectAtAsync(
                    item.ObjectId,
                    item.PackOffset,
                    writer,
                    cancellationToken);
                relocated.Add(new StoredObjectRegistration(
                    descriptor.ObjectId,
                    writer.PackId,
                    descriptor.RecordOffset,
                    descriptor.StoredLength,
                    descriptor.OriginalLength,
                    descriptor.ChecksumAlgorithm.ToString(),
                    descriptor.Checksum,
                    descriptor.CompressionAlgorithm.ToString(),
                    descriptor.Flags));
            }

            var committed = await writer.SealAndPromoteAsync(cancellationToken);
            await repository.CommitCompactionAsync(
                lease,
                runIndex,
                new PackRegistration(
                    committed.PackId,
                    committed.RelativePath,
                    PackWriter.CurrentFormatVersion,
                    committed.ByteLength),
                relocated,
                packs.Select(item => item.PackId).ToArray(),
                cancellationToken);

            return new PackCompactionResult(
                packs.Length,
                relocated.Count,
                committed.PackId,
                FilesThatCouldNotBeDeleted: []);
        }
        finally
        {
            foreach (var reader in readers.Values)
            {
                await reader.DisposeAsync();
            }
        }
    }

    private static string ResolveRepositoryPath(string repositoryPath, string relativePath)
    {
        var normalized = BackupPath.NormalizeRelative(relativePath);
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(repositoryPath));
        var path = Path.GetFullPath(Path.Combine(
            root,
            normalized.Replace('/', Path.DirectorySeparatorChar)));
        if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"Pack path '{relativePath}' escapes its repository.");
        }

        return path;
    }
}
