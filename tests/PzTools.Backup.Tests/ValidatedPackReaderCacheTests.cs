using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Core.Capture;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class ValidatedPackReaderCacheTests
{
    [Theory]
    [InlineData(CompressionAlgorithm.None)]
    [InlineData(CompressionAlgorithm.Brotli)]
    public async Task OnePackManyObjects_ValidatesOnceAndPinsTheVerifiedHandle(CompressionAlgorithm compression)
    {
        using var temp = new TempDirectory();
        var pack = await MakePackAsync(temp.GetPath("repository"), 1, compression);
        await using var cache = new ValidatedPackReaderCache(2);
        for (var pass = 0; pass < 3; pass++)
            foreach (var item in pack.Objects) await CopyAndAssertAsync(cache, pack, item);
        Assert.Equal(1, cache.ValidationCount);
        Assert.Equal(1, cache.CachedCount);
        Assert.Throws<IOException>(() => ExclusiveAccess(pack.Path));
        Assert.Throws<IOException>(() => File.Delete(pack.Path));
        Assert.Throws<IOException>(() => File.Move(pack.Path, temp.GetPath("replacement.pzpack")));
        await cache.DisposeAsync();
        await cache.DisposeAsync();
        ExclusiveAccess(pack.Path);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => CopyAndAssertAsync(cache, pack, pack.Objects[0]));
    }

    [Fact]
    public async Task LruEviction_IsBounded_ReleasesHandlesAndRevalidatesEvictedPacks()
    {
        using var temp = new TempDirectory();
        var packs = new List<PackFixture>();
        for (var i = 1; i <= 3; i++) packs.Add(await MakePackAsync(temp.GetPath("repository"), i));
        await using var cache = new ValidatedPackReaderCache(2);
        await CopyAndAssertAsync(cache, packs[0], packs[0].Objects[0]);
        await CopyAndAssertAsync(cache, packs[1], packs[1].Objects[0]);
        await CopyAndAssertAsync(cache, packs[0], packs[0].Objects[1]);
        await CopyAndAssertAsync(cache, packs[2], packs[2].Objects[0]);
        Assert.Equal(2, cache.CachedCount);
        Assert.Equal(3, cache.ValidationCount);
        ExclusiveAccess(packs[1].Path); // Second pack was least recently used.
        Assert.Throws<IOException>(() => ExclusiveAccess(packs[0].Path));
        await CopyAndAssertAsync(cache, packs[1], packs[1].Objects[1]);
        Assert.Equal(4, cache.ValidationCount);
        Assert.Equal(2, cache.CachedCount);
        ExclusiveAccess(packs[0].Path);
        await cache.ClearAsync();
        Assert.Equal(0, cache.CachedCount);
        foreach (var pack in packs) ExclusiveAccess(pack.Path);
    }

    [Fact]
    public async Task ReopenedPack_RejectsCorruptIndexAndWrongIdentity()
    {
        using var temp = new TempDirectory();
        var pack = await MakePackAsync(temp.GetPath("repository"), 1);
        await using var cache = new ValidatedPackReaderCache();
        await CopyAndAssertAsync(cache, pack, pack.Objects[0]);
        await cache.ClearAsync();
        await Assert.ThrowsAsync<PackFormatException>(() => cache.CopyObjectAtAsync(pack.Path, Guid.NewGuid(),
            pack.Objects[0].Descriptor.ObjectId, pack.Objects[0].Descriptor.RecordOffset, Stream.Null));
        ExclusiveAccess(pack.Path);
        using (var write = new FileStream(pack.Path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            write.Position = write.Length - PackFormat.TrailerSize - 1;
            var previous = write.ReadByte();
            write.Position--;
            write.WriteByte((byte)(previous ^ 1));
        }
        await Assert.ThrowsAsync<PackFormatException>(() => CopyAndAssertAsync(cache, pack, pack.Objects[0]));
        Assert.Equal(0, cache.CachedCount);
        ExclusiveAccess(pack.Path);
    }

    [Fact]
    public async Task EveryLocatedRead_StillChecksTheFullObjectChecksum()
    {
        using var temp = new TempDirectory();
        var pack = await MakePackAsync(temp.GetPath("repository"), 1);
        // An intact index and object header must not hide damaged payload bytes.
        using (var write = new FileStream(pack.Path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            write.Position = pack.Objects[0].Descriptor.PayloadOffset;
            var previous = write.ReadByte();
            write.Position--;
            write.WriteByte((byte)(previous ^ 1));
        }
        await using var cache = new ValidatedPackReaderCache();
        await Assert.ThrowsAsync<PackFormatException>(() => cache.CopyObjectAtAsync(pack.Path, pack.Id,
            pack.Objects[0].Descriptor.ObjectId, pack.Objects[0].Descriptor.RecordOffset, Stream.Null));
        Assert.Equal(1, cache.ValidationCount); // Structural validation succeeded, payload verification did not.
        Assert.Equal(0, cache.CachedCount);
        ExclusiveAccess(pack.Path);
    }

    [Theory]
    [InlineData("cancel")]
    [InlineData("io")]
    [InlineData("mismatch")]
    public async Task FailedOrCancelledComparison_EvictsAndReleasesItsHandle(string failure)
    {
        using var temp = new TempDirectory();
        var pack = await MakePackAsync(temp.GetPath("repository"), 1);
        await using var cache = new ValidatedPackReaderCache();
        await CopyAndAssertAsync(cache, pack, pack.Objects[0]);
        using var cancel = new CancellationTokenSource();
        using var destination = new FailingDestination(failure, cancel);
        var error = await Record.ExceptionAsync(() => cache.CopyObjectAtAsync(pack.Path, pack.Id,
            pack.Objects[0].Descriptor.ObjectId, pack.Objects[0].Descriptor.RecordOffset, destination, cancel.Token));
        switch (failure)
        {
            case "cancel": Assert.IsAssignableFrom<OperationCanceledException>(error); break;
            case "io": Assert.IsType<IOException>(error); break;
            default: Assert.IsType<ContentComparisonStream.ContentMismatchException>(error); break;
        }
        Assert.Equal(0, cache.CachedCount);
        ExclusiveAccess(pack.Path);
        await CopyAndAssertAsync(cache, pack, pack.Objects[0]);
        Assert.Equal(2, cache.ValidationCount);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task IncrementalRun_ReusesCommittedPackAndReleasesItOnEveryExit(bool failCommit)
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("source");
        Directory.CreateDirectory(root);
        await File.WriteAllTextAsync(Path.Combine(root, "one.bin"), "same content");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", root);
        var metadata = new WindowsFileMetadataReader();
        var stable = new StableFileCapturer(metadata);
        await using var capture = new DeduplicatingFileCapturer(stable);
        var storage = new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, true);
        var telemetry = TelemetryStore.CreateDisabled(repository.RepositoryPath);
        var trace = new TelemetryOptions(TelemetryMode.Off, 8, 5, 10, 32);
        await new InitialBackupRunner(new StreamingFullScanner(metadata), stable, new NoCheckpoint(), deduplicatingCapturer: capture)
            .RunAsync(repository, telemetry, lease, source, storage, trace);
        var packPath = Path.Combine(repository.RepositoryPath, Assert.Single(await repository.ReadPacksAsync()).RelativePath);
        await File.WriteAllTextAsync(Path.Combine(root, "two.bin"), "same content");
        await File.WriteAllTextAsync(Path.Combine(root, "three.bin"), "same content");
        var runner = new IncrementalBackupRunner(new StreamingFullScanner(metadata), stable, metadata, new NoJournal(),
            new UsnDeltaPlanner(), failureInjector: failCommit ? new CommitFailure() : null, deduplicatingCapturer: capture);
        if (failCommit)
            await Assert.ThrowsAsync<IOException>(() => runner.RunAsync(repository, telemetry, lease, source, storage, trace));
        else
        {
            Assert.Equal(2, (await runner.RunAsync(repository, telemetry, lease, source, storage, trace)).Revision);
            var restored = temp.GetPath("restored");
            await new RevisionRestorer().RestoreAsync(repository, source.SourceId, 2, restored);
            Assert.Equal("same content", await File.ReadAllTextAsync(Path.Combine(restored, "three.bin")));
            Assert.Equal(3, Directory.GetFiles(restored).Length);
        }
        Assert.Equal(1, capture.PackValidationCount); // Both new paths reuse one structure validation.
        ExclusiveAccess(packPath); // Before disposing the injected capturer.
        Assert.Equal(failCommit ? 1 : 2, (await repository.GetSourceStateAsync(source.SourceId)).CurrentRevision);
        Assert.True((await new RepositoryVerifier().VerifyAsync(repository)).IsValid);
    }

    [Fact]
    public async Task DirectCapture_StagingFailureReleasesPreviouslyCachedHandles()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("source");
        Directory.CreateDirectory(root);
        var path = Path.Combine(root, "one.bin");
        await File.WriteAllTextAsync(path, "cached content");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        await using var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath);
        var source = await repository.AddOrGetSourceAsync(lease, "Sandbox/Test", root);
        var metadata = new WindowsFileMetadataReader();
        var stable = new StableFileCapturer(metadata, maxAttempts: 1);
        await new InitialBackupRunner(new StreamingFullScanner(metadata), stable, new NoCheckpoint()).RunAsync(
            repository, TelemetryStore.CreateDisabled(repository.RepositoryPath), lease, source,
            new(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false), new(TelemetryMode.Off, 8, 5, 10, 32));
        var packPath = Path.Combine(repository.RepositoryPath, Assert.Single(await repository.ReadPacksAsync()).RelativePath);
        await using var capture = new DeduplicatingFileCapturer(stable);
        await using var writer = await PackWriter.CreateAsync(repository.RepositoryPath, 2);
        Assert.True((await capture.CaptureAsync(repository, path, writer, ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, true)).Reused);
        Assert.Throws<IOException>(() => ExclusiveAccess(packPath));
        await Assert.ThrowsAsync<UnstableFileException>(() => capture.CaptureAsync(repository, temp.GetPath("missing"), writer,
            ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, true));
        ExclusiveAccess(packPath);
        await Assert.ThrowsAsync<InvalidOperationException>(() => writer.SealAndPromoteAsync());
    }

    private static void ExclusiveAccess(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
    }
    private static async Task CopyAndAssertAsync(ValidatedPackReaderCache cache, PackFixture pack, ObjectFixture item)
    {
        await using var content = new MemoryStream();
        await cache.CopyObjectAtAsync(pack.Path, pack.Id, item.Descriptor.ObjectId, item.Descriptor.RecordOffset, content);
        Assert.Equal(item.Bytes, content.ToArray());
    }
    private static async Task<PackFixture> MakePackAsync(string root, long run, CompressionAlgorithm compression = CompressionAlgorithm.None)
    {
        await using var writer = await PackWriter.CreateAsync(root, run);
        var objects = new List<ObjectFixture>();
        for (var i = 0; i < 3; i++)
        {
            var bytes = new byte[32 * 1024 + i];
            new Random((int)run * 17 + i).NextBytes(bytes);
            using var source = new MemoryStream(bytes);
            objects.Add(new(await writer.AddObjectAsync(source, ChecksumAlgorithm.Sha256, compression), bytes));
        }
        var pack = await writer.SealAndPromoteAsync();
        return new(pack.FullPath, pack.PackId, objects);
    }
    private sealed record PackFixture(string Path, Guid Id, List<ObjectFixture> Objects);
    private sealed record ObjectFixture(PackObjectDescriptor Descriptor, byte[] Bytes);
    private sealed class NoCheckpoint : ICheckpointBoundaryProvider
    {
        public CheckpointBoundaryResult Capture(string sourcePath) => new(null, "isolated fixture");
    }
    private sealed class NoJournal : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => throw new PlatformNotSupportedException();
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint, long upperUsnExclusive,
            CancellationToken cancellationToken = default) => throw new InvalidOperationException();
    }
    private sealed class CommitFailure : IBackupFailureInjector
    {
        public void ThrowIfRequested(BackupFailurePoint point)
        {
            if (point == BackupFailurePoint.BeforeRepositoryCommit) throw new IOException("injected before commit");
        }
    }
    private sealed class FailingDestination(string failure, CancellationTokenSource cancellation) : Stream
    {
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (failure == "cancel") { cancellation.Cancel(); return ValueTask.FromCanceled(cancellation.Token); }
            return ValueTask.FromException(failure == "io" ? new IOException("injected destination")
                : new ContentComparisonStream.ContentMismatchException());
        }
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }
}
