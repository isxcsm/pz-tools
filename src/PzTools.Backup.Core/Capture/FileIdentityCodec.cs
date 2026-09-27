using System.Buffers.Binary;

namespace PzTools.Backup.Core.Capture;

/// <summary>Format 2 identity: 8-byte volume plus 16-byte file ID, big endian.</summary>
public static class FileIdentityCodec
{
    public const int EncodedLength = 24;

    public static byte[] Encode(string identity)
    {
        ArgumentNullException.ThrowIfNull(identity);
        if (identity.Length != 49 || identity[16] != ':')
            throw new InvalidDataException("Expected a Windows volume:file identity.");
        try { return Convert.FromHexString(string.Concat(identity.AsSpan(0, 16), identity.AsSpan(17, 32))); }
        catch (FormatException exception)
        { throw new InvalidDataException("Invalid hexadecimal file identity.", exception); }
    }

    public static UInt128 FileReference(ReadOnlySpan<byte> identity)
    {
        if (identity.Length != EncodedLength)
            throw new InvalidDataException("Expected a 24-byte file identity.");
        return BinaryPrimitives.ReadUInt128BigEndian(identity[8..]);
    }
}
