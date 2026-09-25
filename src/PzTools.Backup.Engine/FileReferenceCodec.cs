using PzTools.Backup.Core.Capture;

namespace PzTools.Backup.Engine;

internal static class FileReferenceCodec
{
    public static UInt128 Decode(byte[] value)
    {
        ArgumentNullException.ThrowIfNull(value);
        return FileIdentityCodec.FileReference(value);
    }
}
