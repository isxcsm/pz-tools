using System.IO.Compression;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Tests;

/// <summary>
/// The fixture was written by the schema 5 build (52511b6): three manual backups of a small save,
/// with runs kept both in <c>runs</c> and in <c>workflow_runs</c>/<c>workflow_stages</c>.
/// </summary>
public sealed class RepositorySchemaUpgradeTests
{
    // What each backup in the fixture holds.
    private static readonly Dictionary<string, string>[] Revisions =
    [
        new() { ["map_t.bin"] = "first", ["map/map_1_1.bin"] = "chunk one", ["notes.txt"] = "keep me" },
        new() { ["map_t.bin"] = "second", ["map/map_1_1.bin"] = "chunk one", ["added.txt"] = "new file" },
        new() { ["map_t.bin"] = "second", ["map/map_1_1.bin"] = "chunk one, third", ["added.txt"] = "new file" },
    ];

    [Fact]
    public async Task OpeningSchema5_UpgradesInPlace_KeepsEveryBackup_AndAcceptsNewOnes()
    {
        using var temp = new TempDirectory();
        var path = ExtractFixture(temp);
        var before = await ReadRowsAsync(path, "SELECT run_index, status, started_utc FROM runs ORDER BY run_index;");

        var repository = await RepositoryDatabase.OpenExistingAsync(path);

        Assert.Equal(6, repository.Identity.SchemaVersion);
        Assert.Equal(2, repository.Identity.FormatVersion);
        Assert.Equal("6", await ScalarAsync(path, "SELECT schema_version FROM repository_info;"));
        Assert.Equal("6", await ScalarAsync(path, "SELECT MAX(version) FROM schema_migrations;"));
        Assert.Equal("0", await ScalarAsync(path, "SELECT COUNT(*) FROM sqlite_master WHERE name='runs';"));
        Assert.Equal("ok", await ScalarAsync(path, "PRAGMA integrity_check;"));
        Assert.Empty(await ReadRowsAsync(path, "PRAGMA foreign_key_check;"));
        // The worker history answers what runs did, with the same times.
        Assert.Equal(before, await ReadRowsAsync(path, "SELECT run_index, status, started_utc FROM worker_runs ORDER BY run_index;"));
        await AssertBackupsRestoreAsync(temp, repository, 3);

        // The pre-upgrade copy is still schema 5, for going back to the previous app.
        var copy = Path.Combine(path, "repository.schema5.db");
        Assert.Equal("5", await ScalarAsync(path, "SELECT schema_version FROM repository_info;", copy));
        Assert.Equal("3", await ScalarAsync(path, "SELECT COUNT(*) FROM runs;", copy));

        await using (var lease = RepositoryWriterLease.Acquire(path))
        {
            var run = await repository.StartRunAsync(lease, 1);
            var now = DateTimeOffset.UtcNow;
            await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(run.RunIndex, 1, null, [], [],
                [new EntryVersionRegistration("next", CatalogEntryKind.Directory, false, 0, now, now,
                    FileAttributes.Directory, null, null, null)]));
        }
        Assert.Equal(4, (await repository.GetSourceStateAsync(1)).CurrentRevision);
        Assert.Equal("Succeeded", await ScalarAsync(path,
            "SELECT status FROM worker_runs WHERE run_index=(SELECT run_index FROM revisions WHERE revision=4);"));

