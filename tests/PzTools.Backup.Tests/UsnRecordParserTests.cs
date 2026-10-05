using System.Buffers.Binary;
using System.Text;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Capture;

namespace PzTools.Backup.Tests;

public sealed class UsnRecordParserTests
{
    [Fact]
    public void ParseJournalBuffer_ParsesV2AndV3Records()
    {
        var v2 = CreateV2Record(
            fileId: 11,
            parentId: 7,
            usn: 101,
            UsnReason.DataOverwrite | UsnReason.Close,
            "map_1.bin");
        var v3FileId = ((UInt128)2 << 64) | 1;
        var v3ParentId = ((UInt128)4 << 64) | 3;
        var v3 = CreateV3Record(
            v3FileId,
            v3ParentId,
            usn: 102,
            UsnReason.RenameNewName,
            "새이름.bin");
        var buffer = new byte[8 + v2.Length + v3.Length];
        BinaryPrimitives.WriteInt64LittleEndian(buffer, 103);
        v2.CopyTo(buffer, 8);
        v3.CopyTo(buffer, 8 + v2.Length);

        var parsed = UsnRecordParser.ParseJournalBuffer(buffer);

        Assert.Equal(103, parsed.NextUsn);
        Assert.Collection(
            parsed.Records,
            record =>
            {
                Assert.Equal(2, record.MajorVersion);
                Assert.Equal((UInt128)11, record.FileReferenceNumber);
                Assert.Equal((UInt128)7, record.ParentFileReferenceNumber);
                Assert.Equal(101, record.Usn);
                Assert.Equal("map_1.bin", record.FileName);
                Assert.Equal(UsnReason.DataOverwrite | UsnReason.Close, record.Reason);
            },
            record =>
            {
                Assert.Equal(3, record.MajorVersion);
                Assert.Equal(v3FileId, record.FileReferenceNumber);
                Assert.Equal(v3ParentId, record.ParentFileReferenceNumber);
                Assert.Equal(102, record.Usn);
                Assert.Equal("새이름.bin", record.FileName);
            });
    }

    [Fact]
    public void ParseJournalBuffer_RejectsTruncatedRecord()
    {
        var record = CreateV2Record(1, 2, 3, UsnReason.FileCreate, "a");
        var buffer = new byte[8 + record.Length - 1];
        BinaryPrimitives.WriteInt64LittleEndian(buffer, 4);
        record.AsSpan(0, record.Length - 1).CopyTo(buffer.AsSpan(8));

        Assert.Throws<InvalidDataException>(() => UsnRecordParser.ParseJournalBuffer(buffer));
    }

    [Fact]
    public void ParseJournalBuffer_RejectsUnsupportedRecordVersion()
    {
        var buffer = new byte[16];
        BinaryPrimitives.WriteInt64LittleEndian(buffer, 1);
        BinaryPrimitives.WriteUInt32LittleEndian(buffer.AsSpan(8, 4), 8);
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(12, 2), 4);

