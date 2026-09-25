using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed class StreamingFullScanner(IFileMetadataReader metadataReader, int batchSize = 512)
{
    public async Task<FullScanSession> ScanAsync(
        RepositoryDatabase repository,
        long sourceId,
        string sourceRoot,
        CancellationToken cancellationToken = default,
        Func<long, ValueTask>? progress = null)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceRoot);
        var absoluteRoot = Path.GetFullPath(sourceRoot);
        if (!Directory.Exists(absoluteRoot))
        {
            throw new DirectoryNotFoundException($"Source directory '{absoluteRoot}' does not exist.");
        }

        var connection = await repository.OpenConnectionAsync(cancellationToken);
        try
        {
            await CreateStagingTableAsync(connection, cancellationToken);
            if (progress is not null) await progress(0);
            var count = await PopulateAsync(connection, absoluteRoot, cancellationToken, progress);
            return new FullScanSession(connection, sourceId, absoluteRoot, count);
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }

    private async Task<long> PopulateAsync(
        SqliteConnection connection,
        string sourceRoot,
        CancellationToken cancellationToken,
        Func<long, ValueTask>? progress)
    {
        long count = 0;
        if (batchSize <= 0) throw new ArgumentOutOfRangeException(nameof(batchSize));
        SqliteTransaction? transaction = null;
        await using var insert = CreateInsertCommand(connection);
        try
        {
            foreach (var item in EnumerateTree(sourceRoot, metadataReader))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if ((item.Metadata.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    continue;
                }

                // This batch writes TEMP staging only; do not reserve the main DB writer.
                transaction ??= connection.BeginTransaction(deferred: true);
                var relativePath = BackupPath.NormalizeRelative(
                    Path.GetRelativePath(sourceRoot, item.Path));
                await InsertEntryAsync(
                    insert,
                    transaction,
                    relativePath,
                    (item.Metadata.Attributes & FileAttributes.Directory) != 0
                        ? CatalogEntryKind.Directory
                        : CatalogEntryKind.File,
                    item.Metadata,
                    item.ParentFileId,
                    cancellationToken);
                count++;
                if (progress is not null) await progress(count);

                if (count % batchSize == 0)
                {
                    transaction.Commit();
                    transaction.Dispose();
                    transaction = null;
                }
            }

            transaction?.Commit();
            return count;
        }
        catch
        {
            transaction?.Rollback();
            throw;
        }
        finally
        {
            transaction?.Dispose();
        }
    }

    private static IEnumerable<EnumeratedPath> EnumerateTree(
        string sourceRoot,
        IFileMetadataReader metadataReader)
    {
        var rootMetadata = metadataReader.ReadPath(sourceRoot);
        var enumerators = new Stack<DirectoryFrame>();
        enumerators.Push(new DirectoryFrame(
            Directory.EnumerateFileSystemEntries(sourceRoot).GetEnumerator(),
            FileIdentityCodec.Encode(rootMetadata.Identity)));
        try
        {
            while (enumerators.Count > 0)
            {
                var current = enumerators.Peek();
                if (!current.Enumerator.MoveNext())
                {
                    current.Enumerator.Dispose();
                    enumerators.Pop();
                    continue;
                }

                var path = current.Enumerator.Current;
                var metadata = metadataReader.ReadPath(path);
                yield return new EnumeratedPath(path, metadata, current.DirectoryFileId);
                if ((metadata.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint))
                    == FileAttributes.Directory)
                {
                    enumerators.Push(new DirectoryFrame(
                        Directory.EnumerateFileSystemEntries(path).GetEnumerator(),
                        FileIdentityCodec.Encode(metadata.Identity)));
                }
            }
        }
        finally
        {
            while (enumerators.TryPop(out var frame))
            {
                frame.Enumerator.Dispose();
            }
        }
    }

    private static async Task CreateStagingTableAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            PRAGMA temp_store = FILE;
            CREATE TEMP TABLE full_scan_entries (
                path_key TEXT NOT NULL PRIMARY KEY,
                display_path TEXT NOT NULL,
                entry_kind TEXT NOT NULL,
                byte_length INTEGER NOT NULL,
                modified_utc INTEGER NOT NULL,
                changed_utc INTEGER NOT NULL,
                attributes INTEGER NOT NULL,
                file_id BLOB NOT NULL,
                parent_file_id BLOB NOT NULL,
                object_id BLOB NULL,
                pack_id BLOB NULL,
                record_offset INTEGER NULL,
                stored_length INTEGER NULL,
                checksum_algorithm INTEGER NULL,
                checksum BLOB NULL,
                compression_algorithm INTEGER NULL,
                object_flags INTEGER NULL,
                content_hash BLOB NULL
            ) STRICT;
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static SqliteCommand CreateInsertCommand(SqliteConnection connection)
    {
        var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO full_scan_entries(
                path_key, display_path, entry_kind, byte_length, modified_utc,
                changed_utc, attributes, file_id, parent_file_id)
            VALUES (
                $pathKey, $displayPath, $entryKind, $byteLength, $modifiedUtc,
                $changedUtc, $attributes, $fileId, $parentFileId);
            """;
        foreach (var name in new[] { "$pathKey", "$displayPath", "$entryKind" })
            command.Parameters.Add(name, SqliteType.Text);
        foreach (var name in new[] { "$byteLength", "$modifiedUtc", "$changedUtc", "$attributes" })
            command.Parameters.Add(name, SqliteType.Integer);
        command.Parameters.Add("$fileId", SqliteType.Blob);
        command.Parameters.Add("$parentFileId", SqliteType.Blob);
        command.Prepare();
        return command;
    }

    private static async Task InsertEntryAsync(
        SqliteCommand command,
        SqliteTransaction transaction,
        string relativePath,
        CatalogEntryKind kind,
        FileCaptureMetadata metadata,
        byte[] parentFileId,
        CancellationToken cancellationToken)
    {
        command.Transaction = transaction;
        command.Parameters["$pathKey"].Value = relativePath.ToUpperInvariant();
        command.Parameters["$displayPath"].Value = relativePath;
        command.Parameters["$entryKind"].Value = kind.ToString();
        command.Parameters["$byteLength"].Value = metadata.Length;
        command.Parameters["$modifiedUtc"].Value = metadata.ModifiedUtc.UtcTicks;
        command.Parameters["$changedUtc"].Value = metadata.ChangedUtc.UtcTicks;
        command.Parameters["$attributes"].Value = (long)metadata.Attributes;
        command.Parameters["$fileId"].Value = FileIdentityCodec.Encode(metadata.Identity);
        command.Parameters["$parentFileId"].Value = parentFileId;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private sealed record DirectoryFrame(
        IEnumerator<string> Enumerator,
        byte[] DirectoryFileId);

    private sealed record EnumeratedPath(
        string Path,
        FileCaptureMetadata Metadata,
        byte[] ParentFileId);
}

public sealed class FullScanSession : IAsyncDisposable
{
    private readonly SqliteConnection connection;

    internal FullScanSession(
        SqliteConnection connection,
        long sourceId,
        string sourceRoot,
        long entryCount)
    {
        this.connection = connection;
        SourceId = sourceId;
        SourceRoot = sourceRoot;
        EntryCount = entryCount;
    }

    public long SourceId { get; }

    public string SourceRoot { get; }

    public long EntryCount { get; }

    internal SqliteConnection Connection => connection;

    public async Task<(long Files, long Bytes)> ReadFileWorkloadAsync(
        CancellationToken cancellationToken = default)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT COUNT(*),COALESCE(SUM(byte_length),0)
            FROM full_scan_entries WHERE entry_kind='File';
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        await reader.ReadAsync(cancellationToken);
        return (reader.GetInt64(0), reader.GetInt64(1));
    }

    public async Task StageCapturedFileAsync(
        string relativePath,
        Guid packId,
        StableFileCaptureResult captured,
        CancellationToken cancellationToken = default)
    {
        var normalizedPath = BackupPath.NormalizeRelative(relativePath);
        var metadata = captured.SourceMetadata;
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            UPDATE full_scan_entries
            SET byte_length = $byteLength,
                modified_utc = $modifiedUtc,
                changed_utc = $changedUtc,
                attributes = $attributes,
                file_id = $fileId,
                object_id = $objectId,
                pack_id = $packId,
                record_offset = $recordOffset,
                stored_length = $storedLength,
                checksum_algorithm = $checksumAlgorithm,
                checksum = $checksum,
                compression_algorithm = $compressionAlgorithm,
                object_flags = $objectFlags,
                content_hash = $contentHash
            WHERE path_key = $pathKey AND entry_kind = 'File';
            """;
        command.Parameters.AddWithValue("$byteLength", metadata.Length);
        command.Parameters.AddWithValue("$modifiedUtc", metadata.ModifiedUtc.UtcTicks);
        command.Parameters.AddWithValue("$changedUtc", metadata.ChangedUtc.UtcTicks);
        command.Parameters.AddWithValue("$attributes", (long)metadata.Attributes);
        command.Parameters.AddWithValue(
            "$fileId",
            FileIdentityCodec.Encode(metadata.Identity));
        command.Parameters.AddWithValue("$objectId", captured.Object.ObjectId.ToByteArray());
        command.Parameters.AddWithValue("$packId", packId.ToByteArray());
        command.Parameters.AddWithValue("$recordOffset", captured.Object.RecordOffset);
        command.Parameters.AddWithValue("$storedLength", captured.Object.StoredLength);
        command.Parameters.AddWithValue(
            "$checksumAlgorithm",
            (int)captured.Object.ChecksumAlgorithm);
        command.Parameters.AddWithValue("$checksum", captured.Object.Checksum);
        command.Parameters.AddWithValue(
            "$compressionAlgorithm",
            (int)captured.Object.CompressionAlgorithm);
        command.Parameters.AddWithValue("$objectFlags", captured.Object.Flags);
        command.Parameters.AddWithValue("$contentHash",
            (object?)captured.ContentHash ?? DBNull.Value);
        command.Parameters.AddWithValue("$pathKey", normalizedPath.ToUpperInvariant());
        if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
        {
            throw new InvalidOperationException(
                $"Scanned file '{normalizedPath}' is missing from staging.");
        }
    }

    public async IAsyncEnumerable<FullScanEntry> EnumerateEntriesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT path_key, display_path, entry_kind, byte_length, modified_utc,
                   changed_utc, attributes, file_id, parent_file_id
            FROM full_scan_entries
            ORDER BY path_key;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            yield return ReadEntry(reader, columnOffset: 0);
        }
    }

    internal const string ChangeEnumerationSql =
            """
            WITH current_entries AS (
                SELECT path_key, display_path, entry_kind, byte_length, modified_utc,
                       changed_utc, attributes, file_id, parent_file_id
                FROM current_entry_catalog
                WHERE source_id = $sourceId
                  AND valid_to_revision IS NULL
                  AND tombstone = 0
            )
            SELECT 'Added', scan.path_key, scan.display_path, scan.entry_kind,
                   scan.byte_length, scan.modified_utc, scan.changed_utc,
                   scan.attributes, scan.file_id, scan.parent_file_id
            FROM full_scan_entries AS scan
            WHERE NOT EXISTS (
                SELECT 1 FROM paths AS lookup_path
                JOIN entry_versions AS live INDEXED BY ix_entry_versions_current
                  ON live.path_id=lookup_path.path_id
                WHERE lookup_path.path_key=scan.path_key AND live.source_id=$sourceId
                  AND live.valid_to_revision IS NULL AND live.tombstone=0
            )

            UNION ALL

            SELECT 'Modified', scan.path_key, scan.display_path, scan.entry_kind,
                   scan.byte_length, scan.modified_utc, scan.changed_utc,
                   scan.attributes, scan.file_id, scan.parent_file_id
            FROM full_scan_entries AS scan
            JOIN current_entries AS current ON current.path_key = scan.path_key
            WHERE current.display_path <> scan.display_path
               OR current.entry_kind <> scan.entry_kind
               OR current.byte_length <> scan.byte_length
               OR current.modified_utc <> scan.modified_utc
               OR current.changed_utc <> scan.changed_utc
               OR current.attributes <> scan.attributes
               OR NOT (current.file_id IS scan.file_id)
               OR NOT (current.parent_file_id IS scan.parent_file_id)

            UNION ALL

            SELECT 'Deleted', current.path_key, current.display_path,
                   current.entry_kind, current.byte_length, current.modified_utc,
                   current.changed_utc, current.attributes, current.file_id,
                   current.parent_file_id
            FROM current_entries AS current
            LEFT JOIN full_scan_entries AS scan ON scan.path_key = current.path_key
            WHERE scan.path_key IS NULL

            ORDER BY 2;
            """;

    public async IAsyncEnumerable<FullScanChange> EnumerateChangesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            ChangeEnumerationSql;
        command.Parameters.AddWithValue("$sourceId", SourceId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            yield return new FullScanChange(
                Enum.Parse<FullScanChangeKind>(reader.GetString(0)),
                ReadEntry(reader, columnOffset: 1));
        }
    }

    public async IAsyncEnumerable<(FullScanEntry Entry, byte[]? PreviousHash)> EnumerateContentComparisonsAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT scan.path_key, scan.display_path, scan.entry_kind, scan.byte_length,
                   scan.modified_utc, scan.changed_utc, scan.attributes,
                   scan.file_id, scan.parent_file_id,
                   COALESCE(object.content_hash,
                       CASE WHEN object.checksum_algorithm=3 AND length(object.checksum)=32
                           THEN substr(object.checksum, 1, 16) END)
            FROM full_scan_entries AS scan
            JOIN paths AS path ON path.path_key = scan.path_key
            JOIN entry_versions AS current ON current.source_id = $sourceId
                AND current.path_id = path.path_id AND current.valid_to_revision IS NULL
                AND current.tombstone = 0
            LEFT JOIN stored_objects AS object ON object.object_id = current.object_id
            WHERE scan.entry_kind = 'File'
            ORDER BY scan.path_key;
            """;
        command.Parameters.AddWithValue("$sourceId", SourceId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            yield return (ReadEntry(reader, 0), reader.IsDBNull(9) ? null : (byte[])reader.GetValue(9));
    }

    public ValueTask DisposeAsync() => connection.DisposeAsync();

    private static FullScanEntry ReadEntry(SqliteDataReader reader, int columnOffset)
    {
        return new FullScanEntry(
            reader.GetString(columnOffset),
            reader.GetString(columnOffset + 1),
            Enum.Parse<CatalogEntryKind>(reader.GetString(columnOffset + 2)),
            reader.GetInt64(columnOffset + 3),
            new DateTimeOffset(reader.GetInt64(columnOffset + 4), TimeSpan.Zero),
            new DateTimeOffset(reader.GetInt64(columnOffset + 5), TimeSpan.Zero),
            (FileAttributes)reader.GetInt64(columnOffset + 6),
            reader.IsDBNull(columnOffset + 7) ? [] : (byte[])reader.GetValue(columnOffset + 7),
            reader.IsDBNull(columnOffset + 8) ? [] : (byte[])reader.GetValue(columnOffset + 8));
    }
}
