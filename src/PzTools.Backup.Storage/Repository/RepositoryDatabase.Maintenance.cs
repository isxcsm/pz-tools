using System.Globalization;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public async Task<long> CountDeletedRevisionsAsync(
        long sourceId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT COUNT(*) FROM revisions WHERE source_id=$sourceId AND state='Deleted';";
        command.Parameters.AddWithValue("$sourceId", sourceId);
        return Convert.ToInt64(
            await command.ExecuteScalarAsync(cancellationToken),
            CultureInfo.InvariantCulture);
    }

    public async Task<RevisionRetentionResult> MarkRevisionsForRetentionAsync(
        RepositoryWriterLease lease,
        long sourceId,
        int keepLatest = 100,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        if (keepLatest <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(keepLatest));
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await using var mark = connection.CreateCommand();
            mark.Transaction = transaction;
            mark.CommandText =
                """
                UPDATE revisions
                SET state = 'Deleted', deleted_utc = $deletedUtc,
                    delete_reason = 'retention'
                WHERE source_id = $sourceId
                  AND state = 'Active'
                  AND backup_kind = 'Automatic'
                  AND revision NOT IN (
                      SELECT revision FROM revisions
                      WHERE source_id = $sourceId AND state = 'Active'
                        AND backup_kind = 'Automatic'
                      ORDER BY revision DESC LIMIT $keepLatest
                  );
                """;
            mark.Parameters.AddWithValue("$deletedUtc", DateTimeOffset.UtcNow.ToString("O"));
            mark.Parameters.AddWithValue("$sourceId", sourceId);
            mark.Parameters.AddWithValue("$keepLatest", keepLatest);
            var marked = await mark.ExecuteNonQueryAsync(cancellationToken);
            if (marked > 0)
            {
                await IncrementRepositoryChangeRevisionAsync(
                    connection, transaction, cancellationToken);
            }

            await using var state = connection.CreateCommand();
            state.Transaction = transaction;
            state.CommandText =
                """
                SELECT COUNT(*), MIN(revision)
                FROM revisions
                WHERE source_id = $sourceId AND state = 'Active';
                """;
            state.Parameters.AddWithValue("$sourceId", sourceId);
            await using var reader = await state.ExecuteReaderAsync(cancellationToken);
            await reader.ReadAsync(cancellationToken);
            var count = reader.GetInt64(0);
            long? oldest = reader.IsDBNull(1) ? null : reader.GetInt64(1);
            transaction.Commit();
            return new RevisionRetentionResult(sourceId, marked, count, oldest);
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<long> CountCompactableDeletedRevisionsAsync(
        long sourceId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            SELECT COUNT(*) FROM revisions
            WHERE source_id=$sourceId AND state='Deleted'
              AND revision < (SELECT current_revision FROM source_state WHERE source_id=$sourceId);
            """;
        command.Parameters.AddWithValue("$sourceId", sourceId);
        return Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
    }

    public async Task MarkRevisionDeletedAsync(
        RepositoryWriterLease lease,
        long sourceId,
        long revision,
        string reason = "user",
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        ArgumentException.ThrowIfNullOrWhiteSpace(reason);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                """
                UPDATE revisions
                SET state = 'Deleted', deleted_utc = $deletedUtc, delete_reason = $reason
                WHERE source_id = $sourceId AND revision = $revision AND state = 'Active';
                """;
            command.Parameters.AddWithValue("$deletedUtc", DateTimeOffset.UtcNow.ToString("O"));
            command.Parameters.AddWithValue("$reason", reason);
            command.Parameters.AddWithValue("$sourceId", sourceId);
            command.Parameters.AddWithValue("$revision", revision);
            if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
            {
                throw new InvalidOperationException(
                    $"Revision {revision} is missing or already deleted.");
            }
            await IncrementRepositoryChangeRevisionAsync(
                connection, transaction, cancellationToken);
            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<int> MarkAllRevisionsDeletedAsync(
        RepositoryWriterLease lease,
        long sourceId,
        string sourceKey,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        if (sourceId <= 0) throw new ArgumentOutOfRangeException(nameof(sourceId));
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceKey);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            var source = await ReadSourceByKeyAsync(connection, transaction, sourceKey, cancellationToken);
            if (source?.SourceId != sourceId)
                throw new InvalidOperationException("The selected backup source has changed.");

            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                """
                UPDATE revisions
                SET state='Deleted', deleted_utc=$deletedUtc, delete_reason='user'
                WHERE source_id=$sourceId AND state='Active';
                """;
            command.Parameters.AddWithValue("$sourceId", sourceId);
            command.Parameters.AddWithValue("$deletedUtc", DateTimeOffset.UtcNow.ToString("O"));
            var count = await command.ExecuteNonQueryAsync(cancellationToken);
            if (count == 0)
                throw new InvalidOperationException("There are no active backup revisions to delete.");

            await IncrementRepositoryChangeRevisionAsync(connection, transaction, cancellationToken);
            transaction.Commit();
            return count;
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<RevisionCompactionResult> CompactDeletedRevisionsAsync(
        RepositoryWriterLease lease,
        long sourceId,
        int maximumRevisions = 20,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        if (maximumRevisions <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumRevisions));
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            var deleted = new List<long>();
            await using (var select = connection.CreateCommand())
            {
                select.Transaction = transaction;
                select.CommandText =
                    """
                    SELECT revision FROM revisions
                    WHERE source_id = $sourceId AND state = 'Deleted'
                      AND revision < (
                          SELECT current_revision FROM source_state WHERE source_id = $sourceId
                      )
                    ORDER BY revision LIMIT $limit;
                    """;
                select.Parameters.AddWithValue("$sourceId", sourceId);
                select.Parameters.AddWithValue("$limit", maximumRevisions);
                await using var reader = await select.ExecuteReaderAsync(cancellationToken);
                while (await reader.ReadAsync(cancellationToken))
                {
                    deleted.Add(reader.GetInt64(0));
                }
            }

            var rebased = 0;
            foreach (var revision in deleted)
            {
                cancellationToken.ThrowIfCancellationRequested();
                // 삭제된 최신 리비전도 내부 증분 기준으로 유지합니다.
                // 이전 삭제 항목은 다음 사용자 리비전 또는 이 내부 기준으로 재기준화합니다.
                long nextRetained;
                await using (var next = connection.CreateCommand())
                {
                    next.Transaction = transaction;
                    next.CommandText =
                        """
                        SELECT MIN(revision) FROM revisions
                        WHERE source_id = $sourceId AND revision > $revision
                          AND (state = 'Active' OR revision = (
                              SELECT current_revision FROM source_state WHERE source_id = $sourceId
                          ));
                        """;
                    next.Parameters.AddWithValue("$sourceId", sourceId);
                    next.Parameters.AddWithValue("$revision", revision);
                    var value = await next.ExecuteScalarAsync(cancellationToken);
                    if (value is null || value is DBNull)
                    {
                        throw new InvalidOperationException(
                            $"Deleted revision {revision} has no following retained baseline.");
                    }

                    nextRetained = Convert.ToInt64(value, CultureInfo.InvariantCulture);
                }

                await using (var close = connection.CreateCommand())
                {
                    close.Transaction = transaction;
                    close.CommandText =
                        """
                        UPDATE entry_versions SET valid_to_revision = $nextRetained
                        WHERE source_id = $sourceId AND valid_to_revision = $revision;
                        """;
                    close.Parameters.AddWithValue("$nextRetained", nextRetained);
                    close.Parameters.AddWithValue("$sourceId", sourceId);
                    close.Parameters.AddWithValue("$revision", revision);
                    await close.ExecuteNonQueryAsync(cancellationToken);
                }

                await using (var stageRebase = connection.CreateCommand())
                {
                    stageRebase.Transaction = transaction;
                    stageRebase.CommandText =
                        """
                        DROP TABLE IF EXISTS temp.rebase_entry_versions;
                        CREATE TEMP TABLE rebase_entry_versions AS
                        SELECT * FROM entry_versions
                        WHERE source_id = $sourceId
                          AND valid_from_revision = $revision
                          AND (valid_to_revision IS NULL OR valid_to_revision > $nextRetained);

                        DELETE FROM entry_versions
                        WHERE source_id = $sourceId AND valid_from_revision = $revision;

                        INSERT INTO entry_versions(
                            source_id, path_key, display_path, valid_from_revision,
                            valid_to_revision, entry_kind, tombstone, byte_length,
                            modified_utc, changed_utc, attributes, file_id,
                            parent_file_id, object_id)
                        SELECT source_id, path_key, display_path, $nextRetained,
                               valid_to_revision, entry_kind, tombstone, byte_length,
                               modified_utc, changed_utc, attributes, file_id,
                               parent_file_id, object_id
                        FROM rebase_entry_versions;
                        """;
                    stageRebase.Parameters.AddWithValue("$nextRetained", nextRetained);
                    stageRebase.Parameters.AddWithValue("$sourceId", sourceId);
                    stageRebase.Parameters.AddWithValue("$revision", revision);
                    await stageRebase.ExecuteNonQueryAsync(cancellationToken);

                    await using var count = connection.CreateCommand();
                    count.Transaction = transaction;
                    count.CommandText = "SELECT COUNT(*) FROM rebase_entry_versions;";
                    rebased += Convert.ToInt32(
                        await count.ExecuteScalarAsync(cancellationToken),
                        CultureInfo.InvariantCulture);
                }

                await using var removeRevision = connection.CreateCommand();
                removeRevision.Transaction = transaction;
                removeRevision.CommandText =
                    "DELETE FROM revisions WHERE source_id = $sourceId AND revision = $revision AND state = 'Deleted';";
                removeRevision.Parameters.AddWithValue("$sourceId", sourceId);
                removeRevision.Parameters.AddWithValue("$revision", revision);
                if (await removeRevision.ExecuteNonQueryAsync(cancellationToken) != 1)
                {
                    throw new InvalidOperationException($"Revision {revision} changed during compaction.");
                }
            }

            transaction.Commit();
            return new RevisionCompactionResult(sourceId, deleted.Count, rebased);
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<IReadOnlyList<CompactionObject>> ReadCompactionObjectsAsync(
        IReadOnlyCollection<Guid> packIds,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(packIds);
        if (packIds.Count == 0)
        {
            return [];
        }

        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        var parameterNames = new List<string>(packIds.Count);
        var index = 0;
        foreach (var packId in packIds)
        {
            var name = $"$pack{index++}";
            parameterNames.Add(name);
            command.Parameters.AddWithValue(name, packId.ToString("D"));
        }

        command.CommandText =
            $"""
             SELECT object.object_id, object.pack_id, pack.relative_path,
                    object.pack_offset, object.original_length, object.stored_length,
                    object.checksum_algorithm, object.checksum,
                    object.compression_algorithm, object.flags
             FROM stored_objects AS object
             JOIN packs AS pack ON pack.pack_id = object.pack_id
             WHERE object.pack_id IN ({string.Join(", ", parameterNames)})
             ORDER BY object.pack_id, object.pack_offset;
             """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var objects = new List<CompactionObject>();
        while (await reader.ReadAsync(cancellationToken))
        {
            objects.Add(new CompactionObject(
                Guid.Parse(reader.GetString(0)),
                Guid.Parse(reader.GetString(1)),
                reader.GetString(2),
                reader.GetInt64(3),
                reader.GetInt64(4),
                reader.GetInt64(5),
                reader.GetString(6),
                (byte[])reader.GetValue(7),
                reader.GetString(8),
                reader.GetInt32(9)));
        }

        return objects;
    }

    public async Task CommitCompactionAsync(
        RepositoryWriterLease lease,
        long createdRunIndex,
        PackRegistration newPack,
        IReadOnlyList<StoredObjectRegistration> relocatedObjects,
        IReadOnlyCollection<Guid> supersededPackIds,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        ArgumentNullException.ThrowIfNull(newPack);
        ArgumentNullException.ThrowIfNull(relocatedObjects);
        ArgumentNullException.ThrowIfNull(supersededPackIds);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await using (var insert = connection.CreateCommand())
            {
                insert.Transaction = transaction;
                insert.CommandText =
                    """
                    INSERT INTO packs(
                        pack_id, relative_path, format_version, byte_length, status,
                        created_run_index, created_utc)
                    VALUES (
                        $packId, $relativePath, $formatVersion, $byteLength, 'Committed',
                        $runIndex, $createdUtc);
                    """;
                insert.Parameters.AddWithValue("$packId", newPack.PackId.ToString("D"));
                insert.Parameters.AddWithValue("$relativePath", newPack.RelativePath);
                insert.Parameters.AddWithValue("$formatVersion", newPack.FormatVersion);
                insert.Parameters.AddWithValue("$byteLength", newPack.ByteLength);
                insert.Parameters.AddWithValue("$runIndex", createdRunIndex);
                insert.Parameters.AddWithValue("$createdUtc", DateTimeOffset.UtcNow.ToString("O"));
                await insert.ExecuteNonQueryAsync(cancellationToken);
            }

            foreach (var relocated in relocatedObjects)
            {
                await using var update = connection.CreateCommand();
                update.Transaction = transaction;
                update.CommandText =
                    """
                    UPDATE stored_objects
                    SET pack_id = $packId, pack_offset = $packOffset,
                        stored_length = $storedLength, original_length = $originalLength,
                        checksum_algorithm = $checksumAlgorithm, checksum = $checksum,
                        compression_algorithm = $compressionAlgorithm, flags = $flags
                    WHERE object_id = $objectId;
                    """;
                update.Parameters.AddWithValue("$packId", relocated.PackId.ToString("D"));
                update.Parameters.AddWithValue("$packOffset", relocated.PackOffset);
                update.Parameters.AddWithValue("$storedLength", relocated.StoredLength);
                update.Parameters.AddWithValue("$originalLength", relocated.OriginalLength);
                update.Parameters.AddWithValue("$checksumAlgorithm", relocated.ChecksumAlgorithm);
                update.Parameters.AddWithValue("$checksum", (object?)relocated.Checksum ?? DBNull.Value);
                update.Parameters.AddWithValue("$compressionAlgorithm", relocated.CompressionAlgorithm);
                update.Parameters.AddWithValue("$flags", relocated.Flags);
                update.Parameters.AddWithValue("$objectId", relocated.ObjectId.ToString("D"));
                if (await update.ExecuteNonQueryAsync(cancellationToken) != 1)
                {
                    throw new InvalidOperationException(
                        $"Object {relocated.ObjectId} disappeared during compaction.");
                }
            }

            foreach (var packId in supersededPackIds)
            {
                await using var mark = connection.CreateCommand();
                mark.Transaction = transaction;
                mark.CommandText =
                    """
                    UPDATE packs SET status = 'Superseded'
                    WHERE pack_id = $packId
                      AND NOT EXISTS (
                          SELECT 1 FROM stored_objects
                          WHERE stored_objects.pack_id = packs.pack_id
                      );
                    """;
                mark.Parameters.AddWithValue("$packId", packId.ToString("D"));
                if (await mark.ExecuteNonQueryAsync(cancellationToken) != 1)
                {
                    throw new InvalidOperationException(
                        $"Pack {packId} still owns objects after compaction.");
                }
            }

            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task<RevisionPruneResult> PruneRevisionsAsync(
        RepositoryWriterLease lease,
        long sourceId,
        int keepLatest,
        CancellationToken cancellationToken = default)
    {
        var retention = await MarkRevisionsForRetentionAsync(
            lease, sourceId, keepLatest, cancellationToken);
        var compacted = 0;
        while (true)
        {
            var batch = await CompactDeletedRevisionsAsync(
                lease, sourceId, maximumRevisions: 20, cancellationToken);
            compacted += batch.CompactedRevisions;
            if (batch.CompactedRevisions < 20)
            {
                break;
            }
        }

        return new RevisionPruneResult(
            sourceId,
            compacted,
            retention.OldestActiveRevision);
    }

    public async Task<GarbageCollectionResult> CollectGarbageAsync(
        RepositoryWriterLease lease,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        List<string> deletedPackPaths;
        int deletedObjects;
        try
        {
            await using (var deleteObjects = connection.CreateCommand())
            {
                deleteObjects.Transaction = transaction;
                deleteObjects.CommandText =
                    """
                    DELETE FROM stored_objects
                    WHERE NOT EXISTS (
                        SELECT 1 FROM entry_versions
                        WHERE entry_versions.object_id = stored_objects.object_id
                    );
                    """;
                deletedObjects = await deleteObjects.ExecuteNonQueryAsync(cancellationToken);
            }

            deletedPackPaths = [];
            await using (var selectPacks = connection.CreateCommand())
            {
                selectPacks.Transaction = transaction;
                selectPacks.CommandText =
                    """
                    SELECT relative_path
                    FROM packs
                    WHERE NOT EXISTS (
                        SELECT 1 FROM stored_objects
                        WHERE stored_objects.pack_id = packs.pack_id
                    );
                    """;
                await using var reader = await selectPacks.ExecuteReaderAsync(cancellationToken);
                while (await reader.ReadAsync(cancellationToken))
                {
                    deletedPackPaths.Add(reader.GetString(0));
                }
            }

            await using (var deletePacks = connection.CreateCommand())
            {
                deletePacks.Transaction = transaction;
                deletePacks.CommandText =
                    """
                    DELETE FROM packs
                    WHERE NOT EXISTS (
                        SELECT 1 FROM stored_objects
                        WHERE stored_objects.pack_id = packs.pack_id
                    );
                    """;
                await deletePacks.ExecuteNonQueryAsync(cancellationToken);
            }

            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }

        var failed = new List<string>();
        foreach (var relativePath in deletedPackPaths)
        {
            TryDeleteRepositoryFile(relativePath, failed);
        }

        var registered = (await ReadPacksAsync(cancellationToken))
            .Select(item => item.RelativePath.Replace('\\', '/'))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var orphanCount = 0;
        foreach (var path in Directory.EnumerateFiles(
                     Path.Combine(RepositoryPath, "packs"),
                     "*.pzpack",
                     SearchOption.TopDirectoryOnly))
        {
            var relative = Path.GetRelativePath(RepositoryPath, path).Replace('\\', '/');
            if (registered.Contains(relative))
            {
                continue;
            }

            if (TryDeleteRepositoryFile(relative, failed))
            {
                orphanCount++;
            }
        }

        return new GarbageCollectionResult(
            deletedObjects,
            deletedPackPaths.Count,
            orphanCount,
            failed);
    }

    public Task<ArtifactCleanupResult> CleanupArtifactsAsync(
        RepositoryWriterLease lease,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        var staging = Path.Combine(RepositoryPath, "staging");
        var failed = new List<string>();
        var deleted = 0;
        if (!Directory.Exists(staging))
        {
            return Task.FromResult(new ArtifactCleanupResult(0, failed));
        }

        if ((File.GetAttributes(staging) & FileAttributes.ReparsePoint) != 0)
            return Task.FromResult(new ArtifactCleanupResult(0, [staging]));
        var directories = new List<string> { staging };
        var quarantine = Path.Combine(staging, "quarantine");
        if (Directory.Exists(quarantine)
            && (File.GetAttributes(quarantine) & FileAttributes.ReparsePoint) == 0)
            directories.Add(quarantine);
        foreach (var path in directories.SelectMany(directory =>
                     Directory.EnumerateFiles(directory, "*.tmp", SearchOption.TopDirectoryOnly)))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) { failed.Add(path); continue; }
            var relative = Path.GetRelativePath(RepositoryPath, path).Replace('\\', '/');
            if (TryDeleteRepositoryFile(relative, failed)) deleted++;
        }

        if (directories.Contains(quarantine) && !Directory.EnumerateFileSystemEntries(quarantine).Any())
        {
            try { Directory.Delete(quarantine); }
            catch (IOException) { failed.Add(quarantine); }
            catch (UnauthorizedAccessException) { failed.Add(quarantine); }
        }

        return Task.FromResult(new ArtifactCleanupResult(deleted, failed));
    }

    private bool TryDeleteRepositoryFile(string relativePath, ICollection<string> failed)
    {
        var path = Path.GetFullPath(Path.Combine(
            RepositoryPath,
            relativePath.Replace('/', Path.DirectorySeparatorChar)));
        var prefix = Path.TrimEndingDirectorySeparator(RepositoryPath)
            + Path.DirectorySeparatorChar;
        if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            failed.Add(relativePath);
            return false;
        }

        try
        {
            File.Delete(path);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            failed.Add(relativePath);
            return false;
        }
    }
}
