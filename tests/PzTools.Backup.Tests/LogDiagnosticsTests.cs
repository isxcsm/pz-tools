using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class LogDiagnosticsTests
{
    [Theory]
    [InlineData("{\"outcome\":2}", "Skipped")]
    [InlineData("{\"status\":2}", "Failed")]
    [InlineData("{\"outcome\":3}", "Busy")]
    [InlineData("{\"status\":3}", "Cancelled")]
    [InlineData("{\"status\":4}", "Abandoned")]
    [InlineData("{\"outcome\":\"failed\"}", "Failed")]
    [InlineData("{\"status\":\"degraded\"}", "Degraded")]
    [InlineData("{\"status\":\"Succeeded\",\"outcome\":\"Failed\"}", "Failed")]
    public void OutcomeDecodingRespectsTheProducerEnumAndOutcomeTakesPriority(string payload, string expected)
        => Assert.Equal(expected, LogDiagnostics.ReadOutcome(payload));

    [Theory]
    [InlineData("Busy")]
    [InlineData("saved")]
    [InlineData("not-in-world")]
    [InlineData("game-not-running")]
    [InlineData("save-mismatch")]
    public void NonFailureOutcomeIsAvailableWithoutDisplayingFailureDiagnostics(string outcome)
    {
        var payload = System.Text.Json.JsonSerializer.Serialize(new { outcome });
        Assert.Equal(outcome, LogDiagnostics.ReadOutcome(payload));
        Assert.Null(LogDiagnostics.Parse(payload));
        Assert.Null(LogDiagnostics.ReadOutcome("broken"));
        Assert.Null(LogDiagnostics.ReadOutcome("[]"));
    }

    [Fact]
    public void Parse_RecognizesDetailedAndLegacyFailures()
    {
        var detailed = LogDiagnostics.Parse("""
            {"failureCode":"UnstableFileException","phase":"capture","path":"map_meta.bin",
             "reason":"file changed","message":"file changed","innerExceptionType":"IOException"}
            """);
        Assert.NotNull(detailed);
        Assert.Equal("map_meta.bin", detailed.Path);
        Assert.Equal("capture", detailed.Phase);
        Assert.Equal("IOException", detailed.InnerExceptionType);

        var legacy = LogDiagnostics.Parse("""{"status":2,"failureCode":"UnstableFileException"}""");
        Assert.Equal("UnstableFileException", legacy?.FailureCode);
        Assert.Null(legacy?.Path);
    }

    [Fact]
    public void Parse_RecognizesFailedSchedulerButIgnoresSuccessAndInvalidJson()
    {
        var scheduler = LogDiagnostics.Parse("""{"outcome":"Failed","failureOrigin":"backup-worker"}""");
        Assert.Equal("backup-worker", scheduler?.FailureOrigin);
        Assert.Equal("Failed", LogDiagnostics.Parse("""{"outcome":5}""")?.Outcome);
        var cleanup = LogDiagnostics.Parse("""{"outcome":"Degraded","failureCode":"file-delete-failed","failedFileCount":2,"failedFiles":["a.pack","b.pack"]}""");
        Assert.Equal("2", cleanup?.FailedFileCount);
        Assert.Equal("a.pack, b.pack", cleanup?.FailedFiles);
        Assert.Null(LogDiagnostics.Parse("{\"outcome\":\"Succeeded\"}"));
        Assert.Null(LogDiagnostics.Parse("not json"));
    }
}
