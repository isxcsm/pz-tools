namespace PzTools.Backup.ChangeTracking.Windows;

[Flags]
public enum UsnReason : uint
{
    DataOverwrite = 0x00000001,
    DataExtend = 0x00000002,
    DataTruncation = 0x00000004,
    NamedDataOverwrite = 0x00000010,
    NamedDataExtend = 0x00000020,
    NamedDataTruncation = 0x00000040,
    FileCreate = 0x00000100,
    FileDelete = 0x00000200,
    ExtendedAttributeChange = 0x00000400,
    SecurityChange = 0x00000800,
    RenameOldName = 0x00001000,
    RenameNewName = 0x00002000,
    IndexableChange = 0x00004000,
    BasicInfoChange = 0x00008000,
    HardLinkChange = 0x00010000,
    CompressionChange = 0x00020000,
    EncryptionChange = 0x00040000,
    ObjectIdChange = 0x00080000,
    ReparsePointChange = 0x00100000,
    StreamChange = 0x00200000,
    TransactedChange = 0x00400000,
    IntegrityChange = 0x00800000,
    Close = 0x80000000,
}

public sealed record UsnRecord(
    ushort MajorVersion,
    ushort MinorVersion,
    UInt128 FileReferenceNumber,
    UInt128 ParentFileReferenceNumber,
    long Usn,
    DateTimeOffset TimestampUtc,
    UsnReason Reason,
    uint SourceInfo,
    FileAttributes FileAttributes,
    string FileName);

public sealed record UsnReadBuffer(long NextUsn, IReadOnlyList<UsnRecord> Records);
