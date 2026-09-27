using System.Security.Cryptography;
using Microsoft.Data.Sqlite;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class CompactRepositoryFormatTests
{
    [Fact]
    public void Fingerprint_HasKnownPrefixAndRejectsLegacyLength()
    {
        var digest = SHA256.HashData("abc"u8);
        var fingerprint = ContentFingerprint.FromSha256(digest);
        Assert.Equal("BA7816BF8F01CFEA414140DE5DAE2223", Convert.ToHexString(fingerprint));
        Assert.True(ContentFingerprint.MatchesSha256(fingerprint, digest));
        Assert.False(ContentFingerprint.MatchesSha256(fingerprint, SHA256.HashData("abd"u8)));
        Assert.Throws<InvalidDataException>(() => ContentFingerprint.MatchesSha256(digest, digest));
        Assert.Throws<ArgumentException>(() => ContentFingerprint.FromSha256(new byte[16]));
    }

    [Fact]
    public void FileIdentity_PreservesAllVolumeAndReferenceBits()
    {
        const string identity = "FEDCBA9876543210:FFEEDDCCBBAA99887766554433221100";
        var encoded = FileIdentityCodec.Encode(identity);
        Assert.Equal(24, encoded.Length);
        Assert.Equal(identity.Replace(":", ""), Convert.ToHexString(encoded));
        Assert.Equal(UInt128.Parse("FFEEDDCCBBAA99887766554433221100",
            System.Globalization.NumberStyles.HexNumber), FileIdentityCodec.FileReference(encoded));
        Assert.Throws<InvalidDataException>(() => FileIdentityCodec.Encode("legacy-identity"));
        Assert.Throws<InvalidDataException>(() => FileIdentityCodec.FileReference(new byte[49]));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task OldFormat_RequiresReset_WithoutModifyingDatabase(bool createOrOpen)
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("repository");
        Directory.CreateDirectory(path);
        var database = Path.Combine(path, RepositoryDatabase.DatabaseFileName);
        await using (var connection = new SqliteConnection($"Data Source={database};Pooling=False"))
        {
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = """
                CREATE TABLE repository_info(singleton INTEGER PRIMARY KEY,repository_id TEXT,
                    format_version INTEGER,schema_version INTEGER,created_utc TEXT);
                INSERT INTO repository_info VALUES(1,'00000000-0000-0000-0000-000000000001',1,11,'2026-01-01T00:00:00Z');
                CREATE TABLE keep(payload TEXT);
                INSERT INTO keep VALUES('must survive');
                """;
            await command.ExecuteNonQueryAsync();
        }
        var before = SHA256.HashData(await File.ReadAllBytesAsync(database));
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => createOrOpen
            ? RepositoryDatabase.CreateOrOpenAsync(path)
            : RepositoryDatabase.OpenExistingAsync(path));
        Assert.Contains("repository-reset-required", error.Message);
        Assert.Equal(before, SHA256.HashData(await File.ReadAllBytesAsync(database)));
        Assert.False(Directory.Exists(Path.Combine(path, "packs")));
    }

    [Fact]
    public async Task EntryMetadata_PreservesUtcTicksAndBinaryIdentity()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", temp.GetPath("save"));
        var run = await repository.StartRunAsync(lease, source.SourceId);
        var time = new DateTimeOffset(2026, 9, 25, 12, 34, 56, TimeSpan.FromHours(9)).AddTicks(1234567);
        var id = FileIdentityCodec.Encode("FEDCBA9876543210:00000000000000000000000000000001");
        var parent = FileIdentityCodec.Encode("FEDCBA9876543210:00000000000000000000000000000002");
        await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(run.RunIndex, source.SourceId,
            null, [], [], [new EntryVersionRegistration("folder", CatalogEntryKind.Directory, false, 0,
                time, time.AddTicks(1), FileAttributes.Directory, id, parent, null)]));
        var entry = Assert.Single(await repository.ReadRevisionEntriesAsync(source.SourceId, 1));
        Assert.Equal(time.UtcTicks, entry.ModifiedUtc.UtcTicks);
        Assert.Equal(time.UtcTicks + 1, entry.ChangedUtc.UtcTicks);
        Assert.Equal(id, entry.FileId);
        var tracked = Assert.Single(await repository.ReadCurrentTrackedPathsAsync(source.SourceId,
            ["00000000000000000000000000000001"]));
        Assert.Equal("folder", tracked.RelativePath);
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT typeof(modified_utc),typeof(changed_utc),length(file_id),length(parent_file_id) FROM entry_versions;";
        await using var reader = await command.ExecuteReaderAsync();
        Assert.True(await reader.ReadAsync());
        Assert.Equal("integer", reader.GetString(0));
        Assert.Equal("integer", reader.GetString(1));
        Assert.Equal(24, reader.GetInt64(2));
        Assert.Equal(24, reader.GetInt64(3));
    }

    [Fact]
    public async Task BackupRestore_UsesCompactColumnsAndKeepsFullIntegrityChecksum()
    {
        using var temp = new TempDirectory();
        var save = temp.GetPath("save");
        Directory.CreateDirectory(save);
        await File.WriteAllTextAsync(Path.Combine(save, "value.bin"), "full checksum payload");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repository.RepositoryPath);
        var metadata = new WindowsFileMetadataReader();
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            sourceId = (await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", save)).SourceId;
            var source = await repository.GetSourceByIdAsync(sourceId);
            await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
                new NoJournal()).RunAsync(repository, telemetry, lease, source,
                new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, false),
                new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32));
        }
        await using (var connection = await repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = "SELECT length(object_id),length(pack_id),length(content_hash),length(checksum),checksum_algorithm,compression_algorithm FROM stored_objects;";
            await using var reader = await command.ExecuteReaderAsync();
            Assert.True(await reader.ReadAsync());
            Assert.Equal(16, reader.GetInt64(0));
            Assert.Equal(16, reader.GetInt64(1));
            Assert.Equal(16, reader.GetInt64(2));
            Assert.Equal(32, reader.GetInt64(3));
            Assert.Equal(3, reader.GetInt64(4));
            Assert.Equal(2, reader.GetInt64(5));
        }
        var target = temp.GetPath("restored");
        var reopened = await RepositoryDatabase.CreateOrOpenAsync(repository.RepositoryPath);
        await new RevisionRestorer().RestoreAsync(reopened, sourceId, 1, target);
        Assert.Equal("full checksum payload", await File.ReadAllTextAsync(Path.Combine(target, "value.bin")));
        Assert.True((await new RepositoryVerifier().VerifyAsync(reopened)).IsValid);
    }

    [Fact]
    public async Task Scan_ReusesInsertAcrossTransactionBoundaries()
    {
        using var temp = new TempDirectory();
        var save = temp.GetPath("save");
        Directory.CreateDirectory(save);
        for (var i = 0; i < 9; i++) await File.WriteAllTextAsync(Path.Combine(save, $"file-{i}"), "x");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", save);
        await using var scan = await new StreamingFullScanner(new WindowsFileMetadataReader(), 2)
            .ScanAsync(repository, source.SourceId, save);
        Assert.Equal(9, scan.EntryCount);
        var count = 0;
        await foreach (var entry in scan.EnumerateEntriesAsync())
        {
            Assert.Equal(24, entry.FileId.Length);
            count++;
        }
        Assert.Equal(9, count);
    }

    [Fact]
    public async Task DedupLookup_UsesNewPartialIndex()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "EXPLAIN QUERY PLAN SELECT object_id FROM stored_objects WHERE original_length=42 AND checksum_algorithm=3 AND checksum=$hash;";
        command.Parameters.AddWithValue("$hash", new byte[32]);
        await using var reader = await command.ExecuteReaderAsync();
        Assert.True(await reader.ReadAsync());
        Assert.Contains("ix_stored_objects_dedup", reader.GetString(3));
    }

    private sealed class NoJournal : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(null, "test full scan");
    }
}
