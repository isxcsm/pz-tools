using PzTools.Backup.Storage.Repository;
using PzTools.Zomboid.State;

namespace PzTools.Zomboid.Backup;

// Derived display data only: always read the captured file, never the changing live save.
public sealed class RevisionCharacterMetadataCollector(int batchSize = 8, int retrySeconds = 60)
{
    private long afterSource;
    private long afterRevision;
    private DateTimeOffset nextSweep;
    private readonly Queue<(RevisionReference Revision, CharacterSnapshot? Snapshot, string? Error)> ready = new();

    public static async Task PopulateAsync(RepositoryDatabase repository, RepositoryWriterLease lease,
        long sourceId, long revision, CancellationToken token)
    {
        try
        {
            var snapshot = await ReadAsync(repository, sourceId, revision, token);
            await StoreAsync(repository, lease, sourceId, revision, snapshot, token);
        }
        catch (Exception exception) when (IsReadFailure(exception))
        {
            await repository.RecordCharacterMetadataFailureAsync(lease, sourceId, revision, exception.Message, token);
            throw;
        }
    }

    private static async Task<CharacterSnapshot> ReadAsync(RepositoryDatabase repository,
        long sourceId, long revision, CancellationToken token)
    {
        var locator = await repository.TryLocateRevisionFileAsync(sourceId, revision, "players.db", token);
        CharacterSnapshot snapshot;
        if (locator is null) snapshot = new(null, CharacterState.Unknown);
        else
        {
            await using var file = await new RevisionFileReader(repository)
                .MaterializeTemporaryAsync(locator, Path.GetTempPath(), token);
            snapshot = await new CharacterNameReader().ReadSnapshotAsync(file.Path, token);
            if (!snapshot.ReadSucceeded) throw new IOException(snapshot.ReadError ?? "Cannot read the captured character database.");
        }
        return snapshot;
    }

    private static Task<bool> StoreAsync(RepositoryDatabase repository, RepositoryWriterLease lease,
        long sourceId, long revision, CharacterSnapshot snapshot, CancellationToken token) =>
        repository.SetRevisionCharacterMetadataAsync(lease, sourceId, revision,
            snapshot.Name is { Length: > 256 } name ? name[..256] : snapshot.Name,
            snapshot.State.ToString(), token, snapshot.HoursSurvived);

    private static bool IsReadFailure(Exception exception) =>
        exception is IOException or InvalidDataException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException;

    // Repairs missing summaries after interrupted creation as well as older revisions.
    // Keyset traversal bounds attempts (including failures) and prevents one bad pack starving others.
    public async Task CollectOnceAsync(RepositoryDatabase repository, CancellationToken token = default)
    {
        if (batchSize <= 0) throw new ArgumentOutOfRangeException(nameof(batchSize));
        if (retrySeconds <= 0) throw new ArgumentOutOfRangeException(nameof(retrySeconds));
        if (DateTimeOffset.UtcNow < nextSweep) return;
        if (ready.Count == 0)
        {
            var pending = await repository.ReadPendingCharacterMetadataAsync(afterSource, afterRevision, batchSize, token);
            if (pending.Count == 0)
            {
                afterSource = afterRevision = 0;
                nextSweep = DateTimeOffset.UtcNow.AddSeconds(retrySeconds);
                return;
            }
            // Pack I/O is read-only and does not hold the repository writer lease.
            foreach (var item in pending)
            {
                token.ThrowIfCancellationRequested();
                try { ready.Enqueue((item, await ReadAsync(repository, item.SourceId, item.Revision, token), null)); }
                catch (Exception exception) when (IsReadFailure(exception))
                { ready.Enqueue((item, null, exception.GetType().Name + ": " + exception.Message)); }
                afterSource = item.SourceId;
                afterRevision = item.Revision;
            }
        }
        if (ready.Count == 0) return;
        RepositoryWriterLease lease;
        try { lease = RepositoryWriterLease.Acquire(repository.RepositoryPath); }
        catch (RepositoryBusyException) { return; }
        await using (lease)
        {
            while (ready.TryPeek(out var item))
            {
                token.ThrowIfCancellationRequested();
                if (item.Snapshot is { } snapshot)
                    await StoreAsync(repository, lease, item.Revision.SourceId, item.Revision.Revision, snapshot, token);
                else
                    await repository.RecordCharacterMetadataFailureAsync(lease, item.Revision.SourceId,
                        item.Revision.Revision, item.Error!, token);
                ready.Dequeue();
            }
        }
    }
}
