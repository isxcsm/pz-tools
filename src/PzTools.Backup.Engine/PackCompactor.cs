using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed class PackCompactor(IBackupFailureInjector? failureInjector = null)
{
    private readonly IBackupFailureInjector failures = failureInjector ?? NoBackupFailureInjector.Instance;

    /// <summary>
    /// Moves every registered object of the given packs into one new pack and leaves the old packs
    /// empty for garbage collection. Nothing changes unless the whole replacement commits.
    /// <see cref="PackSpaceReclaimer"/> decides which packs are worth rewriting.
    /// </summary>
    public async Task<PackCompactionResult> RewriteAsync(
        RepositoryDatabase repository,
        RepositoryWriterLease lease,
        IReadOnlyList<RepositoryPack> packs,
        long? createdRunIndex = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(lease);
        ArgumentNullException.ThrowIfNull(packs);
        if (packs.Count == 0)
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

            // The same three interruption boundaries as a backup: data only in staging, a promoted
            // but unregistered pack, and a committed switch whose old packs are not yet removed.
            failures.ThrowIfRequested(BackupFailurePoint.BeforePackFlush);
            var committed = await writer.SealAndPromoteAsync(cancellationToken);
            failures.ThrowIfRequested(BackupFailurePoint.AfterPackPromotion);
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
            failures.ThrowIfRequested(BackupFailurePoint.AfterRepositoryCommit);

            return new PackCompactionResult(
                packs.Count,
                relocated.Count,
                committed.PackId,
                FilesThatCouldNotBeDeleted: [],
                committed.ByteLength);
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
