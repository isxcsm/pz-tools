using PzTools.Process.Contracts;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Tests;

public sealed class RepositoryDatabaseTests
{
    [Fact]
    public async Task ExistingRepository_UpgradesNamesWithoutLosingRevisions()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            var source = await repository.AddOrGetSourceAsync(
                lease, "Sandbox/OldSave", temp.GetPath("source"));
            var run = await repository.StartRunAsync(lease, source.SourceId);
            await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(
                run.RunIndex, source.SourceId, null, [], [], []));
        }
        await using (var connection = new SqliteConnection(
                         new SqliteConnectionStringBuilder
                         {
                             DataSource = repository.DatabasePath,
                             Pooling = false,
                         }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText =
                "DROP INDEX ix_revisions_pending_character; "
                + "ALTER TABLE revisions DROP COLUMN hours_survived; "
                + "ALTER TABLE revisions DROP COLUMN character_metadata_read; "
                + "ALTER TABLE revisions DROP COLUMN character_metadata_error; "
                + "DELETE FROM schema_migrations WHERE version IN (10,11); "
                + "ALTER TABLE revisions DROP COLUMN character_name; "
                + "ALTER TABLE revisions DROP COLUMN character_state; "
                + "ALTER TABLE revisions DROP COLUMN display_name; "
                + "ALTER TABLE stored_objects DROP COLUMN content_hash; "
                + "ALTER TABLE stored_objects DROP COLUMN content_hash_algorithm; "
                + "DROP INDEX ix_revisions_automatic_active; "
                + "ALTER TABLE revisions DROP COLUMN backup_kind; "
                + "ALTER TABLE workflow_runs DROP COLUMN owner_pid; "
                + "ALTER TABLE workflow_runs DROP COLUMN owner_start_ticks; "
                + "ALTER TABLE workflow_stages DROP COLUMN owner_pid; "
                + "ALTER TABLE workflow_stages DROP COLUMN owner_start_ticks; "
                + "DELETE FROM schema_migrations WHERE version=9; "
                + "DELETE FROM schema_migrations WHERE version=8; "
                + "DELETE FROM schema_migrations WHERE version=7; "
                + "DELETE FROM schema_migrations WHERE version=6; "
                + "DELETE FROM schema_migrations WHERE version=5; "
                + "UPDATE repository_info SET schema_version=4;";
            await command.ExecuteNonQueryAsync();
        }

        repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
            Assert.Equal(1, await repository.AssignMissingRevisionNamesAsync(
                lease, SupportedLanguage.English));
        var revision = Assert.Single(Assert.Single(
            (await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        Assert.Equal(1, revision.Revision);
        Assert.Equal("Backup 1", revision.DisplayName);
        Assert.Equal(BackupKind.Unknown, revision.Kind);
    }

    [Fact]
    public async Task RevisionNames_AreStoredEditableAndPersistAcrossReopen()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            var source = await repository.AddOrGetSourceAsync(
                lease, "Sandbox/Save", temp.GetPath("source"));
            var first = await repository.StartRunAsync(lease, source.SourceId);
            await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(
                first.RunIndex, source.SourceId, null, [], [], [],
                NameLanguage: SupportedLanguage.English));
            var second = await repository.StartRunAsync(lease, source.SourceId);
            await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(
                second.RunIndex, source.SourceId, null, [], [], [],
                NameLanguage: SupportedLanguage.Korean));
            var before = await repository.ReadCatalogIfChangedAsync(-1);
            Assert.Equal("Manual backup 1", before.Sources.Single().Revisions.Single(item => item.Revision == 1).DisplayName);
            Assert.Equal("수동 백업 2", before.Sources.Single().Revisions.Single(item => item.Revision == 2).DisplayName);

            await repository.RenameRevisionAsync(lease, source.SourceId, 1, "  중요한 백업  ");
            var changed = await repository.ReadCatalogIfChangedAsync(before.RepositoryChangeRevision);
            Assert.True(changed.Modified);
            Assert.Equal("중요한 백업", changed.Sources.Single().Revisions.Single(item => item.Revision == 1).DisplayName);
            await Assert.ThrowsAsync<ArgumentException>(() =>
                repository.RenameRevisionAsync(lease, source.SourceId, 1, "  "));
            await Assert.ThrowsAsync<ArgumentException>(() =>
                repository.RenameRevisionAsync(lease, source.SourceId, 1, new string('x', 101)));
        }

        repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var reopened = await repository.ReadCatalogIfChangedAsync(-1);
        Assert.Equal("중요한 백업", reopened.Sources.Single().Revisions.Single(item => item.Revision == 1).DisplayName);

        await using (var connection = new SqliteConnection(
                         new SqliteConnectionStringBuilder
                         {
                             DataSource = repository.DatabasePath,
                             Pooling = false,
                         }.ToString()))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "UPDATE revisions SET display_name='' WHERE revision=2;";
            await command.ExecuteNonQueryAsync();
        }
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
            Assert.Equal(1, await repository.AssignMissingRevisionNamesAsync(
                lease, SupportedLanguage.English));
        var backfilled = await repository.ReadCatalogIfChangedAsync(-1);
        Assert.Equal("Manual backup 2", backfilled.Sources.Single().Revisions.Single(item => item.Revision == 2).DisplayName);
        Assert.Equal("중요한 백업", backfilled.Sources.Single().Revisions.Single(item => item.Revision == 1).DisplayName);
    }

    [Fact]
    public async Task ConcurrentWorkflowReservations_GetDistinctDurableIndexes()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            sourceId = (await repository.AddOrGetSourceAsync(
                lease, "main", temp.GetPath("source"))).SourceId;
        }

        var workflows = await Task.WhenAll(Enumerable.Range(0, 12).Select(index =>
            repository.ReserveWorkflowAsync(
                "test", sourceId, "test-owner", $"admission-{index}")));

        Assert.Equal(12, workflows.Select(item => item.RunIndex).Distinct().Count());
        Assert.Equal(Enumerable.Range(1, 12).Select(value => (long)value),
            workflows.Select(item => item.RunIndex).Order());
    }

    [Fact]
    public async Task WorkflowReservation_IsIdempotentAndOwnerAloneCompletesIt()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", temp.GetPath("source"));

        var first = await repository.ReserveWorkflowAsync(
            "backup", source.SourceId, "backup-scheduler", "tick-1");
        var repeated = await repository.ReserveWorkflowAsync(
            "backup", source.SourceId, "backup-scheduler", "tick-1");
        Assert.Equal(first.RunIndex, repeated.RunIndex);

        await repository.AttachWorkflowStageAsync(first.RunIndex, "backup-runner");
        await repository.CompleteWorkflowStageAsync(
            first.RunIndex, "backup-runner", WorkflowStatus.Succeeded);
        await Assert.ThrowsAsync<InvalidOperationException>(() => repository.CompleteWorkflowAsync(
            first.RunIndex, "backup-runner", WorkflowStatus.Succeeded));
        await repository.CompleteWorkflowAsync(
            first.RunIndex, "backup-scheduler", WorkflowStatus.Succeeded);
        Assert.Equal(WorkflowStatus.Succeeded,
            (await repository.ReadWorkflowAsync(first.RunIndex)).Status);
    }

    [Fact]
    public async Task SourceLessRunnerReservation_IsBoundWhenBackupWorkerStarts()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var reservation = await repository.ReserveWorkflowAsync(
            "backup", sourceId: null, "backup-worker");

        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(
            lease, "main", temp.GetPath("source"));
        var run = await repository.StartRunAsync(
            lease, source.SourceId, reservation.RunIndex);

        Assert.Equal(reservation.RunIndex, run.RunIndex);
        Assert.Equal(source.SourceId,
            (await repository.ReadWorkflowAsync(run.RunIndex)).SourceId);
        await repository.CompleteRunAsync(
            lease, run.RunIndex, RunStatus.Failed, "test-complete");
    }

    [Fact]
    public async Task RequestedRevision_AllowsGapButRejectsBackwardValue()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", temp.GetPath("source"));
        var now = DateTimeOffset.UtcNow;
        var entry = new EntryVersionRegistration(
            "directory", CatalogEntryKind.Directory, false, 0, now, now,
            FileAttributes.Directory, null, null, null);

        var first = await repository.StartRunAsync(lease, source.SourceId);
        var committed = await repository.CommitRevisionAsync(
            lease,
            new RevisionCommitRequest(
                first.RunIndex, source.SourceId, null, [], [], [entry], RequestedRevision: 10));
        Assert.Equal(10, committed.Revision);

        var second = await repository.StartRunAsync(lease, source.SourceId);
        await Assert.ThrowsAsync<InvalidOperationException>(() => repository.CommitRevisionAsync(
            lease,
            new RevisionCommitRequest(
                second.RunIndex, source.SourceId, null, [], [], [entry], RequestedRevision: 9)));
    }

    [Fact]
    public async Task CatalogRevision_ChangesOnlyForUiVisibleRepositoryMetadata()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var initial = await repository.ReadCatalogIfChangedAsync(-1);
        Assert.True(initial.Modified);
        Assert.Empty(initial.Sources);
        Assert.False((await repository.ReadCatalogIfChangedAsync(
            initial.RepositoryChangeRevision)).Modified);

        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(
            lease, "Sandbox/Save", temp.GetPath("source"));
        var sourceSnapshot = await repository.ReadCatalogIfChangedAsync(
            initial.RepositoryChangeRevision);
        Assert.True(sourceSnapshot.Modified);
        Assert.Empty(sourceSnapshot.Sources.Single().Revisions);

        var packId = Guid.NewGuid();
        var objectId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow;
        var run = await repository.StartRunAsync(lease, source.SourceId);
        await repository.CommitRevisionAsync(
            lease,
            new RevisionCommitRequest(
                run.RunIndex,
                source.SourceId,
                null,
                [new PackRegistration(packId, "packs/test.pack", 1, 12)],
                [new StoredObjectRegistration(
                    objectId, packId, 0, 12, 12, "Sha256", new byte[32], "None")],
                [new EntryVersionRegistration(
                    "file.bin", CatalogEntryKind.File, false, 12, now, now,
                    FileAttributes.Normal, null, null, objectId)]));

        var committed = await repository.ReadCatalogIfChangedAsync(
            sourceSnapshot.RepositoryChangeRevision);
        var revision = Assert.Single(Assert.Single(committed.Sources).Revisions);
        Assert.Equal(1, revision.Revision);
        Assert.Equal(12, revision.LogicalSize);
        Assert.Equal(1, revision.FileCount);
        Assert.False((await repository.ReadCatalogIfChangedAsync(
            committed.RepositoryChangeRevision)).Modified);
    }

    [Fact]
    public async Task CreateOrOpen_PreservesIdentityAndCreatesLayout()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");

        var created = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var reopened = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);

        Assert.Equal(created.Identity, reopened.Identity);
        Assert.Equal(RepositorySchema.CurrentVersion, created.Identity.SchemaVersion);
        Assert.True(File.Exists(Path.Combine(repositoryPath, "repository.db")));
        Assert.True(Directory.Exists(Path.Combine(repositoryPath, "packs")));
        Assert.True(Directory.Exists(Path.Combine(repositoryPath, "staging")));
    }

    [Fact]
    public async Task SourceAndRunIndex_AreRepositoryScopedAndDurable()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var sourcePath = temp.GetPath("source");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);

        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
            var sameSource = await repository.AddOrGetSourceAsync(lease, "MAIN", sourcePath);
            Assert.Equal(source, sameSource);

            var first = await repository.StartRunAsync(lease, source.SourceId);
            await repository.CompleteRunAsync(lease, first.RunIndex, RunStatus.Failed, "test");
            var second = await repository.StartRunAsync(lease, source.SourceId);

            Assert.Equal(1, first.RunIndex);
            Assert.Equal(2, second.RunIndex);
            await repository.CompleteRunAsync(lease, second.RunIndex, RunStatus.Succeeded);
        }

        var reopened = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var reopenedLease = RepositoryWriterLease.Acquire(repositoryPath);
        var reopenedSource = await reopened.AddOrGetSourceAsync(
            reopenedLease,
            "main",
            sourcePath);
        var third = await reopened.StartRunAsync(reopenedLease, reopenedSource.SourceId);
        Assert.Equal(3, third.RunIndex);
    }

    [Fact]
    public async Task EveryOpenedConnection_EnforcesForeignKeys()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));

        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText =
            """
            INSERT INTO source_state(source_id, current_revision)
            VALUES (9999, 0);
            """;

        var exception = await Assert.ThrowsAsync<SqliteException>(
            () => command.ExecuteNonQueryAsync());
        Assert.Equal(19, exception.SqliteErrorCode);
    }

    [Fact]
    public void WriterLease_RejectsConcurrentWriterAndCanBeReacquired()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");

        using (RepositoryWriterLease.Acquire(repositoryPath))
        {
            Assert.Throws<RepositoryBusyException>(
                () => RepositoryWriterLease.Acquire(repositoryPath));
        }

        using var reacquired = RepositoryWriterLease.Acquire(repositoryPath);
        Assert.Equal(Path.GetFullPath(repositoryPath), reacquired.RepositoryPath);
    }

    [Fact]
    public async Task DisposedWriterLease_CannotAuthorizeMutation()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var lease = RepositoryWriterLease.Acquire(repositoryPath);
        await lease.DisposeAsync();

        await Assert.ThrowsAsync<ObjectDisposedException>(
            () => repository.AddOrGetSourceAsync(
                lease,
                "main",
                temp.GetPath("source")));
    }

    [Fact]
    public async Task OpenExisting_DoesNotCreateMissingRepository()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("missing");

        await Assert.ThrowsAsync<DirectoryNotFoundException>(
            () => RepositoryDatabase.OpenExistingAsync(repositoryPath));

        Assert.False(Directory.Exists(repositoryPath));
    }

    [Fact]
    public async Task FailedMigration_LeavesPreviousVersionUsable()
    {
        using var temp = new TempDirectory();
        var databasePath = temp.GetPath("migration.db");
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Pooling = false,
        }.ToString();
        await using var connection = new SqliteConnection(connectionString);
        await connection.OpenAsync();

        var migrations = new RepositoryMigration[]
        {
            new(1, "valid", "CREATE TABLE durable(value INTEGER NOT NULL) STRICT;"),
            new(2, "invalid", "CREATE TABLE broken("),
        };

        await Assert.ThrowsAsync<SqliteException>(
            () => RepositoryMigrationRunner.ApplyAsync(connection, migrations));

        Assert.Equal(1, await RepositoryMigrationRunner.GetVersionAsync(connection));
        await using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO durable(value) VALUES (42); SELECT value FROM durable;";
        Assert.Equal(42L, await command.ExecuteScalarAsync());
    }

    [Fact]
    public async Task CreateOrOpen_MigratesVersionOneRepositoryAndCreatesLookupIndexes()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        Directory.CreateDirectory(repositoryPath);
        var databasePath = Path.Combine(repositoryPath, RepositoryDatabase.DatabaseFileName);
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Pooling = false,
        }.ToString();
        await using (var connection = new SqliteConnection(connectionString))
        {
            await connection.OpenAsync();
            await RepositoryMigrationRunner.ApplyAsync(connection, RepositorySchema.Migrations.Take(1).ToArray());
            await using var insert = connection.CreateCommand();
            insert.CommandText =
                """
                INSERT INTO repository_info(
                    singleton, repository_id, format_version, schema_version,
                    next_run_index, created_utc)
                VALUES (1, $repositoryId, 1, 1, 1, $createdUtc);
                """;
            insert.Parameters.AddWithValue("$repositoryId", Guid.NewGuid().ToString("D"));
            insert.Parameters.AddWithValue("$createdUtc", DateTimeOffset.UtcNow.ToString("O"));
            await insert.ExecuteNonQueryAsync();
        }

        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);

        Assert.Equal(RepositorySchema.CurrentVersion, repository.Identity.SchemaVersion);
        await using var migrated = await repository.OpenConnectionAsync();
        await using var indexes = migrated.CreateCommand();
        indexes.CommandText =
            """
            SELECT COUNT(*)
            FROM sqlite_master
            WHERE type = 'index'
              AND name IN (
                  'ix_entry_versions_current_file_reference',
                  'ix_entry_versions_current_parent_reference',
                  'ix_entry_versions_current_missing_identity');
            """;
        Assert.Equal(3L, await indexes.ExecuteScalarAsync());
    }

    [Fact]
    public async Task FailedRevisionCommit_DoesNotConsumeRevisionNumber()
    {
        using var temp = new TempDirectory();
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(
            lease,
            "main",
            temp.GetPath("source"));
        var failedRun = await repository.StartRunAsync(lease, source.SourceId);
        var now = DateTimeOffset.UtcNow;
        var invalidEntry = new EntryVersionRegistration(
            "file.bin",
            CatalogEntryKind.File,
            Tombstone: false,
            ByteLength: 1,
            now,
            now,
            FileAttributes.Normal,
            FileId: null,
            ParentFileId: null,
            ObjectId: null);

        await Assert.ThrowsAsync<SqliteException>(() => repository.CommitRevisionAsync(
            lease,
            new RevisionCommitRequest(
                failedRun.RunIndex,
                source.SourceId,
                Checkpoint: null,
                Packs: [],
                Objects: [],
                Entries: [invalidEntry])));
        await repository.CompleteRunAsync(
            lease,
            failedRun.RunIndex,
            RunStatus.Failed,
            "invalid-test-entry");

        var successfulRun = await repository.StartRunAsync(lease, source.SourceId);
        var directory = invalidEntry with
        {
            RelativePath = "empty-directory",
            Kind = CatalogEntryKind.Directory,
            ByteLength = 0,
            Attributes = FileAttributes.Directory,
        };
        var committed = await repository.CommitRevisionAsync(
            lease,
            new RevisionCommitRequest(
                successfulRun.RunIndex,
                source.SourceId,
                new SourceCheckpoint("volume", "journal", 123),
                Packs: [],
                Objects: [],
                Entries: [directory]));

        Assert.Equal(1, committed.Revision);
        var state = await repository.GetSourceStateAsync(source.SourceId);
        Assert.Equal(1, state.CurrentRevision);
        Assert.Equal(new SourceCheckpoint("volume", "journal", 123), state.Checkpoint);
    }
}
