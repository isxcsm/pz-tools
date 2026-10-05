using System.Globalization;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    // Whoever holds the writer lease is the only worker that may write: any other worker stage
    // still marked Running was interrupted.
    public async Task<int> RecoverAbandonedRunsAsync(
        RepositoryWriterLease lease,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        var completedUtc = DateTimeOffset.UtcNow.ToString("O");
        await using (var workflows = connection.CreateCommand())
        {
            // A worker that owns its workflow closes it together with its stage, so an interrupted
            // stage leaves that workflow Running for good. A Running workflow blocks VACUUM and the
            // source's orphan cleanup, so close it here as well. Workflows owned by someone else
            // (the scheduler, a maintenance lane) are left to their owner, and a reserved workflow
            // whose worker has not started yet has no Running stage, so neither is touched.
            workflows.Transaction = transaction;
            workflows.CommandText =
                """
                UPDATE workflow_runs
                SET status = 'Abandoned', completed_utc = $completedUtc,
                    failure_code = 'process-interrupted'
                WHERE status = 'Running'
                  AND owner_component IN ('backup-worker', 'maintenance-worker')
                  AND EXISTS (
                      SELECT 1 FROM workflow_stages AS stage
                      WHERE stage.run_index = workflow_runs.run_index
                        AND stage.producer = workflow_runs.owner_component
                        AND stage.status = 'Running');
                """;
            workflows.Parameters.AddWithValue("$completedUtc", completedUtc);
            await workflows.ExecuteNonQueryAsync(cancellationToken);
        }

        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            UPDATE workflow_stages
            SET status = 'Abandoned', completed_utc = $completedUtc,
                failure_code = 'process-interrupted'
            WHERE producer IN ('backup-worker', 'maintenance-worker') AND status = 'Running';
            """;
        command.Parameters.AddWithValue("$completedUtc", completedUtc);
        var abandoned = await command.ExecuteNonQueryAsync(cancellationToken);
        transaction.Commit();
        return abandoned;
    }

    public async Task<IReadOnlyList<RepositoryRun>> ReadRunsAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT run_index, source_id, status, started_utc, completed_utc, failure_code
            FROM worker_runs
            WHERE source_id IS NOT NULL
            ORDER BY run_index;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var runs = new List<RepositoryRun>();
        while (await reader.ReadAsync(cancellationToken))
        {
            runs.Add(new RepositoryRun(
                reader.GetInt64(0),
                reader.GetInt64(1),
                Enum.Parse<RunStatus>(reader.GetString(2)),
                DateTimeOffset.Parse(reader.GetString(3), CultureInfo.InvariantCulture),
                reader.IsDBNull(4)
                    ? null
                    : DateTimeOffset.Parse(reader.GetString(4), CultureInfo.InvariantCulture),
                reader.IsDBNull(5) ? null : reader.GetString(5)));
        }

        return runs;
    }
}
