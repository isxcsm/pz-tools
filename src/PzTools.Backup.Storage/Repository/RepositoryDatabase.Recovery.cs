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
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE workflow_stages
            SET status = 'Abandoned', completed_utc = $completedUtc,
                failure_code = 'process-interrupted'
            WHERE producer IN ('backup-worker', 'maintenance-worker') AND status = 'Running';
            """;
        command.Parameters.AddWithValue("$completedUtc", DateTimeOffset.UtcNow.ToString("O"));
        return await command.ExecuteNonQueryAsync(cancellationToken);
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
