using PzTools.Projections;

namespace PzTools.App.Core;

public sealed record OperationProgressDisplay(bool IsVisible, bool IsIndeterminate)
{
    public static OperationView? SelectForeground(OperationsView view, OperationView? local, long exportBaselineRunIndex)
    {
        return SelectLocal(view.Operations.Where(operation =>
            operation.Kind is "delete-save" or "character-recovery" or "export" or "import"
            || operation.Kind.Contains("restore", StringComparison.OrdinalIgnoreCase)), local, exportBaselineRunIndex);
    }

    public static OperationView? SelectExport(
        OperationsView view, OperationView? local, long baselineRunIndex)
    {
        return SelectLocal(view.Operations.Where(operation =>
            operation.Kind.Contains("export", StringComparison.OrdinalIgnoreCase)
            || operation.Kind.Contains("import", StringComparison.OrdinalIgnoreCase)), local, baselineRunIndex);
    }

    public static OperationView? SelectLocal(IEnumerable<OperationView> operations, OperationView? local, long baselineRunIndex)
    {
        var ordered = operations.OrderByDescending(operation => operation.Status == OperationStatus.Running)
            .ThenByDescending(operation => operation.RunIndex).ToArray();
        var latest = ordered.FirstOrDefault();
        if (local is null) return latest;
        if (local.Status != OperationStatus.Running)
            return ordered.FirstOrDefault(operation => operation.Status == OperationStatus.Running
                && operation.OperationId != local.OperationId
                && operation.RunIndex > Math.Max(baselineRunIndex, local.RunIndex)) ?? local;
        return ordered.FirstOrDefault(operation => operation.OperationId == local.OperationId
            && (operation.Kind == local.Kind || local.Kind == "backup"
                && operation.Kind.Contains("backup", StringComparison.OrdinalIgnoreCase))
            && operation.RunIndex > baselineRunIndex) ?? local;
    }

    public static bool UsesBytes(OperationView operation) => operation.TotalBytes is > 0
        && operation.Phase is "copy" or "copy.retry" or "capture" or "hash" or "restore"
            or "deduplication" or "archive.restore" or "archive.snapshot" or "archive.compress" or "import";

    public static OperationProgressDisplay From(OperationView? operation, bool telemetryFaulted = false)
    {
        // 종료 상태가 마지막 telemetry의 총량/진행률보다 우선합니다.
        if (operation?.Status != OperationStatus.Running)
            return new(false, false);

        var determinate = (!telemetryFaulted || operation.Kind == "delete-save")
            && operation.TelemetryHealth == TelemetryHealth.Healthy
            && (UsesBytes(operation) || operation.TotalItems is > 0);
        return new(true, !determinate);
    }
}
