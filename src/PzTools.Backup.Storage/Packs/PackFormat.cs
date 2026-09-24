using System.Buffers.Binary;
using PzTools.Backup.Core.Configuration;

namespace PzTools.Backup.Storage.Packs;

internal static class PackFormat
{
    public const int Version = 1;
    public const int HeaderSize = 36;
    public const int ObjectHeaderSize = 80;
    public const int IndexHeaderSize = 12;
    public const int IndexEntrySize = 24;
    public const int IndexChecksumSize = 32;
    public const int TrailerSize = 16;

    public static ReadOnlySpan<byte> HeaderMagic => "PZPACK01"u8;
    public static ReadOnlySpan<byte> ObjectMagic => "POBJ"u8;
    public static ReadOnlySpan<byte> IndexMagic => "PZINDEX1"u8;
    public static ReadOnlySpan<byte> TrailerMagic => "PZEND001"u8;

    public static byte Encode(ChecksumAlgorithm algorithm) => algorithm switch
    {
        ChecksumAlgorithm.None => 0,
        ChecksumAlgorithm.XxHash64 => 1,
        ChecksumAlgorithm.Sha256 => 2,
        _ => throw new ArgumentException(
            $"Checksum algorithm {algorithm} must be resolved before writing a pack.",
            nameof(algorithm)),
    };

    public static ChecksumAlgorithm DecodeChecksum(byte value) => value switch
    {
        0 => ChecksumAlgorithm.None,
        1 => ChecksumAlgorithm.XxHash64,
        2 => ChecksumAlgorithm.Sha256,
        _ => throw new PackFormatException($"Unknown checksum algorithm id {value}."),
    };

    public static byte Encode(CompressionAlgorithm algorithm) => algorithm switch
    {
        CompressionAlgorithm.None => 0,
        CompressionAlgorithm.Brotli => 1,
        _ => throw new ArgumentException(
            $"Compression algorithm {algorithm} must be resolved before writing a pack.",
            nameof(algorithm)),
    };

    public static CompressionAlgorithm DecodeCompression(byte value) => value switch
    {
        0 => CompressionAlgorithm.None,
        1 => CompressionAlgorithm.Brotli,
        _ => throw new PackFormatException($"Unknown compression algorithm id {value}."),
    };

    public static void WriteInt32(Span<byte> destination, int value) =>
        BinaryPrimitives.WriteInt32LittleEndian(destination, value);

    public static void WriteInt64(Span<byte> destination, long value) =>
        BinaryPrimitives.WriteInt64LittleEndian(destination, value);

    public static int ReadInt32(ReadOnlySpan<byte> source) =>
        BinaryPrimitives.ReadInt32LittleEndian(source);

    public static long ReadInt64(ReadOnlySpan<byte> source) =>
        BinaryPrimitives.ReadInt64LittleEndian(source);
}
