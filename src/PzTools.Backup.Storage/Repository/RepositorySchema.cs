using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

internal sealed record RepositoryMigration(int Version, string Name, string Sql);

internal static class RepositorySchema
{
    public const int CurrentVersion = 12;

    public static IReadOnlyList<RepositoryMigration> Migrations { get; } =
    [
        new RepositoryMigration(
            1,
            "initial repository schema",
            """
            CREATE TABLE repository_info (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
                repository_id TEXT NOT NULL,
                format_version INTEGER NOT NULL,
                schema_version INTEGER NOT NULL,
                next_run_index INTEGER NOT NULL CHECK (next_run_index >= 1),
                created_utc TEXT NOT NULL
            ) STRICT;

            CREATE TABLE sources (
                source_id INTEGER NOT NULL PRIMARY KEY,
                source_key TEXT NOT NULL COLLATE NOCASE UNIQUE,
                root_path TEXT NOT NULL,
                created_utc TEXT NOT NULL
            ) STRICT;

            CREATE TABLE source_state (
                source_id INTEGER NOT NULL PRIMARY KEY
                    REFERENCES sources(source_id) ON DELETE CASCADE,
                current_revision INTEGER NOT NULL DEFAULT 0 CHECK (current_revision >= 0),
                volume_identity TEXT NULL,
                journal_id TEXT NULL,
                next_usn INTEGER NULL,
                CHECK (
                    (volume_identity IS NULL AND journal_id IS NULL AND next_usn IS NULL)
                    OR
                    (volume_identity IS NOT NULL AND journal_id IS NOT NULL AND next_usn IS NOT NULL)
                )
            ) STRICT;

            CREATE TABLE runs (
                run_index INTEGER NOT NULL PRIMARY KEY,
                source_id INTEGER NOT NULL REFERENCES sources(source_id),
                status TEXT NOT NULL CHECK (
                    status IN ('Running', 'Succeeded', 'Failed', 'Cancelled', 'Abandoned')
                ),
                started_utc TEXT NOT NULL,
                completed_utc TEXT NULL,
                failure_code TEXT NULL
            ) STRICT;

            CREATE TABLE revisions (
                source_id INTEGER NOT NULL REFERENCES sources(source_id),
                revision INTEGER NOT NULL CHECK (revision >= 1),
                run_index INTEGER NOT NULL UNIQUE REFERENCES runs(run_index),
                created_utc TEXT NOT NULL,
                PRIMARY KEY (source_id, revision)
            ) STRICT;

            CREATE TABLE packs (
                pack_id TEXT NOT NULL PRIMARY KEY,
                relative_path TEXT NOT NULL UNIQUE,
                format_version INTEGER NOT NULL,
                byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
                status TEXT NOT NULL CHECK (status IN ('Committed', 'Superseded')),
                created_run_index INTEGER NOT NULL REFERENCES runs(run_index),
                created_utc TEXT NOT NULL
            ) STRICT;

            CREATE TABLE stored_objects (
                object_id TEXT NOT NULL PRIMARY KEY,
                pack_id TEXT NOT NULL REFERENCES packs(pack_id),
                pack_offset INTEGER NOT NULL CHECK (pack_offset >= 0),
                stored_length INTEGER NOT NULL CHECK (stored_length >= 0),
                original_length INTEGER NOT NULL CHECK (original_length >= 0),
                checksum_algorithm TEXT NOT NULL,
                checksum BLOB NULL,
                compression_algorithm TEXT NOT NULL,
                flags INTEGER NOT NULL DEFAULT 0
            ) STRICT;

            CREATE TABLE entry_versions (
                source_id INTEGER NOT NULL,
                path_key TEXT NOT NULL,
                display_path TEXT NOT NULL,
                valid_from_revision INTEGER NOT NULL,
                valid_to_revision INTEGER NULL,
                entry_kind TEXT NOT NULL CHECK (entry_kind IN ('File', 'Directory')),
                tombstone INTEGER NOT NULL CHECK (tombstone IN (0, 1)),
                byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
                modified_utc TEXT NOT NULL,
                changed_utc TEXT NOT NULL,
                attributes INTEGER NOT NULL,
                file_id BLOB NULL,
                parent_file_id BLOB NULL,
                object_id TEXT NULL REFERENCES stored_objects(object_id),
                PRIMARY KEY (source_id, path_key, valid_from_revision),
                FOREIGN KEY (source_id, valid_from_revision)
                    REFERENCES revisions(source_id, revision),
                CHECK (valid_to_revision IS NULL OR valid_to_revision > valid_from_revision),
                CHECK (
                    (entry_kind = 'File' AND tombstone = 0 AND object_id IS NOT NULL)
                    OR entry_kind = 'Directory'
                    OR tombstone = 1
                )
            ) STRICT;

            CREATE UNIQUE INDEX ix_entry_versions_current
                ON entry_versions(source_id, path_key)
                WHERE valid_to_revision IS NULL;

            CREATE INDEX ix_entry_versions_object
                ON entry_versions(object_id)
                WHERE object_id IS NOT NULL;

            CREATE INDEX ix_runs_source
                ON runs(source_id, run_index);
            """),
        new RepositoryMigration(
            2,
            "current entry file-reference lookup indexes",
            """
            CREATE INDEX ix_entry_versions_current_file_reference
                ON entry_versions(
                    source_id,
                    lower(substr(CAST(file_id AS TEXT), -32)))
                WHERE valid_to_revision IS NULL AND tombstone = 0 AND file_id IS NOT NULL;

            CREATE INDEX ix_entry_versions_current_parent_reference
                ON entry_versions(
                    source_id,
                    lower(substr(CAST(parent_file_id AS TEXT), -32)))
                WHERE valid_to_revision IS NULL AND tombstone = 0
                  AND parent_file_id IS NOT NULL;

            CREATE INDEX ix_entry_versions_current_missing_identity
                ON entry_versions(source_id)
                WHERE valid_to_revision IS NULL AND tombstone = 0
                  AND (file_id IS NULL OR parent_file_id IS NULL);
            """),
        new RepositoryMigration(
            3,
            "workflow runs and revision lifecycle",
            """
            ALTER TABLE revisions
                ADD COLUMN state TEXT NOT NULL DEFAULT 'Active'
                    CHECK (state IN ('Active', 'Deleted'));
            ALTER TABLE revisions ADD COLUMN deleted_utc TEXT NULL;
            ALTER TABLE revisions ADD COLUMN delete_reason TEXT NULL;

            CREATE TABLE workflow_runs (
                run_index INTEGER NOT NULL PRIMARY KEY,
                pipeline TEXT NOT NULL,
                source_id INTEGER NULL REFERENCES sources(source_id),
                owner_component TEXT NOT NULL,
                admission_id TEXT NULL UNIQUE,
                status TEXT NOT NULL CHECK (
                    status IN (
                        'Running', 'Succeeded', 'NoChange', 'Skipped', 'Busy',
                        'Degraded', 'Failed', 'Cancelled', 'Abandoned', 'LaunchFailed'
                    )
                ),
                started_utc TEXT NOT NULL,
                completed_utc TEXT NULL,
                failure_code TEXT NULL
            ) STRICT;

            CREATE TABLE workflow_stages (
                run_index INTEGER NOT NULL REFERENCES workflow_runs(run_index),
                producer TEXT NOT NULL,
                status TEXT NOT NULL CHECK (
                    status IN (
                        'Running', 'Succeeded', 'NoChange', 'Skipped', 'Busy',
                        'Degraded', 'Failed', 'Cancelled', 'Abandoned', 'LaunchFailed'
                    )
                ),
                started_utc TEXT NOT NULL,
                completed_utc TEXT NULL,
                failure_code TEXT NULL,
                PRIMARY KEY (run_index, producer)
            ) STRICT;

            INSERT INTO workflow_runs(
                run_index, pipeline, source_id, owner_component, status,
                started_utc, completed_utc, failure_code)
            SELECT run_index, 'backup', source_id, 'backup-worker', status,
                   started_utc, completed_utc, failure_code
            FROM runs;

            INSERT INTO workflow_stages(
                run_index, producer, status, started_utc, completed_utc, failure_code)
            SELECT run_index, 'backup-worker', status, started_utc,
                   completed_utc, failure_code
            FROM runs;

            CREATE INDEX ix_revisions_active
                ON revisions(source_id, revision DESC)
                WHERE state = 'Active';
            CREATE INDEX ix_workflow_runs_source
                ON workflow_runs(source_id, run_index);
            """),
        new RepositoryMigration(
            4,
            "repository change revision",
            """
            ALTER TABLE repository_info
                ADD COLUMN repository_change_revision INTEGER NOT NULL DEFAULT 0;
            """),
        new RepositoryMigration(
            5,
            "revision display names",
            """
            ALTER TABLE revisions ADD COLUMN display_name TEXT NOT NULL DEFAULT '';
            """),
        new RepositoryMigration(
            6,
            "per-revision character snapshots",
            """
            ALTER TABLE revisions ADD COLUMN character_name TEXT NULL;
            ALTER TABLE revisions ADD COLUMN character_state TEXT NULL
                CHECK (character_state IN ('Unknown', 'Alive', 'Dead'));
            """),
        new RepositoryMigration(
            7,
            "optional stored-content fingerprints for full scan comparison",
            """
            ALTER TABLE stored_objects ADD COLUMN content_hash_algorithm TEXT NULL
                CHECK (content_hash_algorithm IS NULL OR content_hash_algorithm = 'Sha256');
            ALTER TABLE stored_objects ADD COLUMN content_hash BLOB NULL
                CHECK ((content_hash IS NULL AND content_hash_algorithm IS NULL)
                    OR (content_hash IS NOT NULL AND length(content_hash) = 32
                        AND content_hash_algorithm IS NOT NULL));
            """),
        new RepositoryMigration(
            8,
            "backup origin and automatic-only retention",
            """
            ALTER TABLE revisions ADD COLUMN backup_kind TEXT NOT NULL DEFAULT 'Unknown'
                CHECK (backup_kind IN ('Unknown', 'Manual', 'Automatic'));

            UPDATE revisions SET backup_kind = 'Automatic'
            WHERE run_index IN (
                SELECT run_index FROM workflow_runs
                WHERE pipeline = 'backup-maintenance' AND owner_component = 'backup-scheduler');
            UPDATE revisions SET backup_kind = 'Manual'
            WHERE run_index IN (
                SELECT run_index FROM workflow_runs WHERE pipeline = 'manual-backup');

            CREATE INDEX ix_revisions_automatic_active
                ON revisions(source_id, revision DESC)
                WHERE state = 'Active' AND backup_kind = 'Automatic';
            UPDATE repository_info SET repository_change_revision = repository_change_revision + 1;
            """),
        new RepositoryMigration(
            9,
            "workflow process ownership for interruption recovery",
            """
            ALTER TABLE workflow_runs ADD COLUMN owner_pid INTEGER NULL;
            ALTER TABLE workflow_runs ADD COLUMN owner_start_ticks INTEGER NULL;
            ALTER TABLE workflow_stages ADD COLUMN owner_pid INTEGER NULL;
            ALTER TABLE workflow_stages ADD COLUMN owner_start_ticks INTEGER NULL;
            """),
        new RepositoryMigration(
            10,
            "persistent revision character summaries",
            """
            ALTER TABLE revisions ADD COLUMN hours_survived REAL NULL;
            ALTER TABLE revisions ADD COLUMN character_metadata_read INTEGER NOT NULL DEFAULT 0
                CHECK (character_metadata_read IN (0, 1));
            CREATE INDEX ix_revisions_pending_character ON revisions(source_id, revision)
                WHERE state = 'Active' AND character_metadata_read = 0;
            """),
        new RepositoryMigration(11, "character summary read diagnostics",
            """
            ALTER TABLE revisions ADD COLUMN character_metadata_error TEXT NULL;
            """),
        new RepositoryMigration(12, "128-bit SHA-256 change fingerprints",
            ContentFingerprintMigration.Sql),
    ];
}

