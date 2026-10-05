using System.Globalization;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

/// <summary>
/// One rule for links on both scan paths: a junction or symbolic link inside the save is neither
/// captured nor entered, and the save folder itself (or a folder above it) may be a link, which is
/// followed. The journal and the full scan must reach the same backup either way.
/// </summary>
public sealed class LinkedSourceTests
{
    private static readonly StorageOptions Storage = new(
        ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, ContentDeduplication: false);

    private static readonly TelemetryOptions Telemetry = new(TelemetryMode.Off, 16, 10, 10, 32);

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ALinkCreatedInsideTheSave_IsLeftOut_ByTheJournalAsByTheFullScan(bool journal)
    {
        using var temp = new TempDirectory();
        var save = temp.GetPath("save");
        var outside = temp.GetPath("outside");
        Directory.CreateDirectory(save);
        Directory.CreateDirectory(outside);
        await File.WriteAllTextAsync(Path.Combine(save, "map_t.bin"), "save");
        await File.WriteAllTextAsync(Path.Combine(outside, "secret.txt"), "not part of the save");
        var metadata = new WindowsFileMetadataReader();
        await using var setup = await CreateInitialAsync(temp, save);
        var link = Path.Combine(save, "linked");
        await CreateJunctionAsync(link, outside);
        try
        {
            var records = new[]
            {
                Record(Reference(metadata.ReadPath(outside)), Reference(metadata.ReadPath(save)), 110,
                    UsnReason.FileCreate, "linked") with
                {
                    FileAttributes = FileAttributes.Directory | FileAttributes.ReparsePoint,
                },
            };

            var result = await Runner(metadata, journal ? new FakeJournal(records) : new NoJournal()).RunAsync(
                setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);

            Assert.Equal(journal ? BackupScanMode.Journal : BackupScanMode.FullScan, result.ScanMode);
            Assert.Null(result.Revision);
        }
        finally
        {
            Directory.Delete(link);
        }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task AFolderReplacedByALink_IsClosedWithEverythingBeneathIt_AndNothingIsReadThroughIt(bool journal)
    {
        using var temp = new TempDirectory();
        var save = temp.GetPath("save");
        var folder = Path.Combine(save, "folder");
        var outside = temp.GetPath("outside");
        Directory.CreateDirectory(folder);
        Directory.CreateDirectory(outside);
        await File.WriteAllTextAsync(Path.Combine(save, "map_t.bin"), "save");
        var child = Path.Combine(folder, "child.bin");
        await File.WriteAllTextAsync(child, "old child");
        // Same name behind the link: reading through it would find a "child.bin" again.
        await File.WriteAllTextAsync(Path.Combine(outside, "child.bin"), "not part of the save");
        var metadata = new WindowsFileMetadataReader();
        var root = Reference(metadata.ReadPath(save));
        var oldFolder = Reference(metadata.ReadPath(folder));
        var oldChild = Reference(metadata.ReadPath(child));
        await using var setup = await CreateInitialAsync(temp, save);
        Directory.Delete(folder, recursive: true);
        await CreateJunctionAsync(folder, outside);
        try
        {
            var records = new[]
            {
                Record(oldChild, oldFolder, 110, UsnReason.FileDelete, "child.bin"),
                Record(oldFolder, root, 120, UsnReason.FileDelete, "folder") with { FileAttributes = FileAttributes.Directory },
                Record(Reference(metadata.ReadPath(outside)), root, 130, UsnReason.FileCreate, "folder") with
                {
                    FileAttributes = FileAttributes.Directory | FileAttributes.ReparsePoint,
                },
            };

            var result = await Runner(metadata, journal ? new FakeJournal(records) : new NoJournal()).RunAsync(
                setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);

            Assert.Equal(journal ? BackupScanMode.Journal : BackupScanMode.FullScan, result.ScanMode);
            Assert.Equal(2, result.Revision);
            var restored = temp.GetPath("restored");
            await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, 2, restored);
            Assert.Equal(["map_t.bin"], Directory.EnumerateFileSystemEntries(restored, "*", SearchOption.AllDirectories)
                .Select(path => Path.GetRelativePath(restored, path)).ToArray());
        }
        finally
        {
            Directory.Delete(folder);
        }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ASaveFolderThatIsALink_IsFollowed_AndADeletionInItIsBackedUp(bool journal)
    {
        using var temp = new TempDirectory();
        var real = temp.GetPath("other-drive", "save");
        Directory.CreateDirectory(real);
        await File.WriteAllTextAsync(Path.Combine(real, "map_t.bin"), "save");
        var deleted = Path.Combine(real, "players.db");
        await File.WriteAllTextAsync(deleted, "player");
        var save = temp.GetPath("save");
        await CreateJunctionAsync(save, real);
        try
        {
            var metadata = new WindowsFileMetadataReader();
            var deletedReference = Reference(metadata.ReadPath(deleted));
            await using var setup = await CreateInitialAsync(temp, save);
            File.Delete(deleted);
            var records = new[]
            {
                Record(deletedReference, Reference(metadata.ReadPath(save)), 110, UsnReason.FileDelete, "players.db"),
            };

            var result = await Runner(metadata, journal ? new FakeJournal(records) : new NoJournal()).RunAsync(
                setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);

            Assert.Equal(journal ? BackupScanMode.Journal : BackupScanMode.FullScan, result.ScanMode);
            Assert.Equal(2, result.Revision);
            var restored = temp.GetPath("restored");
            await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, 2, restored);
            Assert.Equal("save", await File.ReadAllTextAsync(Path.Combine(restored, "map_t.bin")));
            Assert.False(File.Exists(Path.Combine(restored, "players.db")));
        }
        finally
        {
            Directory.Delete(save);
        }
    }