        Assert.Throws<InvalidDataException>(() => UsnRecordParser.ParseJournalBuffer(buffer));
    }

    [Theory]
    [InlineData(-1L)]
    [InlineData(long.MaxValue)]
    public void ParseJournalBuffer_ReportsATimestampOutsideTheDateRangeAsBadData(long timestamp)
    {
        // The planner falls back to a full scan on InvalidDataException; anything else fails the backup.
        var record = CreateV3Record(1, 2, 3, UsnReason.FileCreate, "a");
        BinaryPrimitives.WriteInt64LittleEndian(record.AsSpan(48, 8), timestamp);
        var buffer = new byte[8 + record.Length];
        BinaryPrimitives.WriteInt64LittleEndian(buffer, 4);
        record.CopyTo(buffer, 8);

        Assert.Throws<InvalidDataException>(() => UsnRecordParser.ParseJournalBuffer(buffer));
    }

    [Fact]
    public void ParseJournalBuffer_ReportsARecordLengthAboveInt32AsBadData()
    {
        var buffer = new byte[16];
        BinaryPrimitives.WriteInt64LittleEndian(buffer, 1);
        BinaryPrimitives.WriteUInt32LittleEndian(buffer.AsSpan(8, 4), uint.MaxValue);

        Assert.Throws<InvalidDataException>(() => UsnRecordParser.ParseJournalBuffer(buffer));
        Assert.Throws<InvalidDataException>(() => UsnRecordParser.ParseRecord(buffer.AsSpan(8)));
    }

    [UsnIntegrationFact]
    public void QueryRealNtfsVolume_WhenExplicitlyEnabled()
    {
        var state = new UsnJournalReader().Query(Environment.CurrentDirectory);

        Assert.True(state.JournalId > 0);
        Assert.True(state.NextUsn >= state.FirstUsn);
        Assert.True(state.VolumeSerialNumber > 0);
    }

    [UsnIntegrationFact]
    public void ReadRangeRealNtfsVolume_WhenExplicitlyEnabled()
    {
        using var temp = new TempDirectory();
        var journal = new UsnJournalReader();
        var before = journal.Query(temp.Path);
        var fileName = $"usn-{Guid.NewGuid():N}.bin";
        var path = temp.GetPath(fileName);
        File.WriteAllBytes(path, [1, 2, 3, 4]);
        var after = journal.Query(temp.Path);
        var checkpoint = new UsnCheckpoint(
            before.VolumeSerialNumber,
            before.JournalId,
            before.NextUsn);
        var expectedReference = DecodeReference(new WindowsFileMetadataReader().ReadPath(path));

        var records = journal.ReadRange(temp.Path, checkpoint, after.NextUsn).ToArray();

        Assert.Contains(records, record =>
            record.FileReferenceNumber == expectedReference
            && record.FileName.Equals(fileName, StringComparison.OrdinalIgnoreCase));
    }

    private static UInt128 DecodeReference(FileCaptureMetadata metadata)
    {
        var value = metadata.Identity[(metadata.Identity.LastIndexOf(':') + 1)..];
        return UInt128.Parse(
            value,
            System.Globalization.NumberStyles.AllowHexSpecifier,
            System.Globalization.CultureInfo.InvariantCulture);
    }

    private sealed class UsnIntegrationFactAttribute : FactAttribute
    {
        public UsnIntegrationFactAttribute()
        {
            if (!string.Equals(
                    Environment.GetEnvironmentVariable("PZTOOLS_TEST_USN"),
                    "1",
                    StringComparison.Ordinal))
            {
                Skip = "Set PZTOOLS_TEST_USN=1 in an elevated process.";
            }
        }
    }

    private static byte[] CreateV2Record(
        ulong fileId,
        ulong parentId,
        long usn,
        UsnReason reason,
        string name)
    {
        var nameBytes = Encoding.Unicode.GetBytes(name);
        var length = Align8(60 + nameBytes.Length);
        var record = new byte[length];
        WriteCommon(record, length, version: 2);
        BinaryPrimitives.WriteUInt64LittleEndian(record.AsSpan(8, 8), fileId);
        BinaryPrimitives.WriteUInt64LittleEndian(record.AsSpan(16, 8), parentId);
        WriteTail(record, usn, reason, nameBytes, usnOffset: 24, nameLengthOffset: 56,
            nameOffsetOffset: 58, nameOffset: 60);
        return record;
    }

    private static byte[] CreateV3Record(
        UInt128 fileId,
        UInt128 parentId,
        long usn,
        UsnReason reason,
        string name)
    {
        var nameBytes = Encoding.Unicode.GetBytes(name);
        var length = Align8(76 + nameBytes.Length);
        var record = new byte[length];
        WriteCommon(record, length, version: 3);
        WriteUInt128(record.AsSpan(8, 16), fileId);
        WriteUInt128(record.AsSpan(24, 16), parentId);
        WriteTail(record, usn, reason, nameBytes, usnOffset: 40, nameLengthOffset: 72,
            nameOffsetOffset: 74, nameOffset: 76);
        return record;
    }

    private static void WriteCommon(byte[] record, int length, ushort version)
    {
        BinaryPrimitives.WriteUInt32LittleEndian(record, (uint)length);
        BinaryPrimitives.WriteUInt16LittleEndian(record.AsSpan(4, 2), version);
        BinaryPrimitives.WriteUInt16LittleEndian(record.AsSpan(6, 2), 0);
    }

    private static void WriteTail(
        byte[] record,
        long usn,
        UsnReason reason,
        byte[] name,
        int usnOffset,
        int nameLengthOffset,
        int nameOffsetOffset,
        int nameOffset)
    {
        BinaryPrimitives.WriteInt64LittleEndian(record.AsSpan(usnOffset, 8), usn);
        BinaryPrimitives.WriteInt64LittleEndian(
            record.AsSpan(usnOffset + 8, 8),
            DateTimeOffset.UtcNow.ToFileTime());
        BinaryPrimitives.WriteUInt32LittleEndian(
            record.AsSpan(usnOffset + 16, 4),
            (uint)reason);
        BinaryPrimitives.WriteUInt32LittleEndian(
            record.AsSpan(usnOffset + 28, 4),
            (uint)FileAttributes.Normal);
        BinaryPrimitives.WriteUInt16LittleEndian(
            record.AsSpan(nameLengthOffset, 2),
            checked((ushort)name.Length));
        BinaryPrimitives.WriteUInt16LittleEndian(
            record.AsSpan(nameOffsetOffset, 2),
            checked((ushort)nameOffset));
        name.CopyTo(record, nameOffset);
    }

    private static void WriteUInt128(Span<byte> destination, UInt128 value)
    {
        BinaryPrimitives.WriteUInt64LittleEndian(destination[..8], (ulong)value);
        BinaryPrimitives.WriteUInt64LittleEndian(destination[8..], (ulong)(value >> 64));
    }

    private static int Align8(int value) => (value + 7) & ~7;
}
