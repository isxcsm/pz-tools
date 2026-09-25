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
        try
        {
            foreach (var item in EnumerateTree(sourceRoot, metadataReader))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if ((item.Metadata.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    continue;
                }

                transaction ??= connection.BeginTransaction();
                var relativePath = BackupPath.NormalizeRelative(
                    Path.GetRelativePath(sourceRoot, item.Path));
                await InsertEntryAsync(
                    connection,
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
            Encoding.UTF8.GetBytes(rootMetadata.Identity)));
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
                        Encoding.UTF8.GetBytes(metadata.Identity)));
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
                modified_utc TEXT NOT NULL,
                changed_utc TEXT NOT NULL,
                attributes INTEGER NOT NULL,
                file_id BLOB NOT NULL,
                parent_file_id BLOB NOT NULL,
                object_id TEXT NULL,
                pack_id TEXT NULL,
                record_offset INTEGER NULL,
                stored_length INTEGER NULL,
                checksum_algorithm TEXT NULL,
                checksum BLOB NULL,
                compression_algorithm TEXT NULL,
                object_flags INTEGER NULL,
                content_hash_algorithm TEXT NULL,
                content_hash BLOB NULL
            ) STRICT;
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task InsertEntryAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string relativePath,
        CatalogEntryKind kind,
        FileCaptureMetadata metadata,
        byte[] parentFileId,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO full_scan_entries(
                path_key, display_path, entry_kind, byte_length, modified_utc,
                changed_utc, attributes, file_id, parent_file_id)
            VALUES (
                $pathKey, $displayPath, $entryKind, $byteLength, $modifiedUtc,
                $changedUtc, $attributes, $fileId, $parentFileId);
            """;
        command.Parameters.AddWithValue("$pathKey", relativePath.ToUpperInvariant());
        command.Parameters.AddWithValue("$displayPath", relativePath);
        command.Parameters.AddWithValue("$entryKind", kind.ToString());
        command.Parameters.AddWithValue("$byteLength", metadata.Length);
        command.Parameters.AddWithValue("$modifiedUtc", metadata.ModifiedUtc.ToString("O"));
        command.Parameters.AddWithValue("$changedUtc", metadata.ChangedUtc.ToString("O"));
        command.Parameters.AddWithValue("$attributes", (long)metadata.Attributes);
        command.Parameters.AddWithValue("$fileId", Encoding.UTF8.GetBytes(metadata.Identity));
        command.Parameters.AddWithValue("$parentFileId", parentFileId);
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
                content_hash_algorithm = $contentHashAlgorithm,
                content_hash = $contentHash
            WHERE path_key = $pathKey AND entry_kind = 'File';
            """;
        command.Parameters.AddWithValue("$byteLength", metadata.Length);
        command.Parameters.AddWithValue("$modifiedUtc", metadata.ModifiedUtc.ToString("O"));
        command.Parameters.AddWithValue("$changedUtc", metadata.ChangedUtc.ToString("O"));
        command.Parameters.AddWithValue("$attributes", (long)metadata.Attributes);
        command.Parameters.AddWithValue(
            "$fileId",
            Encoding.UTF8.GetBytes(metadata.Identity));
        command.Parameters.AddWithValue("$objectId", captured.Object.ObjectId.ToString("D"));
        command.Parameters.AddWithValue("$packId", packId.ToString("D"));
        command.Parameters.AddWithValue("$recordOffset", captured.Object.RecordOffset);
        command.Parameters.AddWithValue("$storedLength", captured.Object.StoredLength);
        command.Parameters.AddWithValue(
            "$checksumAlgorithm",
            captured.Object.ChecksumAlgorithm.ToString());
        command.Parameters.AddWithValue("$checksum", captured.Object.Checksum);
        command.Parameters.AddWithValue(
            "$compressionAlgorithm",
            captured.Object.CompressionAlgorithm.ToString());
        command.Parameters.AddWithValue("$objectFlags", captured.Object.Flags);
        command.Parameters.AddWithValue("$contentHashAlgorithm",
            (object?)captured.ContentHashAlgorithm ?? DBNull.Value);
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

    public async IAsyncEnumerable<FullScanChange> EnumerateChangesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            WITH current_entries AS (
                SELECT path_key, display_path, entry_kind, byte_length, modified_utc,
                       changed_utc, attributes, file_id, parent_file_id
                FROM entry_versions
                WHERE source_id = $sourceId
                  AND valid_to_revision IS NULL
                  AND tombstone = 0
            )
            SELECT 'Added', scan.path_key, scan.display_path, scan.entry_kind,
                   scan.byte_length, scan.modified_utc, scan.changed_utc,
                   scan.attributes, scan.file_id, scan.parent_file_id
            FROM full_scan_entries AS scan
            LEFT JOIN current_entries AS current ON current.path_key = scan.path_key
            WHERE current.path_key IS NULL

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
                   CASE WHEN object.content_hash_algorithm = 'Sha256_128' AND length(object.content_hash) = 16
                            THEN object.content_hash
                        WHEN object.content_hash_algorithm = 'Sha256' AND length(object.content_hash) = 32
                            THEN object.content_hash
                        WHEN object.checksum_algorithm = 'Sha256' AND length(object.checksum) = 32
                            THEN object.checksum ELSE NULL END
            FROM full_scan_entries AS scan
            JOIN entry_versions AS current ON current.source_id = $sourceId
                AND current.path_key = scan.path_key AND current.valid_to_revision IS NULL
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
            DateTimeOffset.Parse(
                reader.GetString(columnOffset + 4),
                CultureInfo.InvariantCulture),
            DateTimeOffset.Parse(
                reader.GetString(columnOffset + 5),
                CultureInfo.InvariantCulture),
            (FileAttributes)reader.GetInt64(columnOffset + 6),
            (byte[])reader.GetValue(columnOffset + 7),
            (byte[])reader.GetValue(columnOffset + 8));
    }
}
