using System.Diagnostics;
using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

public sealed record InterruptedWorkflowRecovery(int Recovered, int Unverified);

public sealed partial class RepositoryDatabase
{
    private static async Task StampWorkflowProcessAsync(SqliteConnection connection,
        SqliteTransaction transaction, long runIndex, string? producer, CancellationToken token)
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = producer is null
            ? "UPDATE workflow_runs SET owner_pid=$pid,owner_start_ticks=$ticks WHERE run_index=$run;"
            : "UPDATE workflow_stages SET owner_pid=$pid,owner_start_ticks=$ticks WHERE run_index=$run AND producer=$producer;";
        command.Parameters.AddWithValue("$pid", process.Id);
        command.Parameters.AddWithValue("$ticks", process.StartTime.ToUniversalTime().Ticks);
        command.Parameters.AddWithValue("$run", runIndex);
        if (producer is not null) command.Parameters.AddWithValue("$producer", producer);
        await command.ExecuteNonQueryAsync(token);
    }

    // Call only while holding RepositoryAccess and the writer lease. Process identity
    // also protects jobs that were reserved but have not acquired those locks yet.
    public async Task<InterruptedWorkflowRecovery> RecoverInterruptedWorkflowsAsync(
        RepositoryWriterLease lease, CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        var owners = new Dictionary<long, List<(int? Pid, long? Ticks)>>();
        await using (var query = connection.CreateCommand())
        {
            query.Transaction = transaction;
            query.CommandText = """
                SELECT run_index,owner_pid,owner_start_ticks FROM workflow_runs WHERE status='Running'
                UNION ALL
                SELECT s.run_index,s.owner_pid,s.owner_start_ticks FROM workflow_stages s
                JOIN workflow_runs w ON w.run_index=s.run_index
                WHERE w.status='Running' AND s.status='Running';
                """;
            await using var reader = await query.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                var run = reader.GetInt64(0);
                if (!owners.TryGetValue(run, out var list)) owners.Add(run, list = []);
                list.Add((reader.IsDBNull(1) ? null : reader.GetInt32(1), reader.IsDBNull(2) ? null : reader.GetInt64(2)));
            }
        }
        var recovered = 0;
        var unknown = 0;
        foreach (var (run, processes) in owners)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var states = processes.Select(item => IsSameProcessAlive(item.Pid, item.Ticks)).ToArray();
            if (states.Contains(true)) continue;
            if (states.Contains(null)) { unknown++; continue; }
            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                UPDATE workflow_stages SET status='Abandoned',completed_utc=$now,failure_code='process-interrupted'
                    WHERE run_index=$run AND status='Running';
                UPDATE workflow_runs SET status='Abandoned',completed_utc=$now,failure_code='process-interrupted'
                    WHERE run_index=$run AND status='Running';
                """;
            command.Parameters.AddWithValue("$run", run);
            command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToString("O"));
            await command.ExecuteNonQueryAsync(cancellationToken);
            recovered++;
        }
        transaction.Commit();
        return new InterruptedWorkflowRecovery(recovered, unknown);
    }

    private static bool? IsSameProcessAlive(int? pid, long? ticks)
    {
        if (pid is null || ticks is null) return null;
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById(pid.Value);
            return !process.HasExited && process.StartTime.ToUniversalTime().Ticks == ticks;
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (System.ComponentModel.Win32Exception) { return null; }
    }
}
