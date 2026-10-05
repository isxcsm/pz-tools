using System.Buffers.Binary;
using System.Text;

namespace PzTools.Backup.ChangeTracking.Windows;

public static class UsnRecordParser
{
    private static readonly long MaximumFileTime = DateTime.MaxValue.ToFileTimeUtc();

    public static UsnReadBuffer ParseJournalBuffer(ReadOnlySpan<byte> buffer)
    {
        if (buffer.Length < sizeof(long))
        {
            throw new InvalidDataException("USN journal buffer is shorter than its next-USN header.");
        }

        var nextUsn = BinaryPrimitives.ReadInt64LittleEndian(buffer);
        var records = new List<UsnRecord>();
        var offset = sizeof(long);
        while (offset < buffer.Length)
        {
            if (buffer.Length - offset < 8)
            {
                throw new InvalidDataException("USN record common header is truncated.");
            }

            // Compared before narrowing: a damaged length above int.MaxValue is bad data like any
            // other, so it must not escape as an OverflowException that nothing falls back from.
            var recordLength = BinaryPrimitives.ReadUInt32LittleEndian(buffer.Slice(offset, 4));
            if (recordLength < 8 || recordLength > (uint)(buffer.Length - offset))
            {
                throw new InvalidDataException("USN record length is outside the returned buffer.");
            }

            records.Add(ParseRecord(buffer.Slice(offset, (int)recordLength)));
            offset += (int)recordLength;
        }

        return new UsnReadBuffer(nextUsn, records);
    }

    public static UsnRecord ParseRecord(ReadOnlySpan<byte> record)
    {
        if (record.Length < 8)
        {
            throw new InvalidDataException("USN record is shorter than its common header.");
        }

        var declaredLength = BinaryPrimitives.ReadUInt32LittleEndian(record);
        if (declaredLength != (uint)record.Length)
        {
            throw new InvalidDataException("USN record length does not match its buffer.");
        }

        var major = BinaryPrimitives.ReadUInt16LittleEndian(record.Slice(4, 2));
        var minor = BinaryPrimitives.ReadUInt16LittleEndian(record.Slice(6, 2));
        return major switch
        {
            2 => ParseV2(record, major, minor),
            3 => ParseV3(record, major, minor),
            _ => throw new InvalidDataException($"Unsupported USN record version {major}.{minor}."),
        };
    }

    private static UsnRecord ParseV2(ReadOnlySpan<byte> record, ushort major, ushort minor)
    {
        const int minimumLength = 60;
        EnsureMinimum(record, minimumLength, major);
        return CreateRecord(
            record,
            major,
            minor,
            BinaryPrimitives.ReadUInt64LittleEndian(record.Slice(8, 8)),
            BinaryPrimitives.ReadUInt64LittleEndian(record.Slice(16, 8)),
            usnOffset: 24,
            timestampOffset: 32,
            reasonOffset: 40,
            sourceOffset: 44,
            attributesOffset: 52,
            nameLengthOffset: 56,
            nameOffsetOffset: 58);
    }

    private static UsnRecord ParseV3(ReadOnlySpan<byte> record, ushort major, ushort minor)
    {
        const int minimumLength = 76;
        EnsureMinimum(record, minimumLength, major);
        return CreateRecord(
            record,
            major,
            minor,
            ReadUInt128(record.Slice(8, 16)),
            ReadUInt128(record.Slice(24, 16)),
            usnOffset: 40,
            timestampOffset: 48,
            reasonOffset: 56,
            sourceOffset: 60,
            attributesOffset: 68,
            nameLengthOffset: 72,
            nameOffsetOffset: 74);
    }

    private static UsnRecord CreateRecord(
        ReadOnlySpan<byte> record,
        ushort major,
        ushort minor,
        UInt128 fileReference,
        UInt128 parentReference,
        int usnOffset,
        int timestampOffset,
        int reasonOffset,
        int sourceOffset,
        int attributesOffset,
        int nameLengthOffset,
        int nameOffsetOffset)
    {
        var nameLength = BinaryPrimitives.ReadUInt16LittleEndian(
            record.Slice(nameLengthOffset, 2));
        var nameOffset = BinaryPrimitives.ReadUInt16LittleEndian(
            record.Slice(nameOffsetOffset, 2));
        if ((nameLength & 1) != 0
            || nameOffset > record.Length
            || nameLength > record.Length - nameOffset)
        {
            throw new InvalidDataException("USN record filename range is invalid.");
        }

        var usn = BinaryPrimitives.ReadInt64LittleEndian(record.Slice(usnOffset, 8));
        if (usn < 0)
        {
            throw new InvalidDataException("USN record contains a negative USN.");
        }

        // DateTime.FromFileTimeUtc throws ArgumentOutOfRangeException outside its range. A damaged
        // record is reported as InvalidDataException, the reader's one verdict on bad journal data,
        // so the backup falls back to a full scan instead of failing.
        var timestamp = BinaryPrimitives.ReadInt64LittleEndian(
            record.Slice(timestampOffset, 8));
        if (timestamp < 0 || timestamp > MaximumFileTime)
        {
            throw new InvalidDataException("USN record timestamp is outside the representable range.");
        }

        return new UsnRecord(
            major,
            minor,
            fileReference,
            parentReference,
            usn,
            new DateTimeOffset(DateTime.FromFileTimeUtc(timestamp)),
            (UsnReason)BinaryPrimitives.ReadUInt32LittleEndian(record.Slice(reasonOffset, 4)),
            BinaryPrimitives.ReadUInt32LittleEndian(record.Slice(sourceOffset, 4)),
            (FileAttributes)BinaryPrimitives.ReadUInt32LittleEndian(
                record.Slice(attributesOffset, 4)),
            Encoding.Unicode.GetString(record.Slice(nameOffset, nameLength)));
    }

    private static UInt128 ReadUInt128(ReadOnlySpan<byte> value)
    {
        var low = BinaryPrimitives.ReadUInt64LittleEndian(value[..8]);
        var high = BinaryPrimitives.ReadUInt64LittleEndian(value[8..]);
        return ((UInt128)high << 64) | low;
    }

    private static void EnsureMinimum(ReadOnlySpan<byte> record, int minimum, ushort version)
    {
        if (record.Length < minimum)
        {
            throw new InvalidDataException($"USN V{version} record is truncated.");
        }
    }
}
