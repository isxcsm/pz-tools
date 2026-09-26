using System.Text.Json;
using PzTools.Process.Contracts.GameRuntime;
using System.Text.Json.Serialization;

namespace PzTools.Process.Contracts;

public static class ProcessContractVersions
{
    public const int ResultEnvelope = 1;
}

[JsonConverter(typeof(JsonStringEnumConverter<ProcessOutcome>))]
public enum ProcessOutcome
{
    Succeeded,
    NoChange,
    Skipped,
    Busy,
    Degraded,
    Failed,
    Cancelled,
}

public sealed record ProcessError(string Code, string Message);

public sealed record ProcessResultEnvelope<T>(
    [property: JsonRequired] int Version,
    [property: JsonRequired] string Component,
    [property: JsonRequired] long RunIndex,
    [property: JsonRequired] ProcessOutcome Outcome,
    [property: JsonRequired] DateTimeOffset StartedUtc,
    [property: JsonRequired] DateTimeOffset CompletedUtc,
    T? Result,
    ProcessError? Error)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public ScheduleDisposition ScheduleDisposition { get; init; }
    public static ProcessResultEnvelope<T> Success(
        string component,
        long runIndex,
        ProcessOutcome outcome,
        DateTimeOffset startedUtc,
        T? result = default) =>
        new(
            ProcessContractVersions.ResultEnvelope,
            component,
            runIndex,
            outcome,
            startedUtc,
            DateTimeOffset.UtcNow,
            result,
            Error: null);

    public static ProcessResultEnvelope<T> Failure(
        string component,
        long runIndex,
        ProcessOutcome outcome,
        DateTimeOffset startedUtc,
        string code,
        string message) =>
        new(
            ProcessContractVersions.ResultEnvelope,
            component,
            runIndex,
            outcome,
            startedUtc,
            DateTimeOffset.UtcNow,
            Result: default,
            new ProcessError(code, message));
}

public static class ProcessResultJson
{
    public static JsonSerializerOptions Options { get; } = CreateOptions();

    public static string Serialize<T>(ProcessResultEnvelope<T> envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        return JsonSerializer.Serialize(envelope, Options);
    }

    public static ProcessResultEnvelope<T> Deserialize<T>(string json)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(json);
        var envelope = JsonSerializer.Deserialize<ProcessResultEnvelope<T>>(json, Options)
            ?? throw new InvalidDataException("The process result is empty.");
        if (envelope.Version != ProcessContractVersions.ResultEnvelope)
        {
            throw new InvalidDataException(
                $"Unsupported process result version {envelope.Version}.");
        }

        if (string.IsNullOrWhiteSpace(envelope.Component) || envelope.RunIndex <= 0)
        {
            throw new InvalidDataException("The process result identity is invalid.");
        }

        if (!Enum.IsDefined(envelope.ScheduleDisposition) || !Enum.IsDefined(envelope.Outcome)
            || envelope.CompletedUtc < envelope.StartedUtc)
        {
            throw new InvalidDataException("The process result state is invalid.");
        }

        if (envelope.Outcome is ProcessOutcome.Failed or ProcessOutcome.Cancelled
            && (envelope.Error is null || string.IsNullOrWhiteSpace(envelope.Error.Code)
                || string.IsNullOrWhiteSpace(envelope.Error.Message)))
        {
            throw new InvalidDataException("A failed process result requires an error.");
        }
        if (envelope.Outcome is not (ProcessOutcome.Failed or ProcessOutcome.Cancelled)
            && envelope.Error is not null)
        {
            throw new InvalidDataException("A successful process result cannot contain an error.");
        }

        return envelope;
    }

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }
}

public static class ProcessExitCodes
{
    public const int Success = 0;
    public const int Failure = 1;
    public const int Cancelled = 2;
    public const int Degraded = 3;
    public const int Busy = 75;
    public const int InvalidArguments = 64;

    public static int FromOutcome(ProcessOutcome outcome) => outcome switch
    {
        ProcessOutcome.Succeeded or ProcessOutcome.NoChange or ProcessOutcome.Skipped => Success,
        ProcessOutcome.Degraded => Degraded,
        ProcessOutcome.Busy => Busy,
        ProcessOutcome.Cancelled => Cancelled,
        ProcessOutcome.Failed => Failure,
        _ => throw new ArgumentOutOfRangeException(nameof(outcome)),
    };
}
