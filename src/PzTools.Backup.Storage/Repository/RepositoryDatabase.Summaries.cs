using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    // Only the requested metadata path needs an interval lookup. File/byte totals
    // are immutable revision metadata, not an aggregate across every historical file.
    internal const string CatalogSummarySql =
        """
        SELECT source.source_id,source.source_key,source.root_path,
               state.current_revision,revision.revision,revision.created_utc,
               revision.logical_size,revision.file_count,revision.state,revision.display_name,
               CASE WHEN $metadataPathKey IS NULL THEN NULL ELSE (
                   SELECT entry.modified_utc FROM entry_versions AS entry
                   WHERE entry.source_id=source.source_id AND entry.path_id=(SELECT path_id FROM paths WHERE path_key=$metadataPathKey)
                     AND entry.valid_from_revision<=revision.revision
                     AND (entry.valid_to_revision IS NULL OR entry.valid_to_revision>revision.revision)
                     AND entry.entry_kind='File' AND entry.tombstone=0
                   ORDER BY entry.valid_from_revision DESC LIMIT 1
               ) END,
               revision.character_name,revision.character_state,revision.backup_kind,
               revision.hours_survived,revision.character_metadata_read,revision.character_metadata_error
        FROM sources AS source
        JOIN source_state AS state ON state.source_id=source.source_id
        LEFT JOIN revisions AS revision
          ON revision.source_id=source.source_id AND revision.state='Active'
        ORDER BY source.source_key COLLATE NOCASE,revision.revision DESC;
        """;

    private static async Task<(long Bytes, long Files)> ReadBaselineSummaryAsync(
        SqliteConnection connection, SqliteTransaction transaction, long sourceId,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT state.current_revision,revision.logical_size,revision.file_count
            FROM source_state AS state
            LEFT JOIN revisions AS revision
              ON revision.source_id=state.source_id AND revision.revision=state.current_revision
            WHERE state.source_id=$sourceId;
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken)) throw new InvalidDataException("Source state is missing.");
        if (reader.GetInt64(0) == 0) return (0, 0);
        if (reader.IsDBNull(1) || reader.IsDBNull(2))
            throw new InvalidDataException("The current incremental baseline has no summary.");
        return (reader.GetInt64(1), reader.GetInt64(2));
    }

    private static async Task StoreRevisionSummaryAsync(
        SqliteConnection connection, SqliteTransaction transaction, long sourceId, long revision,
        long bytes, long files, CancellationToken cancellationToken)
    {
        if (bytes < 0 || files < 0) throw new InvalidDataException("Revision summary would be negative.");
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            UPDATE revisions SET logical_size=$bytes,file_count=$files
            WHERE source_id=$sourceId AND revision=$revision;
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        command.Parameters.AddWithValue("$revision", revision);
        command.Parameters.AddWithValue("$bytes", bytes);
        command.Parameters.AddWithValue("$files", files);
        if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
            throw new InvalidDataException("Revision summary target is missing.");
    }

    private static async Task InitializeRevisionSummaryAsync(
        SqliteConnection connection, SqliteTransaction transaction, long sourceId, long revision,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT COALESCE(SUM(byte_length),0),COUNT(*) FROM full_scan_entries WHERE entry_kind='File';
            """;
        long bytes, files;
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            await reader.ReadAsync(cancellationToken);
            bytes = reader.GetInt64(0);
            files = reader.GetInt64(1);
        }
        await StoreRevisionSummaryAsync(connection, transaction, sourceId, revision, bytes, files, cancellationToken);
    }

    private static async Task ApplyEntriesAsync(
        SqliteConnection connection, SqliteTransaction transaction, RevisionCommitRequest request,
        long revision, CancellationToken cancellationToken)
    {
        // source_state still points at the prior revision, including a Deleted
        // latest revision retained as an internal incremental baseline.
        var (bytes, files) = await ReadBaselineSummaryAsync(
            connection, transaction, request.SourceId, cancellationToken);
        await using var paths = new RepositoryPathWriter(connection, transaction);
        await using var close = connection.CreateCommand();
        close.Transaction = transaction;
        close.CommandText =
            """
            UPDATE entry_versions SET valid_to_revision=$revision
            WHERE source_id=$sourceId AND path_id=$pathId AND valid_to_revision IS NULL
            RETURNING entry_kind,tombstone,byte_length;
            """;
        close.Parameters.AddWithValue("$sourceId", request.SourceId);
        close.Parameters.AddWithValue("$revision", revision);
        close.Parameters.AddWithValue("$pathId", "");
        close.Prepare();

        await using var insert = connection.CreateCommand();
        insert.Transaction = transaction;
        insert.CommandText =
            """
            INSERT INTO entry_versions(
                source_id,path_id,spelling_id,valid_from_revision,entry_kind,tombstone,
                byte_length,modified_utc,changed_utc,attributes,file_id,parent_file_id,object_id)
            VALUES($sourceId,$pathId,$spellingId,$revision,$entryKind,$tombstone,
                $byteLength,$modifiedUtc,$changedUtc,$attributes,$fileId,$parentFileId,$objectId);
            """;
        insert.Parameters.AddWithValue("$sourceId", request.SourceId);
        insert.Parameters.AddWithValue("$revision", revision);
        foreach (var name in new[] { "$pathId", "$spellingId", "$entryKind", "$tombstone", "$byteLength",
                     "$modifiedUtc", "$changedUtc", "$attributes", "$fileId", "$parentFileId", "$objectId" })
            insert.Parameters.AddWithValue(name, DBNull.Value);
        insert.Prepare();

        foreach (var entry in request.Entries)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var displayPath = BackupPath.NormalizeRelative(entry.RelativePath);
            var (pathId, spellingId) = await paths.InternAsync(displayPath, cancellationToken);
            close.Parameters["$pathId"].Value = pathId;
            await using (var reader = await close.ExecuteReaderAsync(cancellationToken))
            {
                while (await reader.ReadAsync(cancellationToken))
                {
                    if (reader.GetString(0) != "File" || reader.GetBoolean(1)) continue;
                    bytes = checked(bytes - reader.GetInt64(2));
                    files = checked(files - 1);
                }
            }

            insert.Parameters["$pathId"].Value = pathId;
            insert.Parameters["$spellingId"].Value = spellingId;
            insert.Parameters["$entryKind"].Value = entry.Kind.ToString();
            insert.Parameters["$tombstone"].Value = entry.Tombstone ? 1 : 0;
            insert.Parameters["$byteLength"].Value = entry.ByteLength;
            insert.Parameters["$modifiedUtc"].Value = entry.ModifiedUtc.UtcTicks;
            insert.Parameters["$changedUtc"].Value = entry.ChangedUtc.UtcTicks;
            insert.Parameters["$attributes"].Value = (long)entry.Attributes;
            insert.Parameters["$fileId"].Value = (object?)entry.FileId ?? DBNull.Value;
            insert.Parameters["$parentFileId"].Value = (object?)entry.ParentFileId ?? DBNull.Value;
            insert.Parameters["$objectId"].Value = entry.ObjectId is null ? DBNull.Value : entry.ObjectId.Value.ToByteArray();
            await insert.ExecuteNonQueryAsync(cancellationToken);
            if (entry.Kind == CatalogEntryKind.File && !entry.Tombstone)
            {
                bytes = checked(bytes + entry.ByteLength);
                files = checked(files + 1);
            }
        }
        await StoreRevisionSummaryAsync(connection, transaction, request.SourceId, revision, bytes, files, cancellationToken);
    }
}
