using System.Text.Json;

namespace PzTools.Process.Contracts;

public sealed class ProcessResultValidationException(string code, string message, Exception? inner = null)
    : Exception(message, inner)
{
    public string Code { get; } = code;
}

/// <summary>The same identity and exit-status contract applies at every process boundary.</summary>
public static class ProcessResultValidator
{
    public static ProcessResultEnvelope<T> Read<T>(string output, string expectedComponent,
        long expectedRunIndex, int? exitCode, string? standardError = null)
    {
        ProcessResultEnvelope<T> envelope;
        try
        {
            if (string.IsNullOrWhiteSpace(output))
                throw new InvalidDataException("The child process did not return a result.");
            try { envelope = ProcessResultJson.Deserialize<T>(output); }
            catch (JsonException)
            {
                var last = output.Split('\n').Last(line => !string.IsNullOrWhiteSpace(line));
                envelope = ProcessResultJson.Deserialize<T>(last);
            }
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException)
        {
            throw new ProcessResultValidationException("invalid-process-result",
                DiagnosticMessage(exception.Message, standardError), exception);
        }
        if (!StringComparer.Ordinal.Equals(envelope.Component, expectedComponent)
            || envelope.RunIndex != expectedRunIndex
            || !(exitCode == ProcessExitCodes.FromOutcome(envelope.Outcome)
                || (envelope.Outcome == ProcessOutcome.Failed && exitCode == ProcessExitCodes.InvalidArguments)))
            throw new ProcessResultValidationException("process-contract-mismatch",
                DiagnosticMessage($"Expected {expectedComponent}/{expectedRunIndex}; received "
                    + $"{envelope.Component}/{envelope.RunIndex}, outcome={envelope.Outcome}, exit={exitCode}."
                    + (envelope.Error is { } error ? $" Child error: {error.Code}: {error.Message}" : ""), standardError));
        return envelope;
    }

    public static string DiagnosticMessage(string message, string? standardError) =>
        string.IsNullOrWhiteSpace(standardError) ? message
            : message + "\n" + (standardError.Length > 8192 ? standardError[^8192..] : standardError).Trim();
}
