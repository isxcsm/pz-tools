namespace PzTools.Backup.Core.Capture;

public sealed class UnstableFileException : IOException
{
    public UnstableFileException(string path, string reason, Exception? innerException = null)
        : base($"capture-unstable: File '{path}' could not be captured stably: {reason}.", innerException)
    {
        Path = path;
        Reason = reason;
    }

    public string Path { get; }

    public string Reason { get; }
}
