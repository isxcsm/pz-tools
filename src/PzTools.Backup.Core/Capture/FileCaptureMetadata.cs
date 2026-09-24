using Microsoft.Win32.SafeHandles;

namespace PzTools.Backup.Core.Capture;

public sealed record FileCaptureMetadata(
    string Identity,
    long Length,
    DateTimeOffset ModifiedUtc,
    DateTimeOffset ChangedUtc,
    FileAttributes Attributes,
    long? Usn);

public interface IFileMetadataReader
{
    FileCaptureMetadata ReadPath(string path);

    FileCaptureMetadata ReadHandle(SafeFileHandle handle);
}
