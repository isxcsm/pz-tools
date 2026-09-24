using System.Text.Json;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Tests;

public sealed class ProcessContractsTests
{
    [Theory]
    [InlineData(ProcessOutcome.Succeeded)]
    [InlineData(ProcessOutcome.NoChange)]
    [InlineData(ProcessOutcome.Skipped)]
    [InlineData(ProcessOutcome.Busy)]
    [InlineData(ProcessOutcome.Degraded)]
    public void ResultEnvelope_RoundTrips(ProcessOutcome outcome)
    {
        var started = DateTimeOffset.UtcNow;
        var value = ProcessResultEnvelope<TestPayload>.Success(
            "test-component",
            7,
            outcome,
            started,
            new TestPayload("ok"));

        var result = ProcessResultJson.Deserialize<TestPayload>(
            ProcessResultJson.Serialize(value));

        Assert.Equal(value, result);
    }

    [Fact]
    public void ResultEnvelope_RejectsUnknownVersion()
    {
        var json = JsonSerializer.Serialize(new
        {
            version = 999,
            component = "test",
            runIndex = 1,
            outcome = "Succeeded",
            startedUtc = DateTimeOffset.UtcNow,
            completedUtc = DateTimeOffset.UtcNow,
        });

        Assert.Throws<InvalidDataException>(
            () => ProcessResultJson.Deserialize<TestPayload>(json));
    }

    [Fact]
    public void ResultEnvelope_RejectsErrorOnSuccessfulOutcome()
    {
        var now = DateTimeOffset.UtcNow;
        var invalid = new ProcessResultEnvelope<TestPayload>(
            ProcessContractVersions.ResultEnvelope,
            "test",
            1,
            ProcessOutcome.Succeeded,
            now,
            now,
            new TestPayload("ok"),
            new ProcessError("impossible", "success cannot also be an error"));

        Assert.Throws<InvalidDataException>(() =>
            ProcessResultJson.Deserialize<TestPayload>(ProcessResultJson.Serialize(invalid)));
    }

    [Fact]
    public void FailureTelemetry_PreservesBoundedDiagnosticChain()
    {
        var error = new IOException("C:\\private\\save file changed\nwhile reading",
            new UnauthorizedAccessException("C:\\private\\save access denied"));
        using var json = JsonDocument.Parse(FailureTelemetry.FromException(
            "capture-failed", error, phase: "capture", path: "map_meta.bin",
            redactPathPrefix: "C:\\private\\save"));
        var root = json.RootElement;

        Assert.Equal("capture-failed", root.GetProperty("failureCode").GetString());
        Assert.Equal("capture", root.GetProperty("phase").GetString());
        Assert.Equal("map_meta.bin", root.GetProperty("path").GetString());
        Assert.Equal("IOException", root.GetProperty("exceptionType").GetString());
        Assert.Equal("<save> file changed while reading", root.GetProperty("message").GetString());
        Assert.Equal("UnauthorizedAccessException", root.GetProperty("innerExceptionType").GetString());
        Assert.Equal("<save> access denied", root.GetProperty("innerMessage").GetString());

        using var longMessage = JsonDocument.Parse(FailureTelemetry.FromException(
            "long", new IOException(new string('x', 700))));
        Assert.Equal(513, longMessage.RootElement.GetProperty("message").GetString()!.Length);
    }

    private sealed record TestPayload(string Value);
}