        // Opening again changes nothing.
        var reopened = await RepositoryDatabase.OpenExistingAsync(path);
        Assert.Equal(repository.Identity, reopened.Identity);
        Assert.Equal("1", await ScalarAsync(path, "SELECT COUNT(*) FROM schema_migrations WHERE version=6;"));
    }

    [Fact]
    public async Task Upgrade_KeepsARunThatOnlyTheOldHistoryRecorded()
    {
        using var temp = new TempDirectory();
        var path = ExtractFixture(temp);
        // History cleanup could remove a workflow and leave its run behind.
        await ExecuteAsync(path,
            """
            DELETE FROM workflow_stages WHERE run_index=(SELECT run_index FROM revisions WHERE revision=2);
            DELETE FROM workflow_runs WHERE run_index=(SELECT run_index FROM revisions WHERE revision=2);
            """);

        var repository = await RepositoryDatabase.OpenExistingAsync(path);

        Assert.Equal("backup|backup-worker|Succeeded", await ScalarAsync(path,
            """
            SELECT workflow.pipeline || '|' || stage.producer || '|' || stage.status
            FROM workflow_runs AS workflow JOIN workflow_stages AS stage ON stage.run_index=workflow.run_index
            WHERE workflow.run_index=(SELECT run_index FROM revisions WHERE revision=2);
            """));
        Assert.Empty(await ReadRowsAsync(path, "PRAGMA foreign_key_check;"));
        await AssertBackupsRestoreAsync(temp, repository, 3);
    }

    [Fact]
    public async Task FailedUpgrade_LeavesSchema5AsItWas()
    {
        using var temp = new TempDirectory();
        var path = ExtractFixture(temp);
        // A backup whose run is in neither history cannot be given one: the upgrade must not commit.
        await ExecuteAsync(path,
            """
            UPDATE revisions SET run_index=424242 WHERE revision=3;
            """);
        var revisions = await ReadRowsAsync(path, "SELECT * FROM revisions ORDER BY revision;");

        await Assert.ThrowsAsync<InvalidDataException>(() => RepositoryDatabase.OpenExistingAsync(path));

        Assert.Equal("5", await ScalarAsync(path, "SELECT schema_version FROM repository_info;"));
        Assert.Equal("5", await ScalarAsync(path, "SELECT MAX(version) FROM schema_migrations;"));
        Assert.Equal("3", await ScalarAsync(path, "SELECT COUNT(*) FROM runs;"));
        Assert.Equal(revisions, await ReadRowsAsync(path, "SELECT * FROM revisions ORDER BY revision;"));
        Assert.Equal("0", await ScalarAsync(path, "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%_v6';"));
    }

    [Fact]
    public async Task ProcessesOpeningAtOnce_UpgradeOnce()
    {
        using var temp = new TempDirectory();
        var path = ExtractFixture(temp);

        var opened = await Task.WhenAll(Enumerable.Range(0, 4)
            .Select(_ => Task.Run(() => RepositoryDatabase.OpenExistingAsync(path))));

        Assert.All(opened, repository => Assert.Equal(6, repository.Identity.SchemaVersion));
        Assert.Equal("1", await ScalarAsync(path, "SELECT COUNT(*) FROM schema_migrations WHERE version=6;"));
        Assert.Empty(Directory.GetFiles(path, "*.tmp"));
        await AssertBackupsRestoreAsync(temp, opened[0], 3);
    }

    private static string ExtractFixture(TempDirectory temp)
    {
        var path = temp.GetPath("repository");
        ZipFile.ExtractToDirectory(Path.Combine(AppContext.BaseDirectory, "Fixtures", "repository-schema5.zip"), path);
        Directory.CreateDirectory(Path.Combine(path, "staging"));
        return path;
    }

    private static async Task AssertBackupsRestoreAsync(TempDirectory temp, RepositoryDatabase repository, int count)
    {
        for (var revision = 1; revision <= count; revision++)
        {
            var target = temp.GetPath($"restore-{Guid.NewGuid():N}");
            await new RevisionRestorer().RestoreAsync(repository, 1, revision, target);
            var restored = Directory.EnumerateFiles(target, "*", SearchOption.AllDirectories)
                .ToDictionary(file => Path.GetRelativePath(target, file).Replace('\\', '/'), File.ReadAllText);
            Assert.Equal(Revisions[revision - 1].OrderBy(item => item.Key), restored.OrderBy(item => item.Key));
        }
    }

    // References are not enforced, so a test can damage the fixture on purpose.
    private static SqliteConnection Open(string repositoryPath, string? database = null) =>
        new(new SqliteConnectionStringBuilder
        {
            DataSource = database ?? Path.Combine(repositoryPath, RepositoryDatabase.DatabaseFileName),
            Pooling = false,
            ForeignKeys = false,
        }.ToString());

    private static async Task ExecuteAsync(string repositoryPath, string sql)
    {
        await using var connection = Open(repositoryPath);
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync();
    }

    private static async Task<string?> ScalarAsync(string repositoryPath, string sql, string? database = null) =>
        (await ReadRowsAsync(repositoryPath, sql, database)).SingleOrDefault();

    private static async Task<List<string>> ReadRowsAsync(string repositoryPath, string sql, string? database = null)
    {
        await using var connection = Open(repositoryPath, database);
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = sql;
        await using var reader = await command.ExecuteReaderAsync();
        var rows = new List<string>();
        while (await reader.ReadAsync())
            rows.Add(string.Join("|", Enumerable.Range(0, reader.FieldCount)
                .Select(index => reader.IsDBNull(index) ? "" : Convert.ToString(reader.GetValue(index), System.Globalization.CultureInfo.InvariantCulture))));
        return rows;
    }
}