    [Fact]
    public async Task ASaveFolderThatIsNowAnotherFolder_IsScannedInFull_ThoughTheJournalSaysNothingChanged()
    {
        using var temp = new TempDirectory();
        var save = temp.GetPath("save");
        Directory.CreateDirectory(save);
        await File.WriteAllTextAsync(Path.Combine(save, "map_t.bin"), "old world");
        await using var setup = await CreateInitialAsync(temp, save);
        // A copy moved into its place: nothing beneath the new folder was written since the checkpoint.
        var copy = temp.GetPath("copy");
        Directory.CreateDirectory(copy);
        await File.WriteAllTextAsync(Path.Combine(copy, "map_t.bin"), "other world");
        Directory.Move(save, temp.GetPath("save-old"));
        Directory.Move(copy, save);

        var result = await Runner(new WindowsFileMetadataReader(), new FakeJournal([])).RunAsync(
            setup.Repository, setup.Telemetry, setup.Lease, setup.Source, Storage, Telemetry);

        Assert.Equal(BackupScanMode.FullScan, result.ScanMode);
        Assert.Contains("not the folder the previous backup read", result.FullScanReason, StringComparison.Ordinal);
        Assert.Equal(2, result.Revision);
        var restored = temp.GetPath("restored");
        await new RevisionRestorer().RestoreAsync(setup.Repository, setup.Source.SourceId, 2, restored);
        Assert.Equal("other world", await File.ReadAllTextAsync(Path.Combine(restored, "map_t.bin")));
    }

    [Fact]
    public async Task TheJournalVolume_IsTheOneTheLinkedFolderIsOn()
    {
        using var temp = new TempDirectory();
        var real = temp.GetPath("real");
        Directory.CreateDirectory(real);
        var link = temp.GetPath("link");
        await CreateJunctionAsync(link, real);
        try
        {
            // GetVolumePathName would answer from the link's own path; the final path is the target's.
            var followed = FinalVolumePath.Resolve(link);
            Assert.Equal(FinalVolumePath.Resolve(real), followed);
            Assert.EndsWith(@"\real", followed, StringComparison.OrdinalIgnoreCase);
            var volume = FinalVolumePath.ResolveVolumeRoot(link);
            Assert.StartsWith(@"\\?\Volume{", volume, StringComparison.OrdinalIgnoreCase);
            Assert.EndsWith(@"}\", volume, StringComparison.Ordinal);
            Assert.True(LocalVolume.IsLocalNtfs(link));
        }
        finally
        {
            Directory.Delete(link);
        }
    }

    private static async Task CreateJunctionAsync(string link, string target)
    {
        var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");
        var junction = await new ChildProcessHost().RunAsync(shell,
            ["-NoProfile", "-Command", $"New-Item -ItemType Junction -Path '{link.Replace("'", "''")}' -Target '{target.Replace("'", "''")}'"]);
        Assert.True(junction.ExitCode == 0, junction.StandardError);
    }

    private static IncrementalBackupRunner Runner(IFileMetadataReader metadata, IUsnJournalSource journal) =>
        new(new StreamingFullScanner(metadata), new StableFileCapturer(metadata), metadata, journal, new UsnDeltaPlanner());

    private static async Task<Setup> CreateInitialAsync(TempDirectory temp, string sourcePath)
    {
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        var lease = RepositoryWriterLease.Acquire(repositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "main", sourcePath);
        var metadata = new WindowsFileMetadataReader();
        await new InitialBackupRunner(new StreamingFullScanner(metadata), new StableFileCapturer(metadata),
                new FixedBoundary())
            .RunAsync(repository, telemetry, lease, source, Storage, Telemetry);
        return new Setup(repository, telemetry, lease, source);
    }

    private static UInt128 Reference(FileCaptureMetadata metadata) =>
        UInt128.Parse(metadata.Identity[(metadata.Identity.LastIndexOf(':') + 1)..],
            NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);

    private static UsnRecord Record(UInt128 file, UInt128 parent, long usn, UsnReason reason, string name) =>
        new(3, 0, file, parent, usn, DateTimeOffset.UtcNow, reason, 0, FileAttributes.Normal, name);

    private sealed record Setup(
        RepositoryDatabase Repository,
        TelemetryStore Telemetry,
        RepositoryWriterLease Lease,
        RepositorySource Source) : IAsyncDisposable
    {
        public ValueTask DisposeAsync() => Lease.DisposeAsync();
    }

    private sealed class FixedBoundary : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) =>
            new(new SourceCheckpoint("0000000000000001", "0000000000000002", 100), null);
    }

    private sealed class FakeJournal(IReadOnlyList<UsnRecord> records) : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => new(1, 2, 0, 200, 0);

        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) => records;
    }

    private sealed class NoJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new PlatformNotSupportedException();

        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("Must use full scan");
    }
}
