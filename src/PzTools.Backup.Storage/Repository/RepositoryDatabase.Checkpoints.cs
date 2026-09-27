using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public async Task AdvanceCheckpointWithoutRevisionAsync(
        RepositoryWriterLease lease,
        long runIndex,
        long sourceId,
        SourceCheckpoint? checkpoint,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await using (var state = connection.CreateCommand())
            {
                state.Transaction = transaction;
                state.CommandText =
                    """
                    UPDATE source_state
                    SET volume_identity = $volumeIdentity,
                        journal_id = $journalId,
                        next_usn = $nextUsn
                    WHERE source_id = $sourceId
                      AND EXISTS (
                          SELECT 1 FROM runs
                          WHERE run_index = $runIndex
                            AND source_id = $sourceId
                            AND status = 'Running'
                      );
                    """;
                state.Parameters.AddWithValue(
                    "$volumeIdentity",
                    (object?)checkpoint?.VolumeIdentity ?? DBNull.Value);
                state.Parameters.AddWithValue(
                    "$journalId",
                    (object?)checkpoint?.JournalId ?? DBNull.Value);
                state.Parameters.AddWithValue(
                    "$nextUsn",
                    (object?)checkpoint?.NextUsn ?? DBNull.Value);
                state.Parameters.AddWithValue("$sourceId", sourceId);
                state.Parameters.AddWithValue("$runIndex", runIndex);
                if (await state.ExecuteNonQueryAsync(cancellationToken) != 1)
                {
                    throw new InvalidOperationException("The source or running run is invalid.");
                }
            }

            await CompleteRunInTransactionAsync(
                connection,
                transaction,
                runIndex,
                cancellationToken,
                WorkflowStatus.NoChange);
            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }
}
