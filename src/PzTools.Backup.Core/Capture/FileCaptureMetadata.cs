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

/// <summary>A reader with no state of its own, safe to call from several capture readers at once.</summary>
public interface IConcurrentFileMetadataReader : IFileMetadataReader;
