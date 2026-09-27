using System.Diagnostics;
using System.Text.Json;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Engine;

// Sample before serialization; events still use the backup session's bounded batch queue.
internal sealed class BackupPlanningProgress(TelemetryRunSession telemetry, int intervalMs, CancellationToken token)
{
    private long lastReport;
    private string? lastPhase;

    public async ValueTask ReportAsync(string phase, long items, long bytes = 0, long? totalBytes = null,
        long? totalItems = null)
    {
        var now = Stopwatch.GetTimestamp();
        if (lastPhase == phase && Stopwatch.GetElapsedTime(lastReport, now).TotalMilliseconds < intervalMs)
            return;
        lastReport = now;
        lastPhase = phase;
        await telemetry.EmitAsync(new TelemetryEvent(TelemetryEventScope.Phase, "progress.snapshot",
            JsonSerializer.Serialize(new { phase, completedItems = items, totalItems,
                completedBytes = bytes, totalBytes })), token);
    }
}
