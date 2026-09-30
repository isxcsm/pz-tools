using System.Text.Json;

namespace PzTools.Projections;

public enum LogActivityKind
{
    Backup,
    Restore,
    ArchiveExport,
    ArchiveImport,
    ArchiveInspect,
    Archive,
    StateCheck,
    BackupSchedule,
    Maintenance,
    Other,
    CharacterRecovery,
    Profile,
}

/// <summary>Derives a user-facing activity from durable event fields, including older rows.</summary>
public sealed record LogActivityContext(
    LogActivityKind Kind, long? Revision = null, long? ChangeCount = null)
{
    public static LogActivityContext From(LogEntryView entry)
    {
        string? operation = null;
        long? revision = null;
        long? changeCount = null;
        if (!string.IsNullOrWhiteSpace(entry.PayloadJson))
        {
            try
            {
                using var document = JsonDocument.Parse(entry.PayloadJson);
                if (document.RootElement.ValueKind == JsonValueKind.Object)
                {
                    var root = document.RootElement;
                    operation = ReadString(root, "operation");
                    revision = ReadNumber(root, "revision");
                    changeCount = ReadNumber(root, "count");
                }
            }
            catch (JsonException) { }
        }

        var kind = entry.Component switch
        {
            "backup-worker" or "backup-runner" => LogActivityKind.Backup,
            "restore-worker" => LogActivityKind.Restore,
            "character-recovery" => LogActivityKind.CharacterRecovery,
            "profiler" => LogActivityKind.Profile,
            "archive-worker" => ArchiveKind(operation, entry.SourceId),
            "state-runner" or "state-collector" or "state-reactor" or "state-scheduler" =>
                LogActivityKind.StateCheck,
            "backup-scheduler" => LogActivityKind.BackupSchedule,
            "maintenance-worker" or "maintenance-runner" => LogActivityKind.Maintenance,
            var lane when lane.StartsWith("maintenance-lane-", StringComparison.Ordinal) =>
                LogActivityKind.Maintenance,
            _ => LogActivityKind.Other,
        };
        return new LogActivityContext(kind, revision, changeCount);
    }

    private static LogActivityKind ArchiveKind(string? operation, string sourceId)
    {
        if (operation is "export" or "export-live"
            || sourceId.StartsWith("archive-export", StringComparison.OrdinalIgnoreCase))
            return LogActivityKind.ArchiveExport;
        if (operation == "import"
            || sourceId.StartsWith("archive-import", StringComparison.OrdinalIgnoreCase))
            return LogActivityKind.ArchiveImport;
        if (operation == "inspect"
            || sourceId.StartsWith("archive-inspect", StringComparison.OrdinalIgnoreCase))
            return LogActivityKind.ArchiveInspect;
        return LogActivityKind.Archive;
    }

    private static string? ReadString(JsonElement root, string name)
    {
        foreach (var property in root.EnumerateObject())
            if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase)
                && property.Value.ValueKind == JsonValueKind.String)
                return property.Value.GetString();
        return null;
    }

    private static long? ReadNumber(JsonElement root, string name)
    {
        foreach (var property in root.EnumerateObject())
        {
            if (!property.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) continue;
            if (property.Value.ValueKind == JsonValueKind.Number
                && property.Value.TryGetInt64(out var number) && number >= 0)
                return number;
        }
        return null;
    }
}
