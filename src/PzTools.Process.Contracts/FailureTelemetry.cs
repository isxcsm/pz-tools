using System.Text.Json;

namespace PzTools.Process.Contracts;

/// <summary>Turns an operation failure into a small structured record the log details can read.</summary>
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
        // A Win32Exception says why in its own number (5 is access denied); its HResult is only the generic E_FAIL.
        if (exception is System.ComponentModel.Win32Exception win32) fields["nativeErrorCode"] = win32.NativeErrorCode;
        Add(fields, "status", status, redactPathPrefix);
        Add(fields, "phase", phase, redactPathPrefix);
        Add(fields, "path", path, redactPathPrefix);
        Add(fields, "reason", reason, redactPathPrefix);
        Add(fields, "operation", operation, redactPathPrefix);
        Add(fields, "saveId", saveId, redactPathPrefix);
        if (exception is IFailureDiagnostics { Diagnostics: { Length: > 0 } diagnostics })
            fields["diagnostics"] = Limit(diagnostics, redactPathPrefix, 6144);
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

    private static string Limit(string value, string? redactPathPrefix, int maximumLength = MaximumTextLength)
    {
        var safeValue = string.IsNullOrWhiteSpace(redactPathPrefix) ? value
            : value.Replace(redactPathPrefix, "<save>", StringComparison.OrdinalIgnoreCase);
        var singleLine = safeValue.Replace('\r', ' ').Replace('\n', ' ').Trim();
        return singleLine.Length <= maximumLength
            ? singleLine : singleLine[..maximumLength] + "…";
    }
}
