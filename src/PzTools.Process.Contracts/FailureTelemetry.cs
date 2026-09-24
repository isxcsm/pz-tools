using System.Text.Json;

namespace PzTools.Process.Contracts;

/// <summary>작업 실패를 로그 상세 화면에서 읽을 수 있는 작은 구조화 레코드로 만듭니다.</summary>
public static class FailureTelemetry
{
    private const int MaximumTextLength = 512;

    public static string FromException(
        string failureCode,
        Exception exception,
        string? status = null,
        string? phase = null,
        string? path = null,
        string? reason = null,
        string? operation = null,
        string? saveId = null,
        string? messageOverride = null,
        string? redactPathPrefix = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(failureCode);
        ArgumentNullException.ThrowIfNull(exception);

        var fields = new Dictionary<string, object>
        {
            ["failureCode"] = failureCode,
            ["exceptionType"] = exception.GetType().Name,
            ["message"] = Limit(messageOverride ?? exception.Message, redactPathPrefix),
            ["hResult"] = $"0x{exception.HResult:X8}",
        };
        Add(fields, "status", status, redactPathPrefix);
        Add(fields, "phase", phase, redactPathPrefix);
        Add(fields, "path", path, redactPathPrefix);
        Add(fields, "reason", reason, redactPathPrefix);
        Add(fields, "operation", operation, redactPathPrefix);
        Add(fields, "saveId", saveId, redactPathPrefix);
        if (exception.InnerException is { } inner)
        {
            fields["innerExceptionType"] = inner.GetType().Name;
            fields["innerMessage"] = Limit(inner.Message, redactPathPrefix);
            fields["innerHResult"] = $"0x{inner.HResult:X8}";
        }

        return JsonSerializer.Serialize(fields);
    }

    private static void Add(Dictionary<string, object> fields, string key, string? value,
        string? redactPathPrefix)
    {
        if (!string.IsNullOrWhiteSpace(value)) fields[key] = Limit(value, redactPathPrefix);
    }

    private static string Limit(string value, string? redactPathPrefix)
    {
        var safeValue = string.IsNullOrWhiteSpace(redactPathPrefix) ? value
            : value.Replace(redactPathPrefix, "<save>", StringComparison.OrdinalIgnoreCase);
        var singleLine = safeValue.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return singleLine.Length <= MaximumTextLength
            ? singleLine : singleLine[..MaximumTextLength] + "…";
    }
}
