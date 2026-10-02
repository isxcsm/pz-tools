using PzTools.Projections;

namespace PzTools.App.Core;

public sealed record OperationProgressDisplay(bool IsVisible, bool IsIndeterminate)
{
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
