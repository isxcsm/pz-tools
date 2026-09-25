using PzTools.Process.Contracts;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public async Task<CommittedRevision> CommitInitialRevisionFromStagingAsync(
        RepositoryWriterLease lease,
        SqliteConnection stagingConnection,
        long runIndex,
        long sourceId,
        SourceCheckpoint? checkpoint,
        PackRegistration? pack,
        CancellationToken cancellationToken = default,
        Action? beforeTransactionCommit = null,
        long? requestedRevision = null,
        SupportedLanguage nameLanguage = SupportedLanguage.Korean)
    {
        EnsureLease(lease);
        ArgumentNullException.ThrowIfNull(stagingConnection);
        if (!StringComparer.OrdinalIgnoreCase.Equals(
            Path.GetFullPath(stagingConnection.DataSource),
            DatabasePath))
        {
            throw new ArgumentException(
                "The staging connection belongs to another repository.",
                nameof(stagingConnection));
        }

        using var transaction = stagingConnection.BeginTransaction();
        try
        {
            var request = new RevisionCommitRequest(
                runIndex,
                sourceId,
                checkpoint,
                Packs: [],
                Objects: [],
                Entries: [],
                NameLanguage: nameLanguage);
            var currentRevision = await ReadCurrentRevisionAsync(
                stagingConnection,
                transaction,
                request,
                cancellationToken);
            if (currentRevision != 0)
            {
                throw new InvalidOperationException(
                    $"Source {sourceId} already has revision {currentRevision}; initial commit refused.");
            }

            await EnsureAllFilesCapturedAsync(stagingConnection, transaction, cancellationToken);
            var revision = ResolveRevision(currentRevision, requestedRevision);
            var createdUtc = DateTimeOffset.UtcNow;
            await InsertRevisionAsync(
                stagingConnection,
                transaction,
                request,
                revision,
                createdUtc,
                cancellationToken);

            if (pack is not null)
            {
                await InsertPacksAsync(
                    stagingConnection,
                    transaction,
                    request with { Packs = [pack] },
                    createdUtc,
                    cancellationToken);
            }

            await InsertStagedObjectsAsync(
                stagingConnection,
                transaction,
                cancellationToken);
            await InsertStagedEntriesAsync(
                stagingConnection,
                transaction,
                sourceId,
                revision,
                cancellationToken);
            await UpdateSourceStateAsync(
                stagingConnection,
                transaction,
                sourceId,
                revision,
                checkpoint,
                cancellationToken);
            await CompleteRunInTransactionAsync(
                stagingConnection,
                transaction,
                runIndex,
                cancellationToken);
            await IncrementRepositoryChangeRevisionAsync(
                stagingConnection, transaction, cancellationToken);
            beforeTransactionCommit?.Invoke();
            transaction.Commit();
            return new CommittedRevision(sourceId, revision, runIndex, createdUtc);
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    private static async Task EnsureAllFilesCapturedAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT COUNT(*)
            FROM full_scan_entries
            WHERE entry_kind = 'File' AND object_id IS NULL;
            """;
        var missing = Convert.ToInt64(
            await command.ExecuteScalarAsync(cancellationToken),
            System.Globalization.CultureInfo.InvariantCulture);
        if (missing != 0)
        {
            throw new InvalidOperationException($"{missing} scanned file(s) were not captured.");
        }
    }

    private static async Task InsertStagedObjectsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT OR IGNORE INTO stored_objects(
                object_id, pack_id, pack_offset, stored_length, original_length,
                checksum_algorithm, checksum, compression_algorithm, flags,
                content_hash)
            SELECT object_id, pack_id, record_offset, stored_length, byte_length,
                   checksum_algorithm, checksum, compression_algorithm, object_flags,
                   content_hash
            FROM full_scan_entries
            WHERE entry_kind = 'File';
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task InsertStagedEntriesAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long sourceId,
        long revision,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO entry_versions(
                source_id, path_key, display_path, valid_from_revision,
                entry_kind, tombstone, byte_length, modified_utc, changed_utc,
                attributes, file_id, parent_file_id, object_id)
            SELECT $sourceId, path_key, display_path, $revision,
                   entry_kind, 0, byte_length, modified_utc, changed_utc,
                   attributes, file_id, parent_file_id, object_id
            FROM full_scan_entries;
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        command.Parameters.AddWithValue("$revision", revision);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
