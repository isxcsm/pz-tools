namespace PzTools.Backup.Core;

public sealed class FileSystemScanner(TimeProvider? timeProvider = null)
{
    private readonly TimeProvider _timeProvider = timeProvider ?? TimeProvider.System;

    public FileCatalog Scan(string sourceRoot, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourceRoot);

        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(sourceRoot));
        if (!Directory.Exists(root))
        {
            throw new DirectoryNotFoundException($"Backup source directory was not found: '{root}'.");
        }

        var rootAttributes = File.GetAttributes(root);
        if ((rootAttributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new NotSupportedException("A reparse point cannot be used as a backup source root.");
        }

        var enumerationOptions = new EnumerationOptions
        {
            AttributesToSkip = FileAttributes.ReparsePoint,
            IgnoreInaccessible = false,
            RecurseSubdirectories = true,
            ReturnSpecialDirectories = false,
        };

        var entries = new List<CatalogEntry>();

        foreach (var path in Directory.EnumerateFileSystemEntries(root, "*", enumerationOptions))
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                var attributes = File.GetAttributes(path);
                var kind = (attributes & FileAttributes.Directory) != 0
                    ? CatalogEntryKind.Directory
                    : CatalogEntryKind.File;
                var size = kind == CatalogEntryKind.File ? new FileInfo(path).Length : 0L;
                var lastWriteTimeUtc = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero);

                entries.Add(new CatalogEntry(
                    BackupPath.GetRelative(root, path),
                    kind,
                    size,
                    lastWriteTimeUtc,
                    attributes));
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                throw new SourceScanException(path, exception);
            }
        }

        entries.Sort(static (left, right) =>
            StringComparer.OrdinalIgnoreCase.Compare(left.RelativePath, right.RelativePath));

        return FileCatalog.Create(root, _timeProvider.GetUtcNow(), entries);
    }
}

