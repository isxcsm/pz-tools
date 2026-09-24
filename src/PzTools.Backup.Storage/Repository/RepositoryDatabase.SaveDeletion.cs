using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public async Task<PendingSaveRevisionDeletion> PrepareSaveRevisionDeletionAsync(
        RepositoryWriterLease lease, string sourceKey, string expectedRootPath,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedRootPath);
        var connection = await OpenConnectionAsync(cancellationToken);
        SqliteTransaction? transaction = null;
        try
        {
            transaction = connection.BeginTransaction(deferred: false);
            var source = await ReadSourceByKeyAsync(connection, transaction, sourceKey, cancellationToken);
            var marked = 0;
            if (source is not null)
            {
                if (!StringComparer.OrdinalIgnoreCase.Equals(
                    Path.TrimEndingDirectorySeparator(Path.GetFullPath(source.RootPath)),
                    Path.TrimEndingDirectorySeparator(Path.GetFullPath(expectedRootPath))))
                    throw new InvalidOperationException("The backup source path does not match the save being deleted.");

                await using var command = connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText =
                    """
                    UPDATE revisions
                    SET state='Deleted', deleted_utc=$now, delete_reason='save-deleted'
                    WHERE source_id=$sourceId AND state='Active';
                    """;
                command.Parameters.AddWithValue("$sourceId", source.SourceId);
                command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToString("O"));
                marked = await command.ExecuteNonQueryAsync(cancellationToken);
                if (marked > 0)
                    await IncrementRepositoryChangeRevisionAsync(connection, transaction, cancellationToken);
            }
            return new PendingSaveRevisionDeletion(connection, transaction, marked);
        }
        catch
        {
            try { if (transaction is not null) await transaction.DisposeAsync(); }
            finally { await connection.DisposeAsync(); }
            throw;
        }
    }
}

/// <summary>세이브 폴더 삭제가 성공했을 때만 백업 삭제 마킹을 확정합니다. 미확정 상태로 해제하면 롤백됩니다.</summary>
public sealed class PendingSaveRevisionDeletion : IAsyncDisposable
{
    private readonly SqliteConnection connection;
    private readonly SqliteTransaction transaction;

    internal PendingSaveRevisionDeletion(SqliteConnection connection, SqliteTransaction transaction, int markedRevisions)
    {
        this.connection = connection;
        this.transaction = transaction;
        MarkedRevisions = markedRevisions;
    }

    public int MarkedRevisions { get; }

    // 원본 삭제 이후에는 취소 요청 때문에 백업 삭제 확정이 생략되지 않게 합니다.
    public Task CommitAsync() => transaction.CommitAsync(CancellationToken.None);

    public async ValueTask DisposeAsync()
    {
        try { await transaction.DisposeAsync(); }
        finally { await connection.DisposeAsync(); }
    }
}
