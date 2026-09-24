using PzTools.Process.Contracts;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Repository;

public sealed partial class RepositoryDatabase
{
    private static string DefaultRevisionName(long revision, SupportedLanguage language, BackupKind kind) =>
        RevisionNamePrefix(language, kind) + revision;

    private static string RevisionNamePrefix(SupportedLanguage language, BackupKind kind)
    {
        var names = LanguageCatalog.Get(language);
        return (kind switch
        {
            BackupKind.Manual => names.ManualBackupName,
            BackupKind.Automatic => names.AutomaticBackupName,
            _ => names.BackupName,
        }) + " ";
    }

    public async Task<int> AssignMissingRevisionNamesAsync(
        RepositoryWriterLease lease,
        SupportedLanguage language,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        var prefix = RevisionNamePrefix(language, BackupKind.Unknown);
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                """
                UPDATE revisions SET display_name =
                    (CASE backup_kind WHEN 'Manual' THEN $manual
                        WHEN 'Automatic' THEN $automatic ELSE $prefix END) || revision
                WHERE display_name='';
                """;
            command.Parameters.AddWithValue("$prefix", prefix);
            command.Parameters.AddWithValue("$manual", RevisionNamePrefix(language, BackupKind.Manual));
            command.Parameters.AddWithValue("$automatic", RevisionNamePrefix(language, BackupKind.Automatic));
            var changed = await command.ExecuteNonQueryAsync(cancellationToken);
            if (changed > 0)
                await IncrementRepositoryChangeRevisionAsync(connection, transaction, cancellationToken);
            transaction.Commit();
            return changed;
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    public async Task RenameRevisionAsync(
        RepositoryWriterLease lease,
        long sourceId,
        long revision,
        string displayName,
        CancellationToken cancellationToken = default)
    {
        EnsureLease(lease);
        ArgumentException.ThrowIfNullOrWhiteSpace(displayName);
        var normalized = displayName.Trim();
        if (normalized.Length > 100 || normalized.Any(char.IsControl))
            throw new ArgumentException("Backup name must be 1–100 printable characters.", nameof(displayName));
        await using var connection = await OpenConnectionAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText =
                "UPDATE revisions SET display_name=$name "
                + "WHERE source_id=$sourceId AND revision=$revision AND state='Active';";
            command.Parameters.AddWithValue("$name", normalized);
            command.Parameters.AddWithValue("$sourceId", sourceId);
            command.Parameters.AddWithValue("$revision", revision);
            if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
                throw new InvalidOperationException($"Revision {revision} is missing or deleted.");
            await IncrementRepositoryChangeRevisionAsync(connection, transaction, cancellationToken);
            transaction.Commit();
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }
}
