using Microsoft.Data.Sqlite;

namespace PzTools.Backup.Storage.Repository;

internal sealed record RepositoryMigration(int Version, string Name, string Sql);

internal static class RepositorySchema
{
    public const int CurrentVersion = 5;

    // Fresh format 2 / schema 5 repositories only. Older schemas have no upgrade path.
    public static IReadOnlyList<RepositoryMigration> Migrations { get; } =
    [
        new RepositoryMigration(CurrentVersion, "bounded version and path inspection",
            """
            CREATE TABLE repository_info (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton = 1),
                repository_id BLOB NOT NULL CHECK (repository_id IS NULL OR length(repository_id)=16),
                format_version INTEGER NOT NULL,
                schema_version INTEGER NOT NULL,
                next_run_index INTEGER NOT NULL CHECK (next_run_index >= 1),
                created_utc TEXT NOT NULL,
                repository_change_revision INTEGER NOT NULL DEFAULT 0
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
                state TEXT NOT NULL DEFAULT 'Active' CHECK (state IN ('Active', 'Deleted')),
                deleted_utc TEXT NULL,
                delete_reason TEXT NULL,
                display_name TEXT NOT NULL DEFAULT '',
                character_name TEXT NULL,
                character_state TEXT NULL CHECK (character_state IN ('Unknown', 'Alive', 'Dead')),
                backup_kind TEXT NOT NULL DEFAULT 'Unknown' CHECK (backup_kind IN ('Unknown', 'Manual', 'Automatic')),
                hours_survived REAL NULL,
                character_metadata_read INTEGER NOT NULL DEFAULT 0 CHECK (character_metadata_read IN (0, 1)),
                character_metadata_error TEXT NULL,
                logical_size INTEGER NOT NULL DEFAULT 0 CHECK (logical_size >= 0),
                file_count INTEGER NOT NULL DEFAULT 0 CHECK (file_count >= 0),
                game_version TEXT NULL,
                PRIMARY KEY (source_id, revision)
            ) STRICT;

            CREATE TABLE packs (
                pack_id BLOB NOT NULL CHECK (pack_id IS NULL OR length(pack_id)=16) PRIMARY KEY,
                relative_path TEXT NOT NULL UNIQUE,
                format_version INTEGER NOT NULL,
                byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
                status TEXT NOT NULL CHECK (status IN ('Committed', 'Superseded')),
                created_run_index INTEGER NOT NULL REFERENCES runs(run_index),
                created_utc TEXT NOT NULL
            ) STRICT;

            CREATE TABLE stored_objects (
                object_id BLOB NOT NULL CHECK (object_id IS NULL OR length(object_id)=16) PRIMARY KEY,
                pack_id BLOB NOT NULL CHECK (pack_id IS NULL OR length(pack_id)=16) REFERENCES packs(pack_id),
                pack_offset INTEGER NOT NULL CHECK (pack_offset >= 0),
                stored_length INTEGER NOT NULL CHECK (stored_length >= 0),
                original_length INTEGER NOT NULL CHECK (original_length >= 0),
                checksum_algorithm INTEGER NOT NULL CHECK (checksum_algorithm IN (1,2,3)),
                checksum BLOB NULL,
                compression_algorithm INTEGER NOT NULL CHECK (compression_algorithm IN (1,2)),
                flags INTEGER NOT NULL DEFAULT 0,
                content_hash BLOB NULL CHECK (content_hash IS NULL OR length(content_hash) = 16)
            ) STRICT, WITHOUT ROWID;

            -- Global dictionaries: identities use .NET invariant uppercase keys;
            -- exact display spellings never change once referenced by a revision.
            CREATE TABLE paths (
                path_id INTEGER NOT NULL PRIMARY KEY,
                path_key TEXT NOT NULL COLLATE BINARY UNIQUE CHECK (length(path_key) > 0)
            ) STRICT;

            CREATE TABLE path_spellings (
                path_id INTEGER NOT NULL REFERENCES paths(path_id),
                spelling_id INTEGER NOT NULL CHECK (spelling_id >= 0),
                display_path TEXT NOT NULL COLLATE BINARY CHECK (length(display_path) > 0),
                PRIMARY KEY (path_id, spelling_id)
            ) STRICT, WITHOUT ROWID;

            -- A path normally has one spelling. Enforce uniqueness within that
            -- small indexed range without storing every display string twice.
            CREATE TRIGGER path_spelling_unique BEFORE INSERT ON path_spellings
            WHEN EXISTS (SELECT 1 FROM path_spellings
                         WHERE path_id=NEW.path_id AND display_path=NEW.display_path)
            BEGIN SELECT RAISE(ABORT, 'Duplicate path spelling.'); END;

            CREATE TRIGGER paths_immutable BEFORE UPDATE ON paths
            BEGIN SELECT RAISE(ABORT, 'Path identities are immutable.'); END;
            CREATE TRIGGER path_spellings_immutable BEFORE UPDATE ON path_spellings
            BEGIN SELECT RAISE(ABORT, 'Historical path spellings are immutable.'); END;

            CREATE TABLE entry_versions (
                source_id INTEGER NOT NULL,
                path_id INTEGER NOT NULL,
                spelling_id INTEGER NOT NULL,
                valid_from_revision INTEGER NOT NULL,
                valid_to_revision INTEGER NULL,
                entry_kind TEXT NOT NULL CHECK (entry_kind IN ('File', 'Directory')),
                tombstone INTEGER NOT NULL CHECK (tombstone IN (0, 1)),
                byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
                modified_utc INTEGER NOT NULL,
                changed_utc INTEGER NOT NULL,
                attributes INTEGER NOT NULL,
                file_id BLOB NULL CHECK (file_id IS NULL OR length(file_id)=24),
                parent_file_id BLOB NULL CHECK (parent_file_id IS NULL OR length(parent_file_id)=24),
                object_id BLOB NULL CHECK (object_id IS NULL OR length(object_id)=16) REFERENCES stored_objects(object_id),
                PRIMARY KEY (source_id, path_id, valid_from_revision),
                FOREIGN KEY (path_id, spelling_id) REFERENCES path_spellings(path_id, spelling_id),
                FOREIGN KEY (source_id, valid_from_revision)
                    REFERENCES revisions(source_id, revision),
                CHECK (valid_to_revision IS NULL OR valid_to_revision > valid_from_revision),
                CHECK (
                    (entry_kind = 'File' AND tombstone = 0 AND object_id IS NOT NULL)
                    OR entry_kind = 'Directory'
                    OR tombstone = 1
                )
            ) STRICT;

            -- Read projection of the current schema, not a legacy storage reader.
            CREATE VIEW entry_catalog AS
            SELECT entry.*, path.path_key, spelling.display_path
            FROM entry_versions AS entry
            JOIN paths AS path ON path.path_id=entry.path_id
            JOIN path_spellings AS spelling
              ON spelling.path_id=entry.path_id AND spelling.spelling_id=entry.spelling_id;

            -- Supports FK checks and bounded collection without scanning all versions.
            CREATE INDEX ix_entry_versions_spelling ON entry_versions(path_id, spelling_id);

            -- Resume inspection even when no rows can be deleted. Cursor progress
            -- and deletion commit together; the cursor is not a liveness oracle.
            CREATE TABLE entry_gc_cursors (
                scope_source_id INTEGER NOT NULL PRIMARY KEY CHECK (scope_source_id>=0),
                after_rowid INTEGER NULL
            ) STRICT;

            CREATE TABLE path_gc_cursor (
                singleton INTEGER NOT NULL PRIMARY KEY CHECK (singleton=1),
                spelling_path_id INTEGER NOT NULL,
                spelling_id INTEGER NOT NULL,
                empty_path_id INTEGER NULL,
                spellings_first INTEGER NOT NULL CHECK (spellings_first IN (0,1))
            ) STRICT;
            INSERT INTO path_gc_cursor VALUES(1, -9223372036854775808, -1, NULL, 1);

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
                failure_code TEXT NULL,
                owner_pid INTEGER NULL,
                owner_start_ticks INTEGER NULL
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
                owner_pid INTEGER NULL,
                owner_start_ticks INTEGER NULL,
                PRIMARY KEY (run_index, producer)
            ) STRICT;

            CREATE UNIQUE INDEX ix_entry_versions_current
                ON entry_versions(source_id, path_id)
                WHERE valid_to_revision IS NULL;

            CREATE INDEX ix_entry_versions_object
                ON entry_versions(object_id)
                WHERE object_id IS NOT NULL;

            CREATE INDEX ix_runs_source
                ON runs(source_id, run_index);

            CREATE INDEX ix_entry_versions_current_file_reference
                ON entry_versions(
                    source_id,
                    substr(file_id, 9, 16))
                WHERE valid_to_revision IS NULL AND tombstone = 0 AND file_id IS NOT NULL;

            CREATE INDEX ix_entry_versions_current_missing_identity
                ON entry_versions(source_id)
                WHERE valid_to_revision IS NULL AND tombstone = 0
                  AND (file_id IS NULL OR parent_file_id IS NULL);

            CREATE INDEX ix_revisions_active
                ON revisions(source_id, revision DESC)
                WHERE state = 'Active';

            CREATE INDEX ix_workflow_runs_source
                ON workflow_runs(source_id, run_index);

            CREATE INDEX ix_revisions_automatic_active
                ON revisions(source_id, revision DESC)
                WHERE state = 'Active' AND backup_kind = 'Automatic';

            CREATE INDEX ix_revisions_pending_character ON revisions(source_id, revision)
                WHERE state = 'Active' AND character_metadata_read = 0;

            -- Keep current-only scans on the narrow live index even after adding
            -- revision-maintenance indexes. Historical queries use entry_catalog.
            CREATE VIEW current_entry_catalog AS
            SELECT entry.*, path.path_key, spelling.display_path
            FROM entry_versions AS entry INDEXED BY ix_entry_versions_current
            JOIN paths AS path ON path.path_id=entry.path_id
            JOIN path_spellings AS spelling
              ON spelling.path_id=entry.path_id AND spelling.spelling_id=entry.spelling_id
            WHERE entry.valid_to_revision IS NULL AND entry.tombstone=0;

            CREATE INDEX ix_stored_objects_pack ON stored_objects(pack_id);
            CREATE INDEX ix_entry_versions_revision_start ON entry_versions(source_id, valid_from_revision);
            CREATE INDEX ix_entry_versions_revision_end ON entry_versions(source_id, valid_to_revision)
                WHERE valid_to_revision IS NOT NULL;

            CREATE INDEX ix_stored_objects_dedup ON stored_objects(original_length, checksum) WHERE checksum_algorithm=3;
            """),
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

            // A single fresh baseline can start at the current schema version.
            // Existing repositories are version-checked before this initializer is called.
            var freshBaseline = currentVersion == 0 && migrations.Count == 1;
            if (!freshBaseline && migration.Version != currentVersion + 1)
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
