using System.Globalization;
using System.Text;

namespace PzTools.Backup.Engine;

internal static class FileReferenceCodec
{
    public static UInt128 Decode(byte[] value)
    {
        ArgumentNullException.ThrowIfNull(value);
        var text = Encoding.UTF8.GetString(value);
        var separator = text.LastIndexOf(':');
        var reference = separator >= 0 ? text[(separator + 1)..] : text;
        return UInt128.Parse(reference, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);
    }
}
