namespace PzTools.Backup.Core;

public sealed class SourceScanException : IOException
{
    public SourceScanException(string path, Exception innerException)
        : base($"The source changed or became unavailable while scanning '{path}'.", innerException)
    {
        Path = path;
    }

    public string Path { get; }
}

