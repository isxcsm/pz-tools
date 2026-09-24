using System.Text.Json;

namespace PzTools.Projections;

public sealed record LogDiagnostics(
    string? FailureCode,
    string? ExceptionType,
    string? Phase,
    string? Path,
    string? Reason,
    string? Message,
    string? InnerExceptionType,
    string? InnerMessage,
    string? SaveId,
    string? Operation,
    string? FailureOrigin,
    string? Outcome,
    string? FailedFileCount,
    string? FailedFiles)
{
    // Outcomes also describe successful/skipped work; they must not require a
    // failure diagnostics card in order to choose the correct log message.
    public static string? ReadOutcome(string? payloadJson)
    {
        if (string.IsNullOrWhiteSpace(payloadJson)) return null;
        try
        {
            using var document = JsonDocument.Parse(payloadJson);
            return document.RootElement.ValueKind == JsonValueKind.Object
                ? ReadOutcome(document.RootElement) : null;
        }
        catch (JsonException) { return null; }
    }

    internal static string? ReadOutcome(JsonElement root)
    {
        var outcome = Get(root, "outcome");
        // Legacy backup events used numeric RunStatus, not ProcessOutcome.
        var value = outcome is not null ? outcome switch
        {
            "0" => "Succeeded",
            "1" => "NoChange",
            "2" => "Skipped",
            "3" => "Busy",
            "4" => "Degraded",
            "5" => "Failed",
            "6" => "Cancelled",
            _ => outcome,
        } : Get(root, "status") switch
        {
            "0" => "Running",
            "1" => "Succeeded",
            "2" => "Failed",
            "3" => "Cancelled",
            "4" => "Abandoned",
            var status => status,
        };
        return Enum.TryParse<PzTools.Process.Contracts.ProcessOutcome>(value, true, out var known)
            && Enum.IsDefined(known) ? known.ToString() : value;
    }

    public static LogDiagnostics? Parse(string? payloadJson)
    {
        if (string.IsNullOrWhiteSpace(payloadJson)) return null;
        try
        {
            using var document = JsonDocument.Parse(payloadJson);
            if (document.RootElement.ValueKind != JsonValueKind.Object) return null;
            var root = document.RootElement;
            var code = Get(root, "failureCode") ?? Get(root, "code");
            var exceptionType = Get(root, "exceptionType");
            var outcome = ReadOutcome(root);
            if (code is null && exceptionType is null
                && outcome is not ("Failed" or "Degraded" or "Cancelled" or "Abandoned")) return null;
            return new LogDiagnostics(
                code, exceptionType,
                Get(root, "phase"), Get(root, "path"), Get(root, "reason"),
                Get(root, "message"), Get(root, "innerExceptionType"),
                Get(root, "innerMessage"), Get(root, "saveId"),
                Get(root, "operation"), Get(root, "failureOrigin"), outcome,
                Get(root, "failedFileCount"), GetFileNames(root));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Get(JsonElement root, string name)
    {
        foreach (var property in root.EnumerateObject())
        {
            if (!property.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) continue;
            return property.Value.ValueKind switch
            {
                JsonValueKind.String => property.Value.GetString(),
                JsonValueKind.Number or JsonValueKind.True or JsonValueKind.False =>
                    property.Value.ToString(),
                _ => null,
            };
        }
        return null;
    }

    private static string? GetFileNames(JsonElement root)
    {
        foreach (var property in root.EnumerateObject())
        {
            if (!property.Name.Equals("failedFiles", StringComparison.OrdinalIgnoreCase)
                || property.Value.ValueKind != JsonValueKind.Array) continue;
            return string.Join(", ", property.Value.EnumerateArray()
                .Where(item => item.ValueKind == JsonValueKind.String)
                .Take(8)
                .Select(item => item.GetString())
                .Where(item => !string.IsNullOrWhiteSpace(item)));
        }
        return null;
    }
}
