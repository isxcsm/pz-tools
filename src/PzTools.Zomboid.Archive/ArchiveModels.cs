namespace PzTools.Zomboid.Archive;

public sealed record ZomboidArchiveManifest(
    string Format,
    int Version,
    string SaveId,
    string Mode,
    string SaveName,
    DateTimeOffset? LastPlayedUtc,
    long SourceId,
    long Revision,
    DateTimeOffset ExportedUtc);

public sealed record ArchiveInspection(
    ZomboidArchiveManifest Manifest,
    byte[]? Thumbnail,
    long ArchiveBytes,
    string? CharacterName = null,
    double? HoursSurvived = null);

public sealed record ArchiveExportResult(
    string ArchivePath,
    long SourceId,
    long Revision,
    int Files,
    long ArchiveBytes);

public sealed record ArchiveImportResult(
    string DestinationPath,
    string Mode,
    string SaveName,
    int Files);

public sealed record ArchiveProgress(
    string Phase,
    long CompletedItems,
    long TotalItems,
    long CompletedBytes,
    long TotalBytes,
    string? RelativePath);

public sealed record ArchiveSafetyOptions(
    int MaximumEntries = 1_000_000,
    long MaximumSingleFileBytes = 64L * 1024 * 1024 * 1024,
    int MaximumCompressionRatio = int.MaxValue,
    long CompressionRatioMinimumBytes = long.MaxValue,
    long MinimumFreeSpaceReserveBytes = 5L * 1024 * 1024 * 1024,
    int MinimumFreeSpaceReservePercent = 10)
{
    public void Validate()
    {
        if (MaximumEntries <= 0 || MaximumSingleFileBytes <= 0
            || MaximumCompressionRatio <= 0 || CompressionRatioMinimumBytes < 0
            || MinimumFreeSpaceReserveBytes < 0
            || MinimumFreeSpaceReservePercent is < 0 or > 100)
            throw new ArgumentOutOfRangeException(nameof(ArchiveSafetyOptions));
    }
}
