using System.Globalization;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    public async Task<IReadOnlyList<RepositorySource>> ReadMaintenanceSourcesAsync(
        CancellationToken cancellationToken = default)
    {
        await using var connection = await OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT s.source_id,s.source_key,s.root_path,s.created_utc
            FROM sources s JOIN source_state state ON state.source_id=s.source_id
            WHERE state.current_revision > 0;
            """;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        var sources = new List<RepositorySource>();
        while (await reader.ReadAsync(cancellationToken))
            sources.Add(new RepositorySource(reader.GetInt64(0), reader.GetString(1),
                reader.GetString(2), DateTimeOffset.Parse(reader.GetString(3), CultureInfo.InvariantCulture)));
        return sources;
    }

    // The caller must hold RepositoryAccess and verify that this exact save is absent.
    // Keep an empty, hidden baseline to preserve revision IDs if the save is recreated.
    public async Task<int?> ReclaimOrphanSourceAsync(
        RepositoryWriterLease lease, RepositorySource expectedSource,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        var source = await ReadSourceByKeyAsync(connection, transaction, expectedSource.SourceKey, cancellationToken);
        if (source != expectedSource) throw new InvalidOperationException("The backup source has changed.");
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.Parameters.AddWithValue("$id", source.SourceId);
        command.CommandText = """
            SELECT EXISTS(SELECT 1 FROM workflow_runs WHERE source_id=$id AND status='Running')
                OR EXISTS(SELECT 1 FROM runs WHERE source_id=$id AND status='Running');
            """;
        if (Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture) != 0)
            return null;
        command.CommandText = "SELECT COUNT(*) FROM revisions WHERE source_id=$id AND COALESCE(delete_reason,'') != 'orphan-save';";
        var count = Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken), CultureInfo.InvariantCulture);
        if (count == 0) return 0;
        command.CommandText = """
            DELETE FROM entry_versions WHERE source_id=$id;
            DELETE FROM revisions WHERE source_id=$id AND revision != (
                SELECT current_revision FROM source_state WHERE source_id=$id);
            UPDATE revisions SET state='Deleted',deleted_utc=$now,delete_reason='orphan-save'
                WHERE source_id=$id;
            UPDATE source_state SET volume_identity=NULL,journal_id=NULL,next_usn=NULL WHERE source_id=$id;
            """;
        command.Parameters.AddWithValue("$now", DateTimeOffset.UtcNow.ToString("O"));
        await command.ExecuteNonQueryAsync(cancellationToken);
        await IncrementRepositoryChangeRevisionAsync(connection, transaction, cancellationToken);
        transaction.Commit();
        return count;
    }
}
