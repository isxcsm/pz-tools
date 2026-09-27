using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Engine;

namespace PzTools.Backup.Tests;

public sealed class UsnDeltaPlannerTests
{
    private static readonly UInt128 Root = 1;
    private static readonly DateTimeOffset Now = DateTimeOffset.UtcNow;

    [Fact]
    public void Plan_ReducesRepeatedFileChangesToOnePath()
    {
        var planner = new UsnDeltaPlanner();
        var current = new[] { new TrackedPath(2, Root, "file.bin", IsDirectory: false) };
        var records = new[]
        {
            Record(2, Root, 10, UsnReason.DataOverwrite, "file.bin"),
            Record(2, Root, 11, UsnReason.DataExtend | UsnReason.Close, "file.bin"),
        };

        var result = planner.Plan(Root, current, records);

        Assert.Equal(["file.bin"], result.AffectedPaths);
        Assert.Empty(result.SubtreeRoots);
        Assert.Equal((UInt128)2, Assert.Single(result.ContentChangedFileReferences));
    }

    [Theory]
    [InlineData(UsnReason.DataOverwrite)]
    [InlineData(UsnReason.DataExtend)]
    [InlineData(UsnReason.DataTruncation)]
    [InlineData(UsnReason.NamedDataOverwrite)]
    [InlineData(UsnReason.NamedDataExtend)]
    [InlineData(UsnReason.NamedDataTruncation)]
    public void Plan_PreservesContentChangeIdentityAcrossRename(UsnReason reason)
    {
        var result = new UsnDeltaPlanner().Plan(Root,
            [new TrackedPath(2, Root, "old.bin", IsDirectory: false)],
            [Record(2, Root, 10, reason, "old.bin"),
             Record(2, Root, 11, UsnReason.RenameOldName, "old.bin"),
             Record(2, Root, 12, UsnReason.RenameNewName, "new.bin")]);
        Assert.Equal(["new.bin", "old.bin"], result.AffectedPaths);
        Assert.Equal((UInt128)2, Assert.Single(result.ContentChangedFileReferences));
    }

    [Fact]
    public void Plan_MetadataOnlyChangeDoesNotForceContentCapture()
    {
        var result = new UsnDeltaPlanner().Plan(Root,
            [new TrackedPath(2, Root, "file.bin", IsDirectory: false)],
            [Record(2, Root, 10, UsnReason.BasicInfoChange | UsnReason.Close, "file.bin")]);
        Assert.Equal(["file.bin"], result.AffectedPaths);
        Assert.Empty(result.ContentChangedFileReferences);
    }

    [Fact]
    public void Plan_TracksRenameInsideSource()
    {
        var planner = new UsnDeltaPlanner();
        var current = new[] { new TrackedPath(2, Root, "old.bin", IsDirectory: false) };
        var records = new[]
        {
            Record(2, Root, 10, UsnReason.RenameOldName, "old.bin"),
            Record(2, Root, 11, UsnReason.RenameNewName, "new.bin"),
        };

        var result = planner.Plan(Root, current, records);

        Assert.Equal(["new.bin", "old.bin"], result.AffectedPaths);
    }

    [Fact]
    public void Plan_HandlesMoveOutAndMoveIn()
    {
        var planner = new UsnDeltaPlanner();
        var current = new[] { new TrackedPath(2, Root, "leaving.bin", IsDirectory: false) };
        var records = new[]
        {
            Record(2, Root, 10, UsnReason.RenameOldName, "leaving.bin"),
            Record(2, 999, 11, UsnReason.RenameNewName, "outside.bin"),
            Record(3, 999, 12, UsnReason.RenameOldName, "incoming.bin"),
            Record(3, Root, 13, UsnReason.RenameNewName, "incoming.bin"),
        };

        var result = planner.Plan(Root, current, records);

        Assert.Equal(["incoming.bin", "leaving.bin"], result.AffectedPaths);
    }

    [Fact]
    public void Plan_MarksDirectoryRenameForSubtreeRescan()
    {
        var planner = new UsnDeltaPlanner();
        var current = new[] { new TrackedPath(2, Root, "old", IsDirectory: true) };
        var records = new[]
        {
            Record(2, Root, 10, UsnReason.RenameOldName, "old", directory: true),
            Record(2, Root, 11, UsnReason.RenameNewName, "new", directory: true),
        };

        var result = planner.Plan(Root, current, records);

        Assert.Equal(["new", "old"], result.SubtreeRoots);
    }

    [Fact]
    public void Plan_IgnoresUnrelatedVolumeRecords()
    {
        var result = new UsnDeltaPlanner().Plan(
            Root,
            currentPaths: [],
            [Record(50, 40, 10, UsnReason.DataOverwrite, "elsewhere.bin")]);

        Assert.Empty(result.AffectedPaths);
    }

    [Fact]
    public void Accumulator_PreservesRenamePairAcrossReadBatches()
    {
        var accumulator = new UsnDeltaPlanner().CreateAccumulator(Root);
        accumulator.AddTrackedPaths(
            [new TrackedPath(2, Root, "old.bin", IsDirectory: false)]);

        accumulator.AddRecords(
            [Record(2, Root, 10, UsnReason.RenameOldName, "old.bin")]);
        accumulator.AddRecords(
            [Record(2, Root, 11, UsnReason.RenameNewName, "new.bin")]);

        Assert.Equal(["new.bin", "old.bin"], accumulator.Build().AffectedPaths);
    }

    [Fact]
    public void Accumulator_TracksAllHardLinksForOneFileReference()
    {
        var accumulator = new UsnDeltaPlanner().CreateAccumulator(Root);
        accumulator.AddTrackedPaths(
        [
            new TrackedPath(2, Root, "first.bin", IsDirectory: false),
            new TrackedPath(2, Root, "second.bin", IsDirectory: false),
        ]);

        accumulator.AddRecords(
            [Record(2, Root, 10, UsnReason.DataOverwrite, "first.bin")]);

        Assert.Equal(["first.bin", "second.bin"], accumulator.Build().AffectedPaths);
    }

    private static UsnRecord Record(
        UInt128 file,
        UInt128 parent,
        long usn,
        UsnReason reason,
        string name,
        bool directory = false) =>
        new(
            MajorVersion: 3,
            MinorVersion: 0,
            file,
            parent,
            usn,
            Now,
            reason,
            SourceInfo: 0,
            directory ? FileAttributes.Directory : FileAttributes.Normal,
            name);
}
