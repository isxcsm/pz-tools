using System.Globalization;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public Task<RepositoryCatalogSnapshot> ReadCatalogIfChangedAsync(
        long lastSeenRevision,
        CancellationToken cancellationToken = default) =>
        ReadCatalogIfChangedAsync(lastSeenRevision, metadataFileRelativePath: null, cancellationToken);

    public async Task<RepositoryCatalogSnapshot> ReadCatalogIfChangedAsync(
        long lastSeenRevision,
        string? metadataFileRelativePath,
        CancellationToken cancellationToken = default)
    {
        if (lastSeenRevision < -1)
            throw new ArgumentOutOfRangeException(nameof(lastSeenRevision));

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction(deferred: true);
        await using var revisionCommand = connection.CreateCommand();
        revisionCommand.Transaction = transaction;
        revisionCommand.CommandText =
            "SELECT repository_change_revision FROM repository_info WHERE singleton=1;";
        var repositoryRevision = Convert.ToInt64(
            await revisionCommand.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture);
        if (repositoryRevision == lastSeenRevision)
        {
            transaction.Commit();
            return new RepositoryCatalogSnapshot(false, repositoryRevision, []);
        }

        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = CatalogSummarySql;
        command.Parameters.AddWithValue("$metadataPathKey", metadataFileRelativePath is null
            ? DBNull.Value
            : PzTools.Backup.Core.BackupPath.NormalizeRelative(metadataFileRelativePath).ToUpperInvariant());
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var builders = new Dictionary<long, SourceHistoryBuilder>();
        while (await reader.ReadAsync(cancellationToken))
        {
            var sourceId = reader.GetInt64(0);
            if (!builders.TryGetValue(sourceId, out var source))
            {
                source = new SourceHistoryBuilder(
                    sourceId,
                    reader.GetString(1),
                    reader.GetString(2),
                    reader.GetInt64(3));
                builders.Add(sourceId, source);
            }
            if (!reader.IsDBNull(4))
            {
                source.Revisions.Add(new RepositoryRevisionSummary(
                    reader.GetInt64(4),
                    DateTimeOffset.Parse(reader.GetString(5), CultureInfo.InvariantCulture),
                    reader.GetInt64(6),
                    reader.GetInt64(7),
                    reader.GetString(8),
                    reader.IsDBNull(10) ? null : new DateTimeOffset(reader.GetInt64(10), TimeSpan.Zero),
                    reader.GetString(9),
                    reader.IsDBNull(11) ? null : reader.GetString(11),
                    reader.IsDBNull(12) ? null : reader.GetString(12),
                    Enum.Parse<BackupKind>(reader.GetString(13)),
                    reader.IsDBNull(14) ? null : reader.GetDouble(14), reader.GetBoolean(15),
                    reader.IsDBNull(16) ? null : reader.GetString(16),
                    reader.IsDBNull(17) ? null : reader.GetString(17)));
            }
        }
        transaction.Commit();
        return new RepositoryCatalogSnapshot(
            true,
            repositoryRevision,
            builders.Values.Select(item => new RepositorySourceHistory(
                item.SourceId,
                item.SourceKey,
                item.RootPath,
                item.CurrentRevision,
                item.Revisions)).ToArray());
    }

    private sealed record SourceHistoryBuilder(
        long SourceId,
        string SourceKey,
        string RootPath,
        long CurrentRevision)
    {
        public List<RepositoryRevisionSummary> Revisions { get; } = [];
    }

    public async Task<RevisionFileLocator?> TryLocateRevisionFileAsync(
        long sourceId,
        long revision,
        string relativePath,
        CancellationToken cancellationToken = default)
    {
        if (sourceId <= 0) throw new ArgumentOutOfRangeException(nameof(sourceId));
        if (revision <= 0) throw new ArgumentOutOfRangeException(nameof(revision));
        var normalized = PzTools.Backup.Core.BackupPath.NormalizeRelative(relativePath);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction(deferred: true);
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT entry.display_path,entry.object_id,object.pack_id,pack.relative_path,
                   object.pack_offset,object.stored_length,object.original_length,
                   object.compression_algorithm
            FROM revisions AS revision
            JOIN entry_catalog AS entry
              ON entry.source_id=revision.source_id
             AND entry.valid_from_revision<=revision.revision
             AND (entry.valid_to_revision IS NULL
                  OR entry.valid_to_revision>revision.revision)
            JOIN stored_objects AS object ON object.object_id=entry.object_id
            JOIN packs AS pack ON pack.pack_id=object.pack_id
            WHERE revision.source_id=$sourceId AND revision.revision=$revision
              AND revision.state='Active' AND entry.path_id=(SELECT path_id FROM paths WHERE path_key=$pathKey)
              AND entry.entry_kind='File' AND entry.tombstone=0
              AND pack.status='Committed';
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        command.Parameters.AddWithValue("$revision", revision);
        command.Parameters.AddWithValue("$pathKey", normalized.ToUpperInvariant());
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        RevisionFileLocator? locator = null;
        if (await reader.ReadAsync(cancellationToken))
        {
            locator = new RevisionFileLocator(
                sourceId, revision, reader.GetString(0),
                reader.GetGuid(1), reader.GetGuid(2),
                reader.GetString(3), reader.GetInt64(4), reader.GetInt64(5),
                reader.GetInt64(6), StorageAlgorithmCodec.Compression(reader.GetInt32(7)));
        }
        transaction.Commit();
        return locator;
    }

    public async Task<bool> CurrentEntriesHaveCompleteIdentityAsync(
        long sourceId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT NOT EXISTS (
                SELECT 1
                FROM entry_versions
                WHERE source_id = $sourceId
                  AND valid_to_revision IS NULL
                  AND tombstone = 0
                  AND (file_id IS NULL OR parent_file_id IS NULL)
                LIMIT 1
            );
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        return Convert.ToInt32(
            await command.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture) != 0;
    }

    public async Task<IReadOnlyList<CurrentTrackedPath>> ReadCurrentTrackedPathsAsync(
        long sourceId,
        IReadOnlyCollection<string> fileReferences,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(fileReferences);
        if (fileReferences.Count == 0)
        {
            return [];
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using (var create = connection.CreateCommand())
        {
            create.CommandText = "CREATE TEMP TABLE requested_file_references(value BLOB PRIMARY KEY) WITHOUT ROWID;";
            await create.ExecuteNonQueryAsync(cancellationToken);
        }
        using (var transaction = connection.BeginTransaction(deferred: true))
        {
            await using var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText = "INSERT OR IGNORE INTO requested_file_references(value) VALUES ($value);";
            var value = insert.Parameters.Add("$value", SqliteType.Blob);
            foreach (var reference in fileReferences)
            {
                var bytes = Convert.FromHexString(reference);
                if (bytes.Length != 16) throw new ArgumentException("Expected a 128-bit file reference.", nameof(fileReferences));
                value.Value = bytes;
                await insert.ExecuteNonQueryAsync(cancellationToken);
            }
            transaction.Commit();
        }
        await using var command = connection.CreateCommand();
        command.CommandText = fileReferences.Count <= RequestDrivenLookupThreshold
            ? TrackedPathsRequestFirstSql : TrackedPathsScanSql;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var entries = new List<CurrentTrackedPath>();
        while (await reader.ReadAsync(cancellationToken))
        {
            entries.Add(new CurrentTrackedPath(
                reader.GetString(0),
                reader.GetString(1),
                (byte[])reader.GetValue(2),
                (byte[])reader.GetValue(3)));
        }

        return entries;
    }

    public async Task<IReadOnlyList<RevisionEntry>> ReadCurrentEntriesByPathsAsync(
        long sourceId,
        IReadOnlyCollection<string> relativePaths,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(relativePaths);
        if (relativePaths.Count == 0)
        {
            return [];
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        await CreateValueTableAsync(
            connection,
            "requested_paths",
            "path_key",
            relativePaths.Select(path => path.ToUpperInvariant()),
            cancellationToken);
        return await ReadCurrentEntriesAsync(
            connection,
            sourceId,
            relativePaths.Count <= RequestDrivenLookupThreshold ? PathsRequestFirstFrom : PathsScanFrom,
            cancellationToken);
    }

    public async Task<IReadOnlyList<RevisionEntry>> ReadCurrentEntriesUnderRootsAsync(
        long sourceId,
        IReadOnlyCollection<string> relativeRoots,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(relativeRoots);
        if (relativeRoots.Count == 0)
        {
            return [];
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        await CreateValueTableAsync(
            connection,
            "requested_roots",
            "path_key",
            relativeRoots.Select(path => BackupPath.NormalizeRelative(path).ToUpperInvariant()),
            cancellationToken);
        return await ReadCurrentEntriesAsync(
            connection,
            sourceId,
            RootsRangeFrom,
            cancellationToken);
    }

    public async Task<IReadOnlyList<DeduplicationCandidate>> FindDeduplicationCandidatesAsync(
        long originalLength,
        byte[] sha256,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(sha256);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT object.object_id, object.pack_id, pack.relative_path,
                   object.pack_offset, object.stored_length, object.original_length,
                   object.checksum_algorithm, object.checksum,
                   object.compression_algorithm, object.flags
            FROM stored_objects AS object
            JOIN packs AS pack ON pack.pack_id = object.pack_id
            WHERE pack.status = 'Committed'
              AND object.original_length = $length
              AND object.checksum_algorithm = 3
              AND object.checksum = $checksum;
            """;
        command.Parameters.AddWithValue("$length", originalLength);
        command.Parameters.AddWithValue("$checksum", sha256);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var candidates = new List<DeduplicationCandidate>();
        while (await reader.ReadAsync(cancellationToken))
        {
            candidates.Add(new DeduplicationCandidate(
                reader.GetGuid(0),
                reader.GetGuid(1),
                reader.GetString(2),
                reader.GetInt64(3),
                reader.GetInt64(4),
                reader.GetInt64(5),
                StorageAlgorithmCodec.Checksum(reader.GetInt32(6)),
                (byte[])reader.GetValue(7),
                StorageAlgorithmCodec.Compression(reader.GetInt32(8)),
                reader.GetInt32(9)));
        }

        return candidates;
    }

    public async Task<IReadOnlyList<RevisionEntry>> ReadRevisionEntriesAsync(
        long sourceId,
        long revision,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        return await ReadRevisionEntriesCoreAsync(connection, sourceId, revision, cancellationToken);
    }

    internal static async Task<IReadOnlyList<RevisionEntry>> ReadRevisionEntriesCoreAsync(
        SqliteConnection connection,
        long sourceId,
        long revision,
        CancellationToken cancellationToken = default)
    {
        // A revision can be reclaimed between these queries. Keep existence and
        // entries in one snapshot so a removed revision cannot appear empty.
        using var transaction = connection.BeginTransaction(deferred: true);
        await EnsureRevisionExistsAsync(connection, transaction, sourceId, revision, cancellationToken);
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT entry.display_path, entry.entry_kind, entry.byte_length,
                   entry.modified_utc, entry.changed_utc, entry.attributes,
                   entry.file_id, entry.parent_file_id, entry.object_id,
                   object.pack_id, pack.relative_path, object.pack_offset,
                   object.stored_length, object.original_length,
                   object.checksum_algorithm, object.checksum,
                   object.compression_algorithm, object.flags
            FROM entry_catalog AS entry
            LEFT JOIN stored_objects AS object ON object.object_id = entry.object_id
            LEFT JOIN packs AS pack ON pack.pack_id = object.pack_id
            WHERE entry.source_id = $sourceId
              AND entry.valid_from_revision <= $revision
              AND (entry.valid_to_revision IS NULL OR entry.valid_to_revision > $revision)
              AND entry.tombstone = 0
            ORDER BY entry.path_key;
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        command.Parameters.AddWithValue("$revision", revision);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var entries = new List<RevisionEntry>();
        while (await reader.ReadAsync(cancellationToken))
        {
            entries.Add(new RevisionEntry(
                reader.GetString(0),
                reader.GetString(1),
                reader.GetInt64(2),
                new DateTimeOffset(reader.GetInt64(3), TimeSpan.Zero),
                new DateTimeOffset(reader.GetInt64(4), TimeSpan.Zero),
                (FileAttributes)reader.GetInt64(5),
                reader.IsDBNull(6) ? null : (byte[])reader.GetValue(6),
                reader.IsDBNull(7) ? null : (byte[])reader.GetValue(7),
                reader.IsDBNull(8) ? null : reader.GetGuid(8),
                reader.IsDBNull(9) ? null : reader.GetGuid(9),
                reader.IsDBNull(10) ? null : reader.GetString(10),
                reader.IsDBNull(11) ? null : reader.GetInt64(11),
                reader.IsDBNull(12) ? null : reader.GetInt64(12),
                reader.IsDBNull(13) ? null : reader.GetInt64(13),
                reader.IsDBNull(14) ? null : StorageAlgorithmCodec.Checksum(reader.GetInt32(14)),
                reader.IsDBNull(15) ? null : (byte[])reader.GetValue(15),
                reader.IsDBNull(16) ? null : StorageAlgorithmCodec.Compression(reader.GetInt32(16)),
                reader.IsDBNull(17) ? null : reader.GetInt32(17)));
        }

        await reader.DisposeAsync();
        transaction.Commit();
        return entries;
    }

    public async Task<IReadOnlyList<RepositoryPack>> ReadPacksAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT pack_id, relative_path, byte_length, status, created_run_index
            FROM packs
            ORDER BY pack_id;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var packs = new List<RepositoryPack>();
        while (await reader.ReadAsync(cancellationToken))
        {
            packs.Add(new RepositoryPack(
                reader.GetGuid(0),
                reader.GetString(1),
                reader.GetInt64(2),
                reader.GetString(3),
                reader.GetInt64(4)));
        }

        return packs;
    }

    /// <summary>
    /// Bytes each committed pack still stores for registered objects. Garbage collection removes
    /// unreferenced object rows, so after it the difference from the file size is dead space.
    /// </summary>
    public async Task<IReadOnlyList<PackUsage>> ReadPackUsageAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT pack.pack_id, pack.relative_path, pack.byte_length, pack.status, pack.created_run_index,
                   COALESCE(SUM(object.stored_length), 0)
            FROM packs AS pack
            LEFT JOIN stored_objects AS object ON object.pack_id = pack.pack_id
            WHERE pack.status = 'Committed'
            GROUP BY pack.pack_id
            ORDER BY pack.pack_id;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var packs = new List<PackUsage>();
        while (await reader.ReadAsync(cancellationToken))
        {
            packs.Add(new PackUsage(
                new RepositoryPack(reader.GetGuid(0), reader.GetString(1), reader.GetInt64(2),
                    reader.GetString(3), reader.GetInt64(4)),
                reader.GetInt64(5)));
        }

        return packs;
    }

    public async Task<IReadOnlyList<RevisionReference>> ReadAffectedRevisionsAsync(
        Guid packId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT DISTINCT revision.source_id, revision.revision
            FROM entry_versions AS entry
            JOIN stored_objects AS object ON object.object_id = entry.object_id
            JOIN revisions AS revision
              ON revision.source_id = entry.source_id
             AND revision.revision >= entry.valid_from_revision
             AND (entry.valid_to_revision IS NULL
                  OR revision.revision < entry.valid_to_revision)
            WHERE object.pack_id = $packId
              AND revision.state = 'Active'
            ORDER BY revision.source_id, revision.revision;
            """;
        command.Parameters.AddWithValue("$packId", packId.ToByteArray());
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var revisions = new List<RevisionReference>();
        while (await reader.ReadAsync(cancellationToken))
        {
            revisions.Add(new RevisionReference(reader.GetInt64(0), reader.GetInt64(1)));
        }

        return revisions;
    }

    private static async Task EnsureRevisionExistsAsync(
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
            SELECT 1 FROM revisions
            WHERE source_id = $sourceId AND revision = $revision AND state = 'Active';
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        command.Parameters.AddWithValue("$revision", revision);
        if (await command.ExecuteScalarAsync(cancellationToken) is null)
        {
            throw new KeyNotFoundException(
                $"Revision {revision} for source {sourceId} does not exist.");
        }
    }

    private static async Task CreateValueTableAsync(
        SqliteConnection connection,
        string tableName,
        string columnName,
        IEnumerable<string> values,
        CancellationToken cancellationToken)
    {
        await using (var create = connection.CreateCommand())
        {
            create.CommandText = $"CREATE TEMP TABLE {tableName} ({columnName} TEXT PRIMARY KEY) WITHOUT ROWID;";
            await create.ExecuteNonQueryAsync(cancellationToken);
        }

        using var transaction = connection.BeginTransaction(deferred: true);
        await using var insert = connection.CreateCommand();
        insert.Transaction = transaction;
        insert.CommandText = $"INSERT OR IGNORE INTO {tableName}({columnName}) VALUES ($value);";
        var parameter = insert.Parameters.Add("$value", SqliteType.Text);
        foreach (var value in values)
        {
            parameter.Value = value;
            await insert.ExecuteNonQueryAsync(cancellationToken);
        }

        transaction.Commit();
    }

    private static async Task<IReadOnlyList<RevisionEntry>> ReadCurrentEntriesAsync(
        SqliteConnection connection,
        long sourceId,
        string fromClause,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = CurrentEntriesLookupSql(fromClause);
        command.Parameters.AddWithValue("$sourceId", sourceId);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var entries = new List<RevisionEntry>();
        while (await reader.ReadAsync(cancellationToken))
        {
            entries.Add(ReadRevisionEntry(reader));
        }

        return entries;
    }

    internal static string CurrentEntriesLookupSql(string fromClause) =>
        $"""
            SELECT entry.display_path, entry.entry_kind, entry.byte_length,
                   entry.modified_utc, entry.changed_utc, entry.attributes,
                   entry.file_id, entry.parent_file_id, entry.object_id,
                   object.pack_id, pack.relative_path, object.pack_offset,
                   object.stored_length, object.original_length,
                   object.checksum_algorithm, object.checksum,
                   object.compression_algorithm, object.flags
            FROM {fromClause}
            LEFT JOIN stored_objects AS object ON object.object_id = entry.object_id
            LEFT JOIN packs AS pack ON pack.pack_id = object.pack_id
            WHERE entry.source_id = $sourceId
              AND entry.valid_to_revision IS NULL
              AND entry.tombstone = 0
            ORDER BY entry.path_key;
            """;

    private static RevisionEntry ReadRevisionEntry(SqliteDataReader reader) =>
        new(
            reader.GetString(0),
            reader.GetString(1),
            reader.GetInt64(2),
            new DateTimeOffset(reader.GetInt64(3), TimeSpan.Zero),
            new DateTimeOffset(reader.GetInt64(4), TimeSpan.Zero),
            (FileAttributes)reader.GetInt64(5),
            reader.IsDBNull(6) ? null : (byte[])reader.GetValue(6),
            reader.IsDBNull(7) ? null : (byte[])reader.GetValue(7),
            reader.IsDBNull(8) ? null : reader.GetGuid(8),
            reader.IsDBNull(9) ? null : reader.GetGuid(9),
            reader.IsDBNull(10) ? null : reader.GetString(10),
            reader.IsDBNull(11) ? null : reader.GetInt64(11),
            reader.IsDBNull(12) ? null : reader.GetInt64(12),
            reader.IsDBNull(13) ? null : reader.GetInt64(13),
            reader.IsDBNull(14) ? null : StorageAlgorithmCodec.Checksum(reader.GetInt32(14)),
            reader.IsDBNull(15) ? null : (byte[])reader.GetValue(15),
            reader.IsDBNull(16) ? null : StorageAlgorithmCodec.Compression(reader.GetInt32(16)),
            reader.IsDBNull(17) ? null : reader.GetInt32(17));
}
