namespace PzTools.Backup.Storage.Telemetry;

public enum TelemetryEventScope
{
    Run,
    Phase,
    Raw,
}

public sealed record TelemetryEvent(
    TelemetryEventScope Scope,
    string Name,
    string? PayloadJson = null);

public sealed record StoredTelemetryEvent(
    long RunIndex,
    long Sequence,
    int EventVersion,
    TelemetryEventScope Scope,
    string Name,
    DateTimeOffset TimestampUtc,
    long ElapsedTicks,
    string? PayloadJson);

public sealed record TelemetryRunRecord(
    long RunIndex,
    long SourceId,
    string Status,
    DateTimeOffset StartedUtc,
    DateTimeOffset? CompletedUtc,
    string? FailureCode);

public sealed record BackupTelemetryInfo(
    int FormatVersion,
    int SchemaVersion,
    Guid TelemetryInstanceId,
    string Producer,
    DateTimeOffset CreatedUtc);

public sealed record BackupTelemetryEvent(
    long EventId,
    long RunIndex,
    long Sequence,
    int EventVersion,
    TelemetryEventScope Scope,
    string Name,
    DateTimeOffset TimestampUtc,
    long ElapsedTicks,
    string? PayloadJson);
