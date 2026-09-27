using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Packs;

public sealed record PackObjectDescriptor(
    Guid ObjectId,
    long RecordOffset,
    long PayloadOffset,
    long OriginalLength,
    long StoredLength,
    ChecksumAlgorithm ChecksumAlgorithm,
    byte[] Checksum,
    CompressionAlgorithm CompressionAlgorithm,
    int Flags);

public sealed record CommittedPack(
    Guid PackId,
    long RunIndex,
    string FullPath,
    string RelativePath,
    long ByteLength,
    int ObjectCount);

public sealed record PackValidationResult(Guid PackId, long RunIndex, int ObjectCount);

public sealed class PackFormatException : IOException
{
    public PackFormatException(string message)
        : base(message)
    {
    }

    public PackFormatException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
