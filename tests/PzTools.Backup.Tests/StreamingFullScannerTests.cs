using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Tests;

public sealed class StreamingFullScannerTests
{
    [Fact]
    public async Task Scan_StreamsFilesEmptyDirectoriesAndUnicodeIntoStaging()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(Path.Combine(sourcePath, "empty"));
        Directory.CreateDirectory(Path.Combine(sourcePath, "한글"));
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "한글", "파일.txt"), "content");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var progress = new List<long>();
        await using var scanner = await new StreamingFullScanner(new WindowsFileMetadataReader())
            .ScanAsync(repository, sourceId: 1, sourcePath,
                progress: count => { progress.Add(count); return ValueTask.CompletedTask; });

        var entries = new List<FullScanEntry>();
        await foreach (var entry in scanner.EnumerateEntriesAsync())
        {
            entries.Add(entry);
        }

        Assert.Equal(3, scanner.EntryCount);
        Assert.Equal(new long[] { 0, 1, 2, 3 }, progress);
        Assert.Equal(
            ["empty", "한글", "한글/파일.txt"],
            entries.Select(item => item.RelativePath).Order(StringComparer.Ordinal));
        Assert.Equal(CatalogEntryKind.File, entries.Single(item => item.Length > 0).Kind);
        Assert.All(entries, entry => Assert.NotEmpty(entry.FileId));
    }

    [Fact]
    public async Task Changes_AreComparedBySqlAgainstCurrentCatalog()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(Path.Combine(sourcePath, "keep"));
        Directory.CreateDirectory(Path.Combine(sourcePath, "remove"));
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        await using var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var scannerService = new StreamingFullScanner(new WindowsFileMetadataReader());

        await using (var initialScan = await scannerService.ScanAsync(
            repository,
            source.SourceId,
            sourcePath))
        {
            var registrations = new List<EntryVersionRegistration>();
            await foreach (var entry in initialScan.EnumerateEntriesAsync())
            {
                registrations.Add(ToRegistration(entry));
            }

            var run = await repository.StartRunAsync(lease, source.SourceId);
            await repository.CommitRevisionAsync(
                lease,
                new RevisionCommitRequest(
                    run.RunIndex,
                    source.SourceId,
                    Checkpoint: null,
                    Packs: [],
                    Objects: [],
                    Entries: registrations));
        }

        Directory.Delete(Path.Combine(sourcePath, "remove"));
        Directory.CreateDirectory(Path.Combine(sourcePath, "added"));

        await using var nextScan = await scannerService.ScanAsync(
            repository,
            source.SourceId,
            sourcePath);
        var changes = new List<FullScanChange>();
        await foreach (var change in nextScan.EnumerateChangesAsync())
        {
            changes.Add(change);
        }

        Assert.Contains(changes, item =>
            item.Kind == FullScanChangeKind.Added && item.Entry.RelativePath == "added");
        Assert.Contains(changes, item =>
            item.Kind == FullScanChangeKind.Deleted && item.Entry.RelativePath == "remove");
        Assert.DoesNotContain(changes, item => item.Entry.RelativePath == "keep");
    }

    [Fact]
    public async Task Staging_ReplacesEveryCapturedValueIncludingNullFingerprintWhileEnumerating()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "first"), "one");
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "second"), "second file");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var metadataReader = new WindowsFileMetadataReader();
        await using var scan = await new StreamingFullScanner(metadataReader).ScanAsync(repository, 1, sourcePath);
        var expected = new Dictionary<string, (Guid PackId, StableFileCaptureResult Capture)>();
        await foreach (var entry in scan.EnumerateEntriesAsync())
        {
            var index = expected.Count;
            var metadata = metadataReader.ReadPath(Path.Combine(sourcePath, entry.RelativePath)) with
            {
                ModifiedUtc = DateTimeOffset.UnixEpoch.AddSeconds(index + 1),
                ChangedUtc = DateTimeOffset.UnixEpoch.AddSeconds(index + 10),
                Attributes = index == 0 ? FileAttributes.Archive : FileAttributes.Normal,
            };
            var descriptor = new PackObjectDescriptor(Guid.NewGuid(), 100 + index, 200 + index,
                metadata.Length, 50 + index, index == 0 ? ChecksumAlgorithm.Sha256 : ChecksumAlgorithm.None,
                index == 0 ? new byte[32] : [],
                index == 0 ? CompressionAlgorithm.Brotli : CompressionAlgorithm.None, index);
            var capture = new StableFileCaptureResult(descriptor, metadata,
                index == 0 ? new byte[ContentFingerprint.Length] : null);
            var packId = Guid.NewGuid();
            await scan.StageCapturedFileAsync(entry.RelativePath, packId, capture);
            expected.Add(entry.RelativePath, (packId, capture));
        }

        var last = expected["second"];
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            scan.StageCapturedFileAsync("missing", last.PackId, last.Capture));
        await scan.StageCapturedFileAsync("SECOND", last.PackId, last.Capture);

        await using var command = scan.Connection.CreateCommand();
        command.CommandText = """
            SELECT display_path, byte_length, modified_utc, changed_utc, attributes, file_id,
                   object_id, pack_id, record_offset, stored_length, checksum_algorithm, checksum,
                   compression_algorithm, object_flags, content_hash
            FROM full_scan_entries ORDER BY path_key;
            """;
        await using var reader = await command.ExecuteReaderAsync();
        var rows = 0;
        while (await reader.ReadAsync())
        {
            rows++;
            var (packId, capture) = expected[reader.GetString(0)];
            var metadata = capture.SourceMetadata;
            Assert.Equal(metadata.Length, reader.GetInt64(1));
            Assert.Equal(metadata.ModifiedUtc.UtcTicks, reader.GetInt64(2));
            Assert.Equal(metadata.ChangedUtc.UtcTicks, reader.GetInt64(3));
            Assert.Equal((long)metadata.Attributes, reader.GetInt64(4));
            Assert.Equal(FileIdentityCodec.Encode(metadata.Identity), (byte[])reader.GetValue(5));
            Assert.Equal(capture.Object.ObjectId.ToByteArray(), (byte[])reader.GetValue(6));
            Assert.Equal(packId.ToByteArray(), (byte[])reader.GetValue(7));
            Assert.Equal(capture.Object.RecordOffset, reader.GetInt64(8));
            Assert.Equal(capture.Object.StoredLength, reader.GetInt64(9));
            Assert.Equal((int)capture.Object.ChecksumAlgorithm, reader.GetInt32(10));
            Assert.Equal(capture.Object.Checksum, (byte[])reader.GetValue(11));
            Assert.Equal((int)capture.Object.CompressionAlgorithm, reader.GetInt32(12));
            Assert.Equal(capture.Object.Flags, reader.GetInt32(13));
            if (capture.ContentHash is null) Assert.True(reader.IsDBNull(14));
            else Assert.Equal(capture.ContentHash, (byte[])reader.GetValue(14));
        }
        Assert.Equal(expected.Count, rows);
    }

    private static EntryVersionRegistration ToRegistration(FullScanEntry entry)
    {
        return new EntryVersionRegistration(
            entry.RelativePath,
            entry.Kind,
            Tombstone: false,
            entry.Length,
            entry.ModifiedUtc,
            entry.ChangedUtc,
            entry.Attributes,
            entry.FileId,
            entry.ParentFileId,
            ObjectId: null);
    }
}
