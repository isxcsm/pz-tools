using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;
using Microsoft.Win32.SafeHandles;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

// Port the useful PR #2 regressions to format 2; never introduce a legacy reader.
public sealed class ContentFingerprintTests
{
    [Theory]
    [InlineData("", "e3b0c44298fc1c149afbf4c8996fb924")]
    [InlineData("abc", "ba7816bf8f01cfea414140de5dae2223")]
    public void Fingerprint_UsesFirst128BitsOfKnownSha256(string text, string expected)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(text));
        var original = digest.ToArray();
        var fingerprint = ContentFingerprint.FromSha256(digest);
        Assert.Equal(Convert.FromHexString(expected), fingerprint);
        Assert.Equal(16, fingerprint.Length);
        Assert.Equal("Sha256Truncated128", ContentFingerprint.AlgorithmName);
        Assert.True(ContentFingerprint.MatchesSha256(fingerprint, digest));
        fingerprint[0] ^= 1;
        Assert.Equal(original, digest); // The returned bytes do not alias the digest.
    }

    [Fact]
    public void Comparison_UsesExactlyThePrefix_NotAnIntegrityOrDeduplicationDecision()
    {
        var digest = SHA256.HashData("payload"u8);
        var fingerprint = ContentFingerprint.FromSha256(digest);
        var changedTail = digest.ToArray();
        changedTail[31] ^= 1;
        Assert.True(ContentFingerprint.MatchesSha256(fingerprint, changedTail));
        changedTail[0] ^= 1;
        Assert.False(ContentFingerprint.MatchesSha256(fingerprint, changedTail));
        // The full digest is not a supported fingerprint, even when bytes match.
        Assert.Throws<InvalidDataException>(() => ContentFingerprint.MatchesSha256(digest, digest));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(15)]
    [InlineData(16)]
    [InlineData(31)]
    [InlineData(33)]
    public void DigestInputs_RequireAll32Bytes(int length)
    {
        Assert.Throws<ArgumentException>(() => ContentFingerprint.FromSha256(new byte[length]));
        Assert.Throws<ArgumentException>(() => ContentFingerprint.MatchesSha256(new byte[16], new byte[length]));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(15)]
    [InlineData(17)]
    [InlineData(31)]
    [InlineData(32)]
    [InlineData(33)]
    public void Comparison_RejectsEveryUnsupportedFingerprintLength(int length) =>
        Assert.Throws<InvalidDataException>(() =>
            ContentFingerprint.MatchesSha256(new byte[length], new byte[32]));

    [Theory]
    [InlineData(0)]
    [InlineData(15)]
    [InlineData(17)]
    [InlineData(32)]
    public async Task CurrentSchema_RejectsInvalidFingerprintWithoutChangingChecksum(int length)
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Schema", temp.GetPath("source"));
        var run = await repository.StartRunAsync(lease, source.SourceId);
        var packId = Guid.NewGuid();
        var objectId = Guid.NewGuid();
        var digest = SHA256.HashData("payload"u8);
        // Schema-only fixture. No real pack or user data is required for a CHECK test.
        await repository.CommitRevisionAsync(lease, new RevisionCommitRequest(
            run.RunIndex, source.SourceId, null,
            [new PackRegistration(packId, "packs/schema-fixture.pzpack", 1, 7)],
            [new StoredObjectRegistration(objectId, packId, 0, 7, 7, "Sha256", digest, "None",
                ContentHash: ContentFingerprint.FromSha256(digest))], []));
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "UPDATE stored_objects SET content_hash=$hash WHERE object_id=$id;";
        command.Parameters.AddWithValue("$hash", new byte[length]);
        command.Parameters.AddWithValue("$id", objectId.ToByteArray());
        var error = await Assert.ThrowsAsync<SqliteException>(() => command.ExecuteNonQueryAsync());
        Assert.Equal(19, error.SqliteErrorCode);
        command.Parameters.Clear();
        command.CommandText = "SELECT content_hash,checksum FROM stored_objects;";
        await using (var reader = await command.ExecuteReaderAsync())
        {
            Assert.True(await reader.ReadAsync());
            Assert.Equal(digest[..16], (byte[])reader.GetValue(0));
            Assert.Equal(digest, (byte[])reader.GetValue(1));
            Assert.False(await reader.ReadAsync());
        }
        command.CommandText = "SELECT COUNT(*) FROM pragma_table_info('stored_objects') WHERE name='content_hash_algorithm';";
        Assert.Equal(0L, await command.ExecuteScalarAsync());
        command.CommandText = "PRAGMA foreign_key_check;";
        await using (var reader = await command.ExecuteReaderAsync()) Assert.False(await reader.ReadAsync());
        command.CommandText = "PRAGMA integrity_check;";
        Assert.Equal("ok", await command.ExecuteScalarAsync());
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task FullScan_ReusesCurrentFingerprintOrChecksum_ThenRestoresBothRevisions(bool recordFingerprint)
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        var file = Path.Combine(sourcePath, "file.bin");
        await File.WriteAllTextAsync(file, "before");
        // Exercise both readers and let a reader process another file in the same batch.
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "stable-a.bin"), "stable one");
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "stable-b.bin"), "stable two");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repository.RepositoryPath);
        var metadata = new FrozenTimesMetadataReader();
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, false);
        var telemetryOptions = new TelemetryOptions(TelemetryMode.Off, 16, 10, 10, 32);
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Fingerprint", sourcePath);
        await new InitialBackupRunner(new StreamingFullScanner(metadata),
            new StableFileCapturer(metadata, recordContentHash: recordFingerprint), new NoCheckpoint())
            .RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        await AssertDigestsAsync(repository, source.SourceId, 1, "before", recordFingerprint);
        var baseline = await repository.GetSourceStateAsync(source.SourceId);
        var runner = new IncrementalBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
            metadata, new UnavailableJournal(), new UsnDeltaPlanner());
        var unchanged = await runner.RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        Assert.Equal(BackupScanMode.FullScan, unchanged.ScanMode);
        Assert.Null(unchanged.Revision);
        Assert.Equal(baseline, await repository.GetSourceStateAsync(source.SourceId));
        await using (var connection = await repository.OpenConnectionAsync())
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = "SELECT COUNT(*) FROM stored_objects;";
            Assert.Equal(3L, await command.ExecuteScalarAsync());
            command.CommandText = "SELECT COUNT(*) FROM packs;";
            Assert.Equal(1L, await command.ExecuteScalarAsync());
        }
        // Same identity, length and frozen times: only content comparison can detect this.
        await File.WriteAllTextAsync(file, "after!");
        var changed = await runner.RunAsync(repository, telemetry, lease, source, storage, telemetryOptions);
        Assert.Equal(BackupScanMode.FullScan, changed.ScanMode);
        Assert.Equal(2L, changed.Revision);
        await AssertDigestsAsync(repository, source.SourceId, 1, "before", recordFingerprint);
        await AssertDigestsAsync(repository, source.SourceId, 2, "after!", true);
        var reopened = await RepositoryDatabase.OpenExistingAsync(repository.RepositoryPath);
        foreach (var (revision, expected) in new[] { (1L, "before"), (2L, "after!") })
        {
            var target = temp.GetPath($"restore-{revision}");
            await new RevisionRestorer().RestoreAsync(reopened, source.SourceId, revision, target);
            Assert.Equal(expected, await File.ReadAllTextAsync(Path.Combine(target, "file.bin")));
            Assert.Equal("stable one", await File.ReadAllTextAsync(Path.Combine(target, "stable-a.bin")));
            Assert.Equal("stable two", await File.ReadAllTextAsync(Path.Combine(target, "stable-b.bin")));
        }
        Assert.True((await new RepositoryVerifier().VerifyAsync(reopened)).IsValid);
    }

    private static async Task AssertDigestsAsync(RepositoryDatabase repository, long sourceId,
        long revision, string content, bool hasFingerprint)
    {
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT object.content_hash,object.checksum FROM entry_catalog AS entry
            JOIN stored_objects AS object ON object.object_id=entry.object_id
            WHERE entry.source_id=$source AND entry.valid_from_revision<=$revision
              AND (entry.valid_to_revision IS NULL OR entry.valid_to_revision>$revision)
              AND entry.tombstone=0 AND entry.display_path='file.bin';
            """;
        command.Parameters.AddWithValue("$source", sourceId);
        command.Parameters.AddWithValue("$revision", revision);
        await using var reader = await command.ExecuteReaderAsync();
        Assert.True(await reader.ReadAsync());
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(content));
        if (hasFingerprint) Assert.Equal(digest[..16], (byte[])reader.GetValue(0));
        else Assert.True(reader.IsDBNull(0));
        Assert.Equal(digest, (byte[])reader.GetValue(1));
        Assert.False(await reader.ReadAsync());
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
            Usn = null,
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
