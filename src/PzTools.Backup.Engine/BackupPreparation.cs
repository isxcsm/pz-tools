using System.Text.Json;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Engine;

/// <summary>A preparation declined before any capture; this is not a failed integrity check.</summary>
public sealed class BackupPreparationDeferredException(string reason) : OperationCanceledException(reason) { }

public sealed record BackupPreparationResult(string Outcome, string? Detail = null);

public delegate Task<BackupPreparationResult> BackupSourcePreparation(
    string sourcePath, CancellationToken cancellationToken);

internal static class BackupPreparation
{
    public static async Task RunAsync(BackupSourcePreparation? prepare, string sourcePath,
        TelemetryRunSession telemetry, CancellationToken cancellationToken)
    {
        if (prepare is null) return;
        await telemetry.EmitAsync(new TelemetryEvent(TelemetryEventScope.Phase,
            "source.prepare.started"), cancellationToken);
        var result = await prepare(sourcePath, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        await telemetry.EmitAsync(new TelemetryEvent(TelemetryEventScope.Phase,
            "source.prepare.completed", JsonSerializer.Serialize(new
            {
                outcome = result.Outcome, detail = result.Detail,
            })), cancellationToken);
    }
}
