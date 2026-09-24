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
            INSERT INTO revisions(source_id, revision, run_index, created_utc, display_name, backup_kind)
            VALUES ($sourceId, $revision, $runIndex, $createdUtc, $displayName, $kind);
            """;
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
        foreach (var pack in request.Packs)
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
            command.Parameters.AddWithValue("$packId", pack.PackId.ToString("D"));
            command.Parameters.AddWithValue("$relativePath", pack.RelativePath);
            command.Parameters.AddWithValue("$formatVersion", pack.FormatVersion);
            command.Parameters.AddWithValue("$byteLength", pack.ByteLength);
            command.Parameters.AddWithValue("$runIndex", request.RunIndex);
            command.Parameters.AddWithValue("$createdUtc", createdUtc.ToString("O"));
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task InsertObjectsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        RevisionCommitRequest request,
        CancellationToken cancellationToken)
    {
        foreach (var storedObject in request.Objects)
        {
            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                """
                INSERT INTO stored_objects(
                    object_id, pack_id, pack_offset, stored_length, original_length,
                    checksum_algorithm, checksum, compression_algorithm, flags,
                    content_hash_algorithm, content_hash)
                VALUES (
                    $objectId, $packId, $packOffset, $storedLength, $originalLength,
                    $checksumAlgorithm, $checksum, $compressionAlgorithm, $flags,
                    $contentHashAlgorithm, $contentHash);
                """;
            command.Parameters.AddWithValue("$objectId", storedObject.ObjectId.ToString("D"));
            command.Parameters.AddWithValue("$packId", storedObject.PackId.ToString("D"));
            command.Parameters.AddWithValue("$packOffset", storedObject.PackOffset);
            command.Parameters.AddWithValue("$storedLength", storedObject.StoredLength);
            command.Parameters.AddWithValue("$originalLength", storedObject.OriginalLength);
            command.Parameters.AddWithValue(
                "$checksumAlgorithm",
                storedObject.ChecksumAlgorithm);
            command.Parameters.AddWithValue(
                "$checksum",
                (object?)storedObject.Checksum ?? DBNull.Value);
            command.Parameters.AddWithValue(
                "$compressionAlgorithm",
                storedObject.CompressionAlgorithm);
            command.Parameters.AddWithValue("$flags", storedObject.Flags);
            command.Parameters.AddWithValue("$contentHashAlgorithm",
                (object?)storedObject.ContentHashAlgorithm ?? DBNull.Value);
            command.Parameters.AddWithValue("$contentHash",
                (object?)storedObject.ContentHash ?? DBNull.Value);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task ApplyEntriesAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        RevisionCommitRequest request,
        long revision,
        CancellationToken cancellationToken)
    {
        foreach (var entry in request.Entries)
        {
            var displayPath = BackupPath.NormalizeRelative(entry.RelativePath);
            var pathKey = displayPath.ToUpperInvariant();

            await using (var close = connection.CreateCommand())
            {
                close.Transaction = transaction;
                close.CommandText =
                    """
                    UPDATE entry_versions
                    SET valid_to_revision = $revision
                    WHERE source_id = $sourceId
                      AND path_key = $pathKey
                      AND valid_to_revision IS NULL;
                    """;
                close.Parameters.AddWithValue("$revision", revision);
                close.Parameters.AddWithValue("$sourceId", request.SourceId);
                close.Parameters.AddWithValue("$pathKey", pathKey);
                await close.ExecuteNonQueryAsync(cancellationToken);
            }

            await using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText =
                """
                INSERT INTO entry_versions(
                    source_id, path_key, display_path, valid_from_revision,
                    entry_kind, tombstone, byte_length, modified_utc, changed_utc,
                    attributes, file_id, parent_file_id, object_id)
                VALUES (
                    $sourceId, $pathKey, $displayPath, $revision,
                    $entryKind, $tombstone, $byteLength, $modifiedUtc, $changedUtc,
                    $attributes, $fileId, $parentFileId, $objectId);
                """;
            insert.Parameters.AddWithValue("$sourceId", request.SourceId);
            insert.Parameters.AddWithValue("$pathKey", pathKey);
            insert.Parameters.AddWithValue("$displayPath", displayPath);
            insert.Parameters.AddWithValue("$revision", revision);
            insert.Parameters.AddWithValue("$entryKind", entry.Kind.ToString());
            insert.Parameters.AddWithValue("$tombstone", entry.Tombstone ? 1 : 0);
            insert.Parameters.AddWithValue("$byteLength", entry.ByteLength);
            insert.Parameters.AddWithValue("$modifiedUtc", entry.ModifiedUtc.ToString("O"));
            insert.Parameters.AddWithValue("$changedUtc", entry.ChangedUtc.ToString("O"));
            insert.Parameters.AddWithValue("$attributes", (long)entry.Attributes);
            insert.Parameters.AddWithValue("$fileId", (object?)entry.FileId ?? DBNull.Value);
            insert.Parameters.AddWithValue(
                "$parentFileId",
                (object?)entry.ParentFileId ?? DBNull.Value);
            insert.Parameters.AddWithValue(
                "$objectId",
                entry.ObjectId is null ? DBNull.Value : entry.ObjectId.Value.ToString("D"));
            await insert.ExecuteNonQueryAsync(cancellationToken);
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
