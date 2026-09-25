using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;
using Microsoft.Win32.SafeHandles;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class ContentFingerprintTests
{
    [Theory]
    [InlineData("", "e3b0c44298fc1c149afbf4c8996fb924")]
    [InlineData("abc", "ba7816bf8f01cfea414140de5dae2223")]
    public void Fingerprint_UsesFirst128BitsOfSha256(string text, string expected)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        var fingerprint = ContentFingerprint.FromSha256(digest);
        Assert.Equal(Convert.FromHexString(expected), fingerprint);
        Assert.Equal(16, fingerprint.Length);
        Assert.Equal("Sha256_128", ContentFingerprint.AlgorithmForLength(16));
        Assert.Equal("Sha256", ContentFingerprint.AlgorithmForLength(32));
        Assert.True(ContentFingerprint.MatchesSha256(digest, fingerprint));
        Assert.True(ContentFingerprint.MatchesSha256(digest, digest));
    }

    [Fact]
    public void Comparison_DoesNotTruncateLegacyDigestsOrAcceptArbitraryPrefixes()
    {
        var digest = SHA256.HashData("payload"u8);
        var differentTail = (byte[])digest.Clone();
        differentTail[31] ^= 1;
        Assert.False(ContentFingerprint.MatchesSha256(digest, differentTail));
        Assert.True(ContentFingerprint.MatchesSha256(digest, differentTail.AsSpan(0, 16)));
        differentTail[0] ^= 1;
        Assert.False(ContentFingerprint.MatchesSha256(digest, differentTail.AsSpan(0, 16)));
        foreach (var length in new[] { 0, 1, 15, 17, 31, 33 })
            Assert.False(ContentFingerprint.MatchesSha256(digest, new byte[length]));
        Assert.False(ContentFingerprint.MatchesSha256(new byte[16], new byte[16]));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(16)]
    [InlineData(31)]
    [InlineData(33)]
    public void Truncation_RequiresAFullDigest(int length) =>
        Assert.Throws<ArgumentException>(() => ContentFingerprint.FromSha256(new byte[length]));

    [Fact]
    public async Task Migration_ConvertsExistingFingerprintsAndPreservesReferencesAndChecksums()
    {
        await using var connection = await CreateVersion11Async();
        var digest = SHA256.HashData("payload"u8);
        Assert.Equal(12, await RepositoryMigrationRunner.ApplyAsync(connection, RepositorySchema.Migrations));
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT content_hash_algorithm,content_hash,checksum FROM stored_objects WHERE object_id='object';";
        await using (var reader = await command.ExecuteReaderAsync())
        {
            Assert.True(await reader.ReadAsync());
            Assert.Equal("Sha256_128", reader.GetString(0));
            Assert.Equal(digest[..16], (byte[])reader.GetValue(1));
            Assert.Equal(digest, (byte[])reader.GetValue(2));
        }
        command.CommandText = "SELECT COUNT(*) FROM stored_objects WHERE object_id='no-hash' AND content_hash IS NULL AND content_hash_algorithm IS NULL;";
        Assert.Equal(1L, await command.ExecuteScalarAsync());
        command.CommandText = "SELECT COUNT(*) FROM entry_versions WHERE object_id='object';";
        Assert.Equal(1L, await command.ExecuteScalarAsync());
        command.CommandText = "SELECT current_revision FROM source_state WHERE source_id=1;";
        Assert.Equal(1L, await command.ExecuteScalarAsync());
        command.CommandText = "SELECT schema_version FROM repository_info;";
        Assert.Equal(12L, await command.ExecuteScalarAsync());
        command.CommandText = "PRAGMA foreign_key_check;";
        await using (var reader = await command.ExecuteReaderAsync()) Assert.False(await reader.ReadAsync());
        command.CommandText = "PRAGMA integrity_check;";
        Assert.Equal("ok", await command.ExecuteScalarAsync());
        Assert.Equal(12, await RepositoryMigrationRunner.ApplyAsync(connection, RepositorySchema.Migrations));
    }

    [Fact]
    public async Task FailedMigration_RestoresOldColumnsDataAndVersionMarker()
    {
        await using var connection = await CreateVersion11Async();
        var migration = new RepositoryMigration(12, "injected failure",
            ContentFingerprintMigration.Sql + " SELECT * FROM deliberately_missing_table;");
        await Assert.ThrowsAsync<SqliteException>(() => RepositoryMigrationRunner.ApplyAsync(connection, [migration]));
        Assert.Equal(11, await RepositoryMigrationRunner.GetVersionAsync(connection));
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT schema_version FROM repository_info;";
        Assert.Equal(11L, await command.ExecuteScalarAsync());
        command.CommandText = "SELECT content_hash FROM stored_objects WHERE object_id='object';";
        Assert.Equal(SHA256.HashData("payload"u8), (byte[])(await command.ExecuteScalarAsync())!);
        command.CommandText = "SELECT COUNT(*) FROM sqlite_temp_master WHERE name='migration_content_fingerprints';";
        Assert.Equal(0L, await command.ExecuteScalarAsync());
        command.CommandText = "PRAGMA foreign_key_check;";
        await using var reader = await command.ExecuteReaderAsync();
        Assert.False(await reader.ReadAsync());
    }

    [Theory]
    [InlineData("Sha256", 16)]
    [InlineData("Sha256_128", 32)]
    [InlineData("Sha256_128", 0)]
    [InlineData("unknown", 16)]
    [InlineData(null, 16)]
    public async Task Schema_RejectsMismatchedAlgorithmAndLength(string? algorithm, int length)
    {
        await using var connection = await CreateVersion11Async();
        await RepositoryMigrationRunner.ApplyAsync(connection, RepositorySchema.Migrations);
        await using var command = connection.CreateCommand();
        command.CommandText = "UPDATE stored_objects SET content_hash_algorithm=$algorithm,content_hash=$hash WHERE object_id='object';";
        command.Parameters.AddWithValue("$algorithm", (object?)algorithm ?? DBNull.Value);
        command.Parameters.AddWithValue("$hash", new byte[length]);
        var error = await Assert.ThrowsAsync<SqliteException>(() => command.ExecuteNonQueryAsync());
        Assert.Equal(19, error.SqliteErrorCode);
    }

    [Theory]
    [InlineData("compact")]
    [InlineData("legacy")]
    [InlineData("checksum")]
    public async Task FullScan_ReusesCompatibleBaselineThenCapturesSameLengthContentChange(string mode)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var file = Path.Combine(sourcePath, "file.bin");
        await File.WriteAllTextAsync(file, "before");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repository.RepositoryPath);
        var metadata = new FrozenTimesMetadataReader();
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, ContentDeduplication: false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 16, 10, 10, 32);
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/HashTest", sourcePath);
        await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
            new NoCheckpoint()).RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        await using (var connection = await repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = "SELECT length(content_hash) FROM stored_objects;";
            Assert.Equal(16L, await command.ExecuteScalarAsync());
            if (mode == "legacy")
            {
                command.CommandText = "UPDATE stored_objects SET content_hash_algorithm='Sha256',content_hash=$hash;";
                command.Parameters.AddWithValue("$hash", SHA256.HashData("before"u8));
                await command.ExecuteNonQueryAsync();
            }
            else if (mode == "checksum")
            {
                command.CommandText = "UPDATE stored_objects SET content_hash_algorithm=NULL,content_hash=NULL;";
                await command.ExecuteNonQueryAsync();
            }
        }
        var runner = new IncrementalBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
            metadata, new UnavailableJournal(), new UsnDeltaPlanner());
        var same = await runner.RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        Assert.Null(same.Revision);
        await File.WriteAllTextAsync(file, "after!");
        var changed = await runner.RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        Assert.Equal(2L, changed.Revision);
        var restored = temp.GetPath("restored");
        await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 2, restored);
        Assert.Equal("after!", await File.ReadAllTextAsync(Path.Combine(restored, "file.bin")));
        await using var check = await repository.OpenConnectionAsync();
        await using var current = check.CreateCommand();
        current.CommandText = """
            SELECT object.content_hash,object.checksum FROM stored_objects AS object
            JOIN entry_versions AS entry ON entry.object_id=object.object_id
            WHERE entry.valid_to_revision IS NULL;
            """;
        await using var result = await current.ExecuteReaderAsync();
        Assert.True(await result.ReadAsync());
        var expected = SHA256.HashData("after!"u8);
        Assert.Equal(expected[..16], (byte[])result.GetValue(0));
        Assert.Equal(expected, (byte[])result.GetValue(1));
    }

    private static async Task<SqliteConnection> CreateVersion11Async()
    {
        var connection = new SqliteConnection("Data Source=:memory:;Pooling=False");
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA foreign_keys=ON;";
        await command.ExecuteNonQueryAsync();
        await RepositoryMigrationRunner.ApplyAsync(connection,
            RepositorySchema.Migrations.Where(migration => migration.Version <= 11).ToArray());
        command.CommandText = """
            INSERT INTO repository_info VALUES(1,'fixture',1,11,2,'2000-01-01T00:00:00+00:00',0);
            INSERT INTO sources VALUES(1,'Sandbox/Fixture','fixture','2000-01-01T00:00:00+00:00');
            INSERT INTO source_state(source_id,current_revision) VALUES(1,1);
            INSERT INTO runs(run_index,source_id,status,started_utc) VALUES(1,1,'Succeeded','2000-01-01T00:00:00+00:00');
            INSERT INTO revisions(source_id,revision,run_index,created_utc) VALUES(1,1,1,'2000-01-01T00:00:00+00:00');
            INSERT INTO packs VALUES('pack','packs/fixture',1,7,'Committed',1,'2000-01-01T00:00:00+00:00');
            INSERT INTO stored_objects VALUES('object','pack',0,7,7,'Sha256',$hash,'None',0,'Sha256',$hash);
            INSERT INTO stored_objects VALUES('no-hash','pack',0,7,7,'Sha256',$hash,'None',0,NULL,NULL);
            INSERT INTO entry_versions(source_id,path_key,display_path,valid_from_revision,entry_kind,tombstone,
                byte_length,modified_utc,changed_utc,attributes,object_id)
                VALUES(1,'FILE','file',1,'File',0,7,'2000-01-01T00:00:00+00:00','2000-01-01T00:00:00+00:00',0,'object');
            """;
        command.Parameters.AddWithValue("$hash", SHA256.HashData("payload"u8));
        await command.ExecuteNonQueryAsync();
        return connection;
    }

    private sealed class FrozenTimesMetadataReader : IFileMetadataReader
    {
        private readonly WindowsFileMetadataReader inner = new();
        public FileCaptureMetadata ReadPath(string path) => Freeze(inner.ReadPath(path));
        public FileCaptureMetadata ReadHandle(SafeFileHandle handle) => Freeze(inner.ReadHandle(handle));
        private static FileCaptureMetadata Freeze(FileCaptureMetadata value) => value with
        {
            ModifiedUtc = DateTimeOffset.UnixEpoch,
            ChangedUtc = DateTimeOffset.UnixEpoch,
        };
    }

    private sealed class NoCheckpoint : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(null, "test full scan");
    }

    private sealed class UnavailableJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new PlatformNotSupportedException("test full scan");
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("The full-scan fixture must not read the journal.");
    }
}
