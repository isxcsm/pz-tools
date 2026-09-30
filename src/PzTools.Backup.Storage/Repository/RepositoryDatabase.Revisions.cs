using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public async Task<CommittedRevision> CommitRevisionAsync(
        RepositoryWriterLease lease,
        RevisionCommitRequest request,
        CancellationToken cancellationToken = default,
        Action? beforeTransactionCommit = null)
    {
        EnsureLease(lease);
        ArgumentNullException.ThrowIfNull(request);
        ValidateCommitRequest(request);

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            var currentRevision = await ReadCurrentRevisionAsync(
                connection,
                transaction,
                request,
                cancellationToken);
            var revision = ResolveRevision(currentRevision, request.RequestedRevision);
            var createdUtc = DateTimeOffset.UtcNow;

            await InsertRevisionAsync(
                connection,
                transaction,
                request,
                revision,
                createdUtc,
                cancellationToken);
            await InsertPacksAsync(
                connection,
                transaction,
                request,
                createdUtc,
                cancellationToken);
            await InsertObjectsAsync(connection, transaction, request, cancellationToken);
            await ApplyEntriesAsync(
                connection,
                transaction,
                request,
                revision,
                cancellationToken);
            await UpdateSourceStateAsync(
                connection,
                transaction,
                request.SourceId,
                revision,
                request.Checkpoint,
                cancellationToken);
            await CompleteRunInTransactionAsync(
                connection,
                transaction,
                request.RunIndex,
                cancellationToken);
            await IncrementRepositoryChangeRevisionAsync(
                connection, transaction, cancellationToken);
            beforeTransactionCommit?.Invoke();

            transaction.Commit();
            return new CommittedRevision(
                request.SourceId,
                revision,
                request.RunIndex,
                createdUtc);
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    private static async Task<long> ReadCurrentRevisionAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        RevisionCommitRequest request,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT state.current_revision
            FROM source_state AS state
            JOIN runs AS run ON run.source_id = state.source_id
            WHERE state.source_id = $sourceId
              AND run.run_index = $runIndex
              AND run.status = 'Running';
            """;
        command.Parameters.AddWithValue("$sourceId", request.SourceId);
        command.Parameters.AddWithValue("$runIndex", request.RunIndex);
        var value = await command.ExecuteScalarAsync(cancellationToken);
        return value is null
            ? throw new InvalidOperationException(
                "The source or running run does not exist, or the run targets another source.")
            : Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static async Task InsertRevisionAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        RevisionCommitRequest request,
        long revision,
        DateTimeOffset createdUtc,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT EXISTS(SELECT 1 FROM workflow_runs
                WHERE run_index = $runIndex AND pipeline = 'backup-maintenance'
                  AND owner_component = 'backup-scheduler');
            """;
        command.Parameters.AddWithValue("$runIndex", request.RunIndex);
        // The reserved workflow is the authority for origin, including initial and incremental runs.
        // Direct CLI/engine captures are manual; only the scheduler can create automatic backups.
        var kind = Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken)) == 1
            ? BackupKind.Automatic : BackupKind.Manual;
        command.CommandText =
            """
            INSERT INTO revisions(source_id, revision, run_index, created_utc, display_name, backup_kind, game_version)
            VALUES ($sourceId, $revision, $runIndex, $createdUtc, $displayName, $kind, $gameVersion);
            """;
        var gameVersion = request.GameVersion?.Trim();
        if (gameVersion is { Length: > 80 } || gameVersion?.Any(char.IsControl) == true)
            throw new ArgumentException("Game version must be at most 80 printable characters.", nameof(request));
        command.Parameters.AddWithValue("$gameVersion", string.IsNullOrEmpty(gameVersion) ? DBNull.Value : gameVersion);
        command.Parameters.AddWithValue("$sourceId", request.SourceId);
        command.Parameters.AddWithValue("$revision", revision);
        command.Parameters.AddWithValue("$createdUtc", createdUtc.ToString("O"));
        command.Parameters.AddWithValue("$displayName", DefaultRevisionName(revision, request.NameLanguage, kind));
        command.Parameters.AddWithValue("$kind", kind.ToString());
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task InsertPacksAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        RevisionCommitRequest request,
        DateTimeOffset createdUtc,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO packs(
                pack_id, relative_path, format_version, byte_length, status,
                created_run_index, created_utc)
            VALUES (
                $packId, $relativePath, $formatVersion, $byteLength, 'Committed',
                $runIndex, $createdUtc);
            """;
        foreach (var name in new[] { "$packId", "$relativePath", "$formatVersion", "$byteLength", "$runIndex", "$createdUtc" })
            command.Parameters.AddWithValue(name, DBNull.Value);
        command.Prepare();
        foreach (var pack in request.Packs)
        {
            cancellationToken.ThrowIfCancellationRequested();
            command.Parameters["$packId"].Value = pack.PackId.ToByteArray();
            command.Parameters["$relativePath"].Value = pack.RelativePath;
            command.Parameters["$formatVersion"].Value = pack.FormatVersion;
            command.Parameters["$byteLength"].Value = pack.ByteLength;
            command.Parameters["$runIndex"].Value = request.RunIndex;
            command.Parameters["$createdUtc"].Value = createdUtc.ToString("O");
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task InsertObjectsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        RevisionCommitRequest request,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO stored_objects(
                object_id, pack_id, pack_offset, stored_length, original_length,
                checksum_algorithm, checksum, compression_algorithm, flags,
                content_hash)
            VALUES (
                $objectId, $packId, $packOffset, $storedLength, $originalLength,
                $checksumAlgorithm, $checksum, $compressionAlgorithm, $flags,
                $contentHash);
            """;
        foreach (var name in new[] { "$objectId", "$packId", "$packOffset", "$storedLength", "$originalLength", "$checksumAlgorithm", "$checksum", "$compressionAlgorithm", "$flags", "$contentHash" })
            command.Parameters.AddWithValue(name, DBNull.Value);
        command.Prepare();
        foreach (var storedObject in request.Objects)
        {
            cancellationToken.ThrowIfCancellationRequested();
            command.Parameters["$objectId"].Value = storedObject.ObjectId.ToByteArray();
            command.Parameters["$packId"].Value = storedObject.PackId.ToByteArray();
            command.Parameters["$packOffset"].Value = storedObject.PackOffset;
            command.Parameters["$storedLength"].Value = storedObject.StoredLength;
            command.Parameters["$originalLength"].Value = storedObject.OriginalLength;
            command.Parameters["$checksumAlgorithm"].Value = StorageAlgorithmCodec.Checksum(storedObject.ChecksumAlgorithm);
            command.Parameters["$checksum"].Value = (object?)storedObject.Checksum ?? DBNull.Value;
            command.Parameters["$compressionAlgorithm"].Value = StorageAlgorithmCodec.Compression(storedObject.CompressionAlgorithm);
            command.Parameters["$flags"].Value = storedObject.Flags;
            command.Parameters["$contentHash"].Value = (object?)storedObject.ContentHash ?? DBNull.Value;
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task UpdateSourceStateAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long sourceId,
        long revision,
        SourceCheckpoint? checkpoint,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            UPDATE source_state
            SET current_revision = $revision,
                volume_identity = $volumeIdentity,
                journal_id = $journalId,
                next_usn = $nextUsn
            WHERE source_id = $sourceId;
            """;
        command.Parameters.AddWithValue("$revision", revision);
        command.Parameters.AddWithValue(
            "$volumeIdentity",
            (object?)checkpoint?.VolumeIdentity ?? DBNull.Value);
        command.Parameters.AddWithValue(
            "$journalId",
            (object?)checkpoint?.JournalId ?? DBNull.Value);
        command.Parameters.AddWithValue("$nextUsn", (object?)checkpoint?.NextUsn ?? DBNull.Value);
        command.Parameters.AddWithValue("$sourceId", sourceId);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task CompleteRunInTransactionAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long runIndex,
        CancellationToken cancellationToken,
        WorkflowStatus workflowStatus = WorkflowStatus.Succeeded)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            UPDATE runs
            SET status = 'Succeeded', completed_utc = $completedUtc
            WHERE run_index = $runIndex AND status = 'Running';
            """;
        command.Parameters.AddWithValue("$completedUtc", DateTimeOffset.UtcNow.ToString("O"));
        command.Parameters.AddWithValue("$runIndex", runIndex);
        if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
        {
            throw new InvalidOperationException($"Run {runIndex} is not Running.");
        }

        await CompleteLegacyWorkflowInTransactionAsync(
            connection,
            transaction,
            runIndex,
            workflowStatus,
            failureCode: null,
            cancellationToken);
    }

    private static long ResolveRevision(long currentRevision, long? requestedRevision)
    {
        if (requestedRevision is null)
        {
            return checked(currentRevision + 1);
        }

        if (requestedRevision <= currentRevision)
        {
            throw new InvalidOperationException(
                $"Requested revision {requestedRevision} must be greater than current revision {currentRevision}.");
        }

        return requestedRevision.Value;
    }

    private static void ValidateCommitRequest(RevisionCommitRequest request)
    {
        var duplicatePack = request.Packs
            .GroupBy(item => item.PackId)
            .FirstOrDefault(group => group.Count() > 1);
        if (duplicatePack is not null)
        {
            throw new ArgumentException($"Duplicate pack id {duplicatePack.Key}.", nameof(request));
        }

        var duplicateObject = request.Objects
            .GroupBy(item => item.ObjectId)
            .FirstOrDefault(group => group.Count() > 1);
        if (duplicateObject is not null)
        {
            throw new ArgumentException(
                $"Duplicate object id {duplicateObject.Key}.",
                nameof(request));
        }

        var duplicatePath = request.Entries
            .GroupBy(
                item => BackupPath.NormalizeRelative(item.RelativePath),
                StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault(group => group.Count() > 1);
        if (duplicatePath is not null)
        {
            throw new ArgumentException(
                $"Duplicate normalized path '{duplicatePath.Key}'.",
                nameof(request));
        }
    }
}
