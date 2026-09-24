using System.Globalization;
using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public async Task<WorkflowRun> ReserveWorkflowAsync(
        string pipeline,
        long? sourceId,
        string ownerComponent,
        string? admissionId = null,
        CancellationToken cancellationToken = default)
        => await ReserveWorkflowCoreAsync(
            pipeline, sourceId, ownerComponent, admissionId, null, cancellationToken);

    public async Task<WorkflowRun> ReserveWorkflowAsync(
        string pipeline,
        long? sourceId,
        string ownerComponent,
        string? admissionId,
        long runIndex,
        CancellationToken cancellationToken = default)
        => await ReserveWorkflowCoreAsync(
            pipeline, sourceId, ownerComponent, admissionId, runIndex, cancellationToken);

    private async Task<WorkflowRun> ReserveWorkflowCoreAsync(
        string pipeline,
        long? sourceId,
        string ownerComponent,
        string? admissionId,
        long? requestedRunIndex,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeline);
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerComponent);
        if (sourceId is <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sourceId));
        }

        if (admissionId is not null)
        {
            ArgumentException.ThrowIfNullOrWhiteSpace(admissionId);
            var existing = await TryReadWorkflowByAdmissionAsync(admissionId, cancellationToken);
            if (existing is not null)
            {
                EnsureWorkflowIdentity(existing, pipeline, sourceId, ownerComponent);
                return existing;
            }
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            long runIndex;
            if (requestedRunIndex is null)
            {
                await using var allocate = connection.CreateCommand();
                allocate.Transaction = transaction;
                allocate.CommandText =
                    """
                    UPDATE repository_info
                    SET next_run_index = next_run_index + 1
                    WHERE singleton = 1
                    RETURNING next_run_index - 1;
                    """;
                runIndex = Convert.ToInt64(
                    await allocate.ExecuteScalarAsync(cancellationToken),
                    CultureInfo.InvariantCulture);
            }
            else
            {
                if (requestedRunIndex <= 0)
                    throw new ArgumentOutOfRangeException(nameof(requestedRunIndex));
                runIndex = requestedRunIndex.Value;
                await using var advance = connection.CreateCommand();
                advance.Transaction = transaction;
                advance.CommandText =
                    "UPDATE repository_info SET next_run_index=MAX(next_run_index,$next) WHERE singleton=1;";
                advance.Parameters.AddWithValue("$next", checked(runIndex + 1));
                await advance.ExecuteNonQueryAsync(cancellationToken);
            }

            var startedUtc = DateTimeOffset.UtcNow;
            await using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText =
                """
                INSERT INTO workflow_runs(
                    run_index, pipeline, source_id, owner_component, admission_id,
                    status, started_utc)
                VALUES (
                    $runIndex, $pipeline, $sourceId, $ownerComponent, $admissionId,
                    'Running', $startedUtc);
                """;
            insert.Parameters.AddWithValue("$runIndex", runIndex);
            insert.Parameters.AddWithValue("$pipeline", pipeline);
            insert.Parameters.AddWithValue("$sourceId", (object?)sourceId ?? DBNull.Value);
            insert.Parameters.AddWithValue("$ownerComponent", ownerComponent);
            insert.Parameters.AddWithValue("$admissionId", (object?)admissionId ?? DBNull.Value);
            insert.Parameters.AddWithValue("$startedUtc", startedUtc.ToString("O"));
            await insert.ExecuteNonQueryAsync(cancellationToken);
            await StampWorkflowProcessAsync(connection, transaction, runIndex, null, cancellationToken);
            transaction.Commit();
            return new WorkflowRun(
                runIndex,
                pipeline,
                sourceId,
                ownerComponent,
                admissionId,
                WorkflowStatus.Running,
                startedUtc,
                CompletedUtc: null,
                FailureCode: null);
        }
        catch (SqliteException exception) when (
            admissionId is not null && exception.SqliteErrorCode == 19)
        {
            transaction.Rollback();
            var existing = await TryReadWorkflowByAdmissionAsync(admissionId, cancellationToken);
            if (existing is null)
            {
                throw;
            }

            EnsureWorkflowIdentity(existing, pipeline, sourceId, ownerComponent);
            return existing;
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<WorkflowRun> ReadWorkflowAsync(
        long runIndex,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = CreateWorkflowSelect(connection);
        command.CommandText += " WHERE run_index = $runIndex;";
        command.Parameters.AddWithValue("$runIndex", runIndex);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken)
            ? ReadWorkflow(reader)
            : throw new KeyNotFoundException($"Workflow run {runIndex} does not exist.");
    }

    public async Task<WorkflowStage> AttachWorkflowStageAsync(
        long runIndex,
        string producer,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(producer);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await EnsureRunningWorkflowAsync(connection, transaction, runIndex, cancellationToken);
            var startedUtc = DateTimeOffset.UtcNow;
            await using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText =
                """
                INSERT INTO workflow_stages(run_index, producer, status, started_utc)
                VALUES ($runIndex, $producer, 'Running', $startedUtc)
                ON CONFLICT(run_index, producer) DO NOTHING;
                """;
            insert.Parameters.AddWithValue("$runIndex", runIndex);
            insert.Parameters.AddWithValue("$producer", producer);
            insert.Parameters.AddWithValue("$startedUtc", startedUtc.ToString("O"));
            var inserted = await insert.ExecuteNonQueryAsync(cancellationToken);
            if (inserted > 0)
                await StampWorkflowProcessAsync(connection, transaction, runIndex, producer, cancellationToken);
            if (inserted == 0)
            {
                var existing = await ReadStageAsync(
                    connection,
                    transaction,
                    runIndex,
                    producer,
                    cancellationToken);
                if (existing.Status != WorkflowStatus.Running)
                {
                    throw new InvalidOperationException(
                        $"Workflow stage '{producer}' for run {runIndex} is already complete.");
                }

                transaction.Commit();
                return existing;
            }

            transaction.Commit();
            return new WorkflowStage(
                runIndex,
                producer,
                WorkflowStatus.Running,
                startedUtc,
                CompletedUtc: null,
                FailureCode: null);
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<IReadOnlyList<WorkflowStage>> ReadWorkflowStagesAsync(
        long runIndex,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT producer,status,started_utc,completed_utc,failure_code
            FROM workflow_stages WHERE run_index=$runIndex ORDER BY producer;
            """;
        command.Parameters.AddWithValue("$runIndex", runIndex);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var stages = new List<WorkflowStage>();
        while (await reader.ReadAsync(cancellationToken))
        {
            stages.Add(new WorkflowStage(
                runIndex,
                reader.GetString(0),
                Enum.Parse<WorkflowStatus>(reader.GetString(1)),
                DateTimeOffset.Parse(reader.GetString(2), CultureInfo.InvariantCulture),
                reader.IsDBNull(3)
                    ? null
                    : DateTimeOffset.Parse(reader.GetString(3), CultureInfo.InvariantCulture),
                reader.IsDBNull(4) ? null : reader.GetString(4)));
        }

        return stages;
    }

    public async Task CompleteWorkflowStageAsync(
        long runIndex,
        string producer,
        WorkflowStatus status,
        string? failureCode = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(producer);
        EnsureTerminalStatus(status);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE workflow_stages
            SET status = $status, completed_utc = $completedUtc, failure_code = $failureCode
            WHERE run_index = $runIndex AND producer = $producer AND status = 'Running';
            """;
        command.Parameters.AddWithValue("$status", status.ToString());
        command.Parameters.AddWithValue("$completedUtc", DateTimeOffset.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$failureCode", (object?)failureCode ?? DBNull.Value);
        command.Parameters.AddWithValue("$runIndex", runIndex);
        command.Parameters.AddWithValue("$producer", producer);
        if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
        {
            throw new InvalidOperationException(
                $"Workflow stage '{producer}' for run {runIndex} is not Running.");
        }
    }

    public async Task CompleteWorkflowAsync(
        long runIndex,
        string ownerComponent,
        WorkflowStatus status,
        string? failureCode = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerComponent);
        EnsureTerminalStatus(status);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE workflow_runs
            SET status = $status, completed_utc = $completedUtc, failure_code = $failureCode
            WHERE run_index = $runIndex
              AND owner_component = $ownerComponent
              AND status = 'Running';
            """;
        command.Parameters.AddWithValue("$status", status.ToString());
        command.Parameters.AddWithValue("$completedUtc", DateTimeOffset.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$failureCode", (object?)failureCode ?? DBNull.Value);
        command.Parameters.AddWithValue("$runIndex", runIndex);
        command.Parameters.AddWithValue("$ownerComponent", ownerComponent);
        if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
        {
            throw new InvalidOperationException(
                $"Workflow run {runIndex} is not owned by '{ownerComponent}' or is not Running.");
        }
    }

    public async Task<int> RecoverAbandonedWorkflowsAsync(
        string ownerComponent,
        long? sourceId = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownerComponent);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        var completedUtc = DateTimeOffset.UtcNow.ToString("O");
        await using (var stages = connection.CreateCommand())
        {
            stages.Transaction = transaction;
            stages.CommandText =
                """
                UPDATE workflow_stages
                SET status = 'Abandoned', completed_utc = $completedUtc,
                    failure_code = 'process-interrupted'
                WHERE status = 'Running'
                  AND run_index IN (
                      SELECT run_index FROM workflow_runs
                      WHERE owner_component = $owner AND status = 'Running'
                        AND ($sourceId IS NULL OR source_id = $sourceId)
                  );
                """;
            stages.Parameters.AddWithValue("$completedUtc", completedUtc);
            stages.Parameters.AddWithValue("$owner", ownerComponent);
            stages.Parameters.AddWithValue("$sourceId", (object?)sourceId ?? DBNull.Value);
            await stages.ExecuteNonQueryAsync(cancellationToken);
        }

        await using var workflows = connection.CreateCommand();
        workflows.Transaction = transaction;
        workflows.CommandText =
            """
            UPDATE workflow_runs
            SET status = 'Abandoned', completed_utc = $completedUtc,
                failure_code = 'process-interrupted'
            WHERE owner_component = $owner AND status = 'Running'
              AND ($sourceId IS NULL OR source_id = $sourceId);
            """;
        workflows.Parameters.AddWithValue("$completedUtc", completedUtc);
        workflows.Parameters.AddWithValue("$owner", ownerComponent);
        workflows.Parameters.AddWithValue("$sourceId", (object?)sourceId ?? DBNull.Value);
        var count = await workflows.ExecuteNonQueryAsync(cancellationToken);
        transaction.Commit();
        return count;
    }

    public async Task<int> RecoverAbandonedWorkflowStagesAsync(
        string producer,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(producer);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE workflow_stages
            SET status='Abandoned',completed_utc=$completed,
                failure_code='process-interrupted'
            WHERE producer=$producer AND status='Running';
            """;
        command.Parameters.AddWithValue("$completed", DateTimeOffset.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$producer", producer);
        return await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task<bool> StartMaintenanceStageAsync(
        RepositoryWriterLease lease,
        long sourceId,
        long runIndex,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await EnsureRunningWorkflowAsync(connection, transaction, runIndex, cancellationToken);
            await using (var verify = connection.CreateCommand())
            {
                verify.Transaction = transaction;
                verify.CommandText =
                    "SELECT 1 FROM workflow_runs WHERE run_index = $runIndex AND source_id = $sourceId;";
                verify.Parameters.AddWithValue("$runIndex", runIndex);
                verify.Parameters.AddWithValue("$sourceId", sourceId);
                if (await verify.ExecuteScalarAsync(cancellationToken) is null)
                {
                    throw new InvalidOperationException(
                        $"Workflow run {runIndex} does not target source {sourceId}.");
                }
            }

            var startedUtc = DateTimeOffset.UtcNow.ToString("O");
            await using (var stage = connection.CreateCommand())
            {
                stage.Transaction = transaction;
                stage.CommandText =
                    """
                    INSERT INTO workflow_stages(run_index, producer, status, started_utc)
                    VALUES ($runIndex, 'maintenance-worker', 'Running', $startedUtc);
                    """;
                stage.Parameters.AddWithValue("$runIndex", runIndex);
                stage.Parameters.AddWithValue("$startedUtc", startedUtc);
                await stage.ExecuteNonQueryAsync(cancellationToken);
                await StampWorkflowProcessAsync(connection, transaction, runIndex, "maintenance-worker", cancellationToken);
            }

            await using var legacy = connection.CreateCommand();
            legacy.Transaction = transaction;
            legacy.CommandText =
                """
                INSERT OR IGNORE INTO runs(run_index, source_id, status, started_utc)
                VALUES ($runIndex, $sourceId, 'Running', $startedUtc);
                """;
            legacy.Parameters.AddWithValue("$runIndex", runIndex);
            legacy.Parameters.AddWithValue("$sourceId", sourceId);
            legacy.Parameters.AddWithValue("$startedUtc", startedUtc);
            var createdLegacyRun = await legacy.ExecuteNonQueryAsync(cancellationToken) == 1;
            transaction.Commit();
            return createdLegacyRun;
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task CompleteMaintenanceStageAsync(
        RepositoryWriterLease lease,
        long runIndex,
        bool ownsLegacyRun,
        WorkflowStatus status,
        string? failureCode = null,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        EnsureTerminalStatus(status);
        if (ownsLegacyRun)
        {
            await using var connection = await OpenConnectionAsync(cancellationToken);
            await using var legacy = connection.CreateCommand();
            legacy.CommandText =
                """
                UPDATE runs SET status = $status, completed_utc = $completedUtc,
                    failure_code = $failureCode
                WHERE run_index = $runIndex AND status = 'Running';
                """;
            var legacyStatus = status is WorkflowStatus.Cancelled or WorkflowStatus.Abandoned
                ? status.ToString()
                : status == WorkflowStatus.Succeeded ? "Succeeded" : "Failed";
            legacy.Parameters.AddWithValue("$status", legacyStatus);
            legacy.Parameters.AddWithValue("$completedUtc", DateTimeOffset.UtcNow.ToString("O"));
            legacy.Parameters.AddWithValue("$failureCode", (object?)failureCode ?? DBNull.Value);
            legacy.Parameters.AddWithValue("$runIndex", runIndex);
            await legacy.ExecuteNonQueryAsync(cancellationToken);
        }

        await CompleteWorkflowStageAsync(
            runIndex, "maintenance-worker", status, failureCode, cancellationToken);
        var workflow = await ReadWorkflowAsync(runIndex, cancellationToken);
        if (StringComparer.Ordinal.Equals(workflow.OwnerComponent, "maintenance-worker"))
        {
            await CompleteWorkflowAsync(
                runIndex, "maintenance-worker", status, failureCode, cancellationToken);
        }
    }

    public async Task<WorkflowRun?> TryReadWorkflowByAdmissionAsync(
        string admissionId,
        CancellationToken cancellationToken)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = CreateWorkflowSelect(connection);
        command.CommandText += " WHERE admission_id = $admissionId;";
        command.Parameters.AddWithValue("$admissionId", admissionId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        return await reader.ReadAsync(cancellationToken) ? ReadWorkflow(reader) : null;
    }

    private static SqliteCommand CreateWorkflowSelect(SqliteConnection connection)
    {
        var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT run_index, pipeline, source_id, owner_component, admission_id,
                   status, started_utc, completed_utc, failure_code
            FROM workflow_runs
            """;
        return command;
    }

    private static WorkflowRun ReadWorkflow(SqliteDataReader reader) =>
        new(
            reader.GetInt64(0),
            reader.GetString(1),
            reader.IsDBNull(2) ? null : reader.GetInt64(2),
            reader.GetString(3),
            reader.IsDBNull(4) ? null : reader.GetString(4),
            Enum.Parse<WorkflowStatus>(reader.GetString(5)),
            DateTimeOffset.Parse(reader.GetString(6), CultureInfo.InvariantCulture),
            reader.IsDBNull(7)
                ? null
                : DateTimeOffset.Parse(reader.GetString(7), CultureInfo.InvariantCulture),
            reader.IsDBNull(8) ? null : reader.GetString(8));

    private static async Task EnsureRunningWorkflowAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long runIndex,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "SELECT 1 FROM workflow_runs WHERE run_index = $runIndex AND status = 'Running';";
        command.Parameters.AddWithValue("$runIndex", runIndex);
        if (await command.ExecuteScalarAsync(cancellationToken) is null)
        {
            throw new InvalidOperationException($"Workflow run {runIndex} is not Running.");
        }
    }

    private static async Task<WorkflowStage> ReadStageAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long runIndex,
        string producer,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT status, started_utc, completed_utc, failure_code
            FROM workflow_stages
            WHERE run_index = $runIndex AND producer = $producer;
            """;
        command.Parameters.AddWithValue("$runIndex", runIndex);
        command.Parameters.AddWithValue("$producer", producer);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            throw new InvalidOperationException(
                $"Workflow stage '{producer}' for run {runIndex} does not exist.");
        }

        return new WorkflowStage(
            runIndex,
            producer,
            Enum.Parse<WorkflowStatus>(reader.GetString(0)),
            DateTimeOffset.Parse(reader.GetString(1), CultureInfo.InvariantCulture),
            reader.IsDBNull(2)
                ? null
                : DateTimeOffset.Parse(reader.GetString(2), CultureInfo.InvariantCulture),
            reader.IsDBNull(3) ? null : reader.GetString(3));
    }

    private static void EnsureWorkflowIdentity(
        WorkflowRun workflow,
        string pipeline,
        long? sourceId,
        string ownerComponent)
    {
        if (!StringComparer.Ordinal.Equals(workflow.Pipeline, pipeline)
            || (sourceId is not null && workflow.SourceId != sourceId)
            || !StringComparer.Ordinal.Equals(workflow.OwnerComponent, ownerComponent))
        {
            throw new InvalidOperationException(
                $"Admission '{workflow.AdmissionId}' already belongs to another workflow.");
        }
    }

    private static void EnsureTerminalStatus(WorkflowStatus status)
    {
        if (status == WorkflowStatus.Running)
        {
            throw new ArgumentException("A completed workflow cannot remain Running.", nameof(status));
        }
    }

    private static async Task CompleteLegacyWorkflowInTransactionAsync(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        long runIndex,
        WorkflowStatus status,
        string? failureCode,
        CancellationToken cancellationToken)
    {
        var completedUtc = DateTimeOffset.UtcNow.ToString("O");
        await using (var stage = connection.CreateCommand())
        {
            stage.Transaction = transaction;
            stage.CommandText =
                """
                UPDATE workflow_stages
                SET status = $status, completed_utc = $completedUtc, failure_code = $failureCode
                WHERE run_index = $runIndex
                  AND producer = 'backup-worker'
                  AND status = 'Running';
                """;
            stage.Parameters.AddWithValue("$status", status.ToString());
            stage.Parameters.AddWithValue("$completedUtc", completedUtc);
            stage.Parameters.AddWithValue("$failureCode", (object?)failureCode ?? DBNull.Value);
            stage.Parameters.AddWithValue("$runIndex", runIndex);
            if (await stage.ExecuteNonQueryAsync(cancellationToken) != 1)
            {
                throw new InvalidOperationException(
                    $"Backup workflow stage for run {runIndex} is not Running.");
            }
        }

        await using var workflow = connection.CreateCommand();
        workflow.Transaction = transaction;
        workflow.CommandText =
            """
            UPDATE workflow_runs
            SET status = $status, completed_utc = $completedUtc, failure_code = $failureCode
            WHERE run_index = $runIndex
              AND owner_component = 'backup-worker'
              AND status = 'Running';
            """;
        workflow.Parameters.AddWithValue("$status", status.ToString());
        workflow.Parameters.AddWithValue("$completedUtc", completedUtc);
        workflow.Parameters.AddWithValue("$failureCode", (object?)failureCode ?? DBNull.Value);
        workflow.Parameters.AddWithValue("$runIndex", runIndex);
        await workflow.ExecuteNonQueryAsync(cancellationToken);
    }
}
