using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core;
using PzTools.Backup.Engine;
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
