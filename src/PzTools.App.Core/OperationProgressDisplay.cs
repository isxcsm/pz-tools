using PzTools.Projections;

namespace PzTools.App.Core;

public sealed record OperationProgressDisplay(bool IsVisible, bool IsIndeterminate)
{
    public static bool UsesBytes(OperationView operation) => operation.TotalBytes is > 0
        && operation.Phase is "copy" or "copy.retry" or "capture" or "hash" or "restore"
            or "deduplication" or "archive.restore" or "archive.snapshot" or "archive.compress" or "import";

    public static OperationProgressDisplay From(OperationView? operation, bool telemetryFaulted = false)
    {
        // An end state wins over the last telemetry's total and progress.
        if (operation?.Status != OperationStatus.Running)
            return new(false, false);

        var determinate = (!telemetryFaulted || operation.Kind == "delete-save")
            && operation.TelemetryHealth == TelemetryHealth.Healthy
            && (UsesBytes(operation) || operation.TotalItems is > 0);
        return new(true, !determinate);
    }
}