internal static class RepositoryMigrationRunner
{
    public static async Task<int> ApplyAsync(
        SqliteConnection connection,
        IReadOnlyList<RepositoryMigration> migrations,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(migrations);

        await EnsureMigrationTableAsync(connection, cancellationToken);
        var currentVersion = await GetVersionAsync(connection, cancellationToken);

        foreach (var migration in migrations.OrderBy(item => item.Version))
        {
            if (migration.Version <= currentVersion)
            {
                continue;
            }

            if (migration.Version != currentVersion + 1)
            {
                throw new InvalidOperationException(
                    $"Migration {migration.Version} is not consecutive after {currentVersion}.");
            }

            using var transaction = connection.BeginTransaction();
            try
            {
                await using var command = connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText = migration.Sql;
                await command.ExecuteNonQueryAsync(cancellationToken);

                command.Parameters.Clear();
                command.CommandText =
                    """
                    INSERT INTO schema_migrations(version, name, applied_utc)
                    VALUES ($version, $name, $appliedUtc);
                    """;
                command.Parameters.AddWithValue("$version", migration.Version);
                command.Parameters.AddWithValue("$name", migration.Name);
                command.Parameters.AddWithValue(
                    "$appliedUtc",
                    DateTimeOffset.UtcNow.ToString("O"));
                await command.ExecuteNonQueryAsync(cancellationToken);
                transaction.Commit();
                currentVersion = migration.Version;
            }
            catch
            {
                transaction.Rollback();
                throw;
            }
        }

        return currentVersion;
    }

    public static async Task<int> GetVersionAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken = default)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;";
        return Convert.ToInt32(
            await command.ExecuteScalarAsync(cancellationToken),
            System.Globalization.CultureInfo.InvariantCulture);
    }

    private static async Task EnsureMigrationTableAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                applied_utc TEXT NOT NULL
            ) STRICT;
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
