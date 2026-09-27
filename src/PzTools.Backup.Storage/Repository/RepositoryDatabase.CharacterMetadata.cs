namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public async Task<bool> SetRevisionCharacterMetadataAsync(
        RepositoryWriterLease lease,
        long sourceId,
        long revision,
        string? characterName,
        string characterState,
        CancellationToken cancellationToken = default,
        double? hoursSurvived = null)
    {
        EnsureLease(lease);
        if (sourceId <= 0) throw new ArgumentOutOfRangeException(nameof(sourceId));
        if (revision <= 0) throw new ArgumentOutOfRangeException(nameof(revision));
        if (hoursSurvived is { } hours && (!double.IsFinite(hours) || hours < 0))
            throw new ArgumentOutOfRangeException(nameof(hoursSurvived));
        if (characterState is not ("Unknown" or "Alive" or "Dead"))
            throw new ArgumentOutOfRangeException(nameof(characterState));
        if (characterName is { Length: > 256 })
            throw new ArgumentOutOfRangeException(nameof(characterName));

        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await using var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText =
                "UPDATE revisions SET character_name=$name,character_state=$state, "
                + "hours_survived=$hours,character_metadata_read=1,character_metadata_error=NULL "
                + "WHERE source_id=$sourceId AND revision=$revision "
                + "AND state='Active' AND character_metadata_read=0;";
            update.Parameters.AddWithValue("$name", (object?)characterName ?? DBNull.Value);
            update.Parameters.AddWithValue("$state", characterState);
            update.Parameters.AddWithValue("$hours", (object?)hoursSurvived ?? DBNull.Value);
            update.Parameters.AddWithValue("$sourceId", sourceId);
            update.Parameters.AddWithValue("$revision", revision);
            var changed = await update.ExecuteNonQueryAsync(cancellationToken) == 1;
            if (changed)
                await IncrementRepositoryChangeRevisionAsync(
                    connection, transaction, cancellationToken);
            transaction.Commit();
            return changed;
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task RecordCharacterMetadataFailureAsync(RepositoryWriterLease lease,
        long sourceId, long revision, string error, CancellationToken token = default)
    {
        EnsureLease(lease);
        ArgumentException.ThrowIfNullOrWhiteSpace(error);
        await using var connection = await OpenConnectionAsync(token);
        using var transaction = connection.BeginTransaction();
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            UPDATE revisions SET character_metadata_error=$error
            WHERE source_id=$source AND revision=$revision AND state='Active'
                AND character_metadata_read=0 AND character_metadata_error IS NOT $error;
            """;
        command.Parameters.AddWithValue("$error", error.Length > 2048 ? error[..2048] : error);
        command.Parameters.AddWithValue("$source", sourceId);
        command.Parameters.AddWithValue("$revision", revision);
        if (await command.ExecuteNonQueryAsync(token) != 0)
            await IncrementRepositoryChangeRevisionAsync(connection, transaction, token);
        transaction.Commit();
    }

    public async Task<IReadOnlyList<RevisionReference>> ReadPendingCharacterMetadataAsync(
        long afterSource, long afterRevision, int limit, CancellationToken token = default)
    {
        if (limit <= 0) throw new ArgumentOutOfRangeException(nameof(limit));
        await using var connection = await OpenConnectionAsync(token);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT source_id, revision FROM revisions
            WHERE state='Active' AND character_metadata_read=0
              AND (source_id > $source OR (source_id=$source AND revision > $revision))
            ORDER BY source_id, revision LIMIT $limit;
            """;
        command.Parameters.AddWithValue("$source", afterSource);
        command.Parameters.AddWithValue("$revision", afterRevision);
        command.Parameters.AddWithValue("$limit", limit);
        var result = new List<RevisionReference>();
        await using var reader = await command.ExecuteReaderAsync(token);
        while (await reader.ReadAsync(token)) result.Add(new(reader.GetInt64(0), reader.GetInt64(1)));
        return result;
    }
}
