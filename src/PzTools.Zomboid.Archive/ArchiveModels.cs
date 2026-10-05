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
    DateTimeOffset ExportedUtc,
    // The exporting PC's time zone (a Windows ID): its entries' times are that PC's clock time, which a zip keeps
    // without an offset. Absent from archives made before entries carried the save's own times.
    string? EntryTimeZone = null);

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

// No compression-ratio limit: ordinary saves have files, such as map_visited.bin, that compress far beyond
// any ratio that would catch a ZIP bomb. Each entry is bounded by its size limit and its declared length, and
// the whole import by the free-space check.
public sealed record ArchiveSafetyOptions(
    int MaximumEntries = 1_000_000,
    long MaximumSingleFileBytes = 64L * 1024 * 1024 * 1024,
    long MinimumFreeSpaceReserveBytes = 5L * 1024 * 1024 * 1024,
    int MinimumFreeSpaceReservePercent = 10)
{
    public void Validate()
    {
        if (MaximumEntries <= 0 || MaximumSingleFileBytes <= 0
            || MinimumFreeSpaceReserveBytes < 0
            || MinimumFreeSpaceReservePercent is < 0 or > 100)
            throw new ArgumentOutOfRangeException(nameof(ArchiveSafetyOptions));
    }
}
