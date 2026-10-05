using System.Text.Json;
using PzTools.App.Core;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class ExtensionRuntimeDiagnosticsTests
{
    [Fact]
    public async Task HeartbeatsAndSamplesDoNotFloodDurableLog()
    {
        using var temp = new TempDirectory();
        var logger = new ExtensionRuntimeDiagnostics(temp.Path);
        var status = Active();
        logger.Observe(null);
        logger.Observe(status);
        for (var i = 0; i < 1000; i++)
            logger.Observe(status with { AgeMilliseconds = i, Diagnostics = $"rpm={800 + i}" });
        await logger.FlushAsync();

        var sink = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var entry = Assert.Single((await ReadAsync(sink)).Entries);
        Assert.Equal(LogLevel.Information, entry.Level);
        Assert.Equal("extension.runtime.changed", entry.EventName);
        using var payload = JsonDocument.Parse(entry.PayloadJson!);
        Assert.Equal("pztools.vehicle-drivetrain", payload.RootElement.GetProperty("extensionId").GetString());
        Assert.Equal(status.ProcessSession, payload.RootElement.GetProperty("processSession").GetString());
        Assert.Equal(status.ModuleVersion, payload.RootElement.GetProperty("moduleVersion").GetString());
        Assert.Equal(status.ModuleHash, payload.RootElement.GetProperty("moduleHash").GetString());
        Assert.Equal("rpm=800", payload.RootElement.GetProperty("diagnostics").GetString());
        Assert.Equal(4, payload.RootElement.GetProperty("requestedRevision").GetInt64());
        Assert.True(payload.RootElement.GetProperty("controlReady").GetBoolean());
        var options = payload.RootElement.GetProperty("appliedVehicleOptions");
        Assert.True(options.GetProperty("torqueEnabled").GetBoolean());
        Assert.False(options.GetProperty("reverseEnabled").GetBoolean());
        Assert.True(options.GetProperty("steeringEnabled").GetBoolean());
    }

    // Seen in a test drive: after the vehicle stopped, its last sample was written again every ten seconds, only older.
    [Fact]
    public async Task ASampleThatOnlyGrewOlderIsNotWrittenAgain()
    {
        using var temp = new TempDirectory();
        var sink = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var clock = new ManualTime(new DateTimeOffset(2026, 10, 5, 12, 0, 0, TimeSpan.Zero));
        var logger = new ExtensionRuntimeDiagnostics(temp.Path, () => sink, clock);
        var status = Active();
        void At(double seconds, string diagnostics)
        {
            clock.Now = new DateTimeOffset(2026, 10, 5, 12, 0, 0, TimeSpan.Zero).AddSeconds(seconds);
            logger.Observe(status with { Diagnostics = diagnostics });
        }
        At(0, "samples=5;rpm=1000;sample_age_ms=3");
        At(10, "samples=9;rpm=1200;sample_age_ms=1");    // Driving: a newer sample.
        At(20, "samples=9;rpm=1200;sample_age_ms=10012"); // Stopped: the same sample, older.
        At(30, "samples=9;rpm=1200;sample_age_ms=20015");
        At(40, "samples=12;rpm=900;sample_age_ms=2");     // Driving again.
        await logger.FlushAsync();

        var entries = (await ReadAsync(sink)).Entries.OrderBy(entry => entry.EventId).ToArray();
        Assert.Equal([ExtensionRuntimeDiagnostics.ChangedEvent, ExtensionRuntimeDiagnostics.SampleEvent,
            ExtensionRuntimeDiagnostics.SampleEvent], entries.Select(entry => entry.EventName));
        using var last = JsonDocument.Parse(entries[^1].PayloadJson!);
        // What is written is the sample as it came, age included.
        Assert.Equal("samples=12;rpm=900;sample_age_ms=2", last.RootElement.GetProperty("diagnostics").GetString());
    }

    [Fact]
    public async Task SteadyDrivingWithDiagnosticsWritesASampleAtMostEveryTenSeconds()
    {
        using var temp = new TempDirectory();
        var sink = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var clock = new ManualTime(new DateTimeOffset(2026, 10, 5, 12, 0, 0, TimeSpan.Zero));
        var logger = new ExtensionRuntimeDiagnostics(temp.Path, () => sink, clock);
        var status = Active();
        void At(double seconds, RuntimeExtensionStatus value)
        {
            clock.Now = new DateTimeOffset(2026, 10, 5, 12, 0, 0, TimeSpan.Zero).AddSeconds(seconds);
            logger.Observe(value);
        }
        At(0, status);                                                  // The state: one entry.
        At(5, status with { Diagnostics = "rpm=900" });                 // Too soon after it.
        At(10, status with { Diagnostics = "rpm=1000" });               // A sample.
        At(15, status with { Diagnostics = "rpm=1100" });               // Too soon.
        At(25, status with { Diagnostics = "rpm=1000" });               // The sample already written.
        At(26, status with { Diagnostics = "rpm=1200" });               // A sample.
        At(40, status with { Diagnostics = "" });                       // Diagnostics off: nothing to show.
        At(41, status with { Reason = "revision-conflict", Diagnostics = "rpm=1300" }); // A change, at once.
        At(45, status with { Reason = "revision-conflict", Diagnostics = "rpm=1400" }); // Too soon after the change.
        At(51, status with { Reason = "revision-conflict", Diagnostics = "rpm=1500" }); // A sample, at its own level.
        await logger.FlushAsync();

        var entries = (await ReadAsync(sink)).Entries.OrderBy(entry => entry.EventId).ToArray();
        Assert.Equal([ExtensionRuntimeDiagnostics.ChangedEvent, ExtensionRuntimeDiagnostics.SampleEvent,
            ExtensionRuntimeDiagnostics.SampleEvent, ExtensionRuntimeDiagnostics.ChangedEvent, ExtensionRuntimeDiagnostics.SampleEvent],
            entries.Select(entry => entry.EventName));
        string? Sample(LogEntryView entry)
        {
            using var payload = JsonDocument.Parse(entry.PayloadJson!);
            return payload.RootElement.GetProperty("diagnostics").GetString();
        }
        Assert.Equal(["rpm=800", "rpm=1000", "rpm=1200", "rpm=1300", "rpm=1500"], entries.Select(Sample));
        Assert.Equal(LogLevel.Warning, entries[3].Level);
        // A sample repeats a recorded state; it is not another warning.
        Assert.Equal(LogLevel.Information, entries[4].Level);
        Assert.Null(LogDiagnostics.Parse(entries[4].PayloadJson)?.FailureCode);
    }

    [Fact]
    public async Task EveryIdentityDimensionAndReturnTransitionIsRecordedInOrder()
    {
        using var temp = new TempDirectory();
        var sink = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var logger = new ExtensionRuntimeDiagnostics(temp.Path, () => sink);
        var status = Active();
        RuntimeExtensionStatus[] transitions = [
            status with { State = RuntimeExtensionState.Pending },
            status with { ProcessSession = Guid.NewGuid().ToString("N") },
            status with { WorldSession = Guid.NewGuid().ToString("N") },
            status with { Generation = Guid.NewGuid().ToString("N") },
            status with { AppliedRevision = 5 },
            status with { RequestedRevision = 5 },
            status with { Reason = "revision-conflict" }];
        logger.Observe(status);
        foreach (var transition in transitions)
        {
            logger.Observe(transition);
            logger.Observe(status);
        }
        await logger.FlushAsync();
        var entries = (await ReadAsync(sink)).Entries.OrderBy(entry => entry.EventId).ToArray();
        Assert.Equal(1 + transitions.Length * 2, entries.Length);
        Assert.Equal(Enumerable.Range(1, entries.Length).Select(value => (long)value), entries.Select(entry => entry.EventId));
        Assert.Equal(LogLevel.Warning, entries[^2].Level);
        Assert.Equal(LogLevel.Information, entries[^1].Level);
    }

    [Theory]
    [InlineData(RuntimeExtensionState.Disabled, "user-disabled", LogLevel.Information)]
    [InlineData(RuntimeExtensionState.Pending, "safe-boundary", LogLevel.Information)]
    [InlineData(RuntimeExtensionState.Unsupported, "unsupported-game-resource", LogLevel.Warning)]
    [InlineData(RuntimeExtensionState.FaultedPassThrough, "callback-failed", LogLevel.Error)]
    [InlineData(RuntimeExtensionState.RestartRequired, "retirement-failed", LogLevel.Error)]
    [InlineData(RuntimeExtensionState.RestartRequired, "bootstrap-update", LogLevel.Information)]
    [InlineData(RuntimeExtensionState.Active, "update-rejected:preflight:changed", LogLevel.Warning)]
    [InlineData(RuntimeExtensionState.Active, "configuration-invalid", LogLevel.Warning)]
    [InlineData(RuntimeExtensionState.Active, "revision-conflict", LogLevel.Warning)]
    [InlineData(RuntimeExtensionState.Active, "process-changed", LogLevel.Warning)]
    public async Task FailuresRemainVisibleEvenWhenOldGenerationIsActive(RuntimeExtensionState state,
        string reason, LogLevel expected)
    {
        using var temp = new TempDirectory();
        var sink = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var logger = new ExtensionRuntimeDiagnostics(temp.Path, () => sink);
        logger.Observe(Active() with { State = state, Reason = reason });
        await logger.FlushAsync();
        var entry = Assert.Single((await ReadAsync(sink)).Entries);
        Assert.Equal(expected, entry.Level);
        if (expected >= LogLevel.Warning) Assert.Equal(reason, LogDiagnostics.Parse(entry.PayloadJson)?.FailureCode);
    }

    [Fact]
    public async Task SharedInboxKeepsItsCacheAndRecordingPolicy()
    {
        using var temp = new TempDirectory();
        var sink = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        await sink.ConfigureStorageAsync(LogLevel.Warning, 10000);
        Assert.Empty((await ReadAsync(sink)).Entries);
        var logger = new ExtensionRuntimeDiagnostics(temp.Path, () => sink);
        logger.Observe(Active());
        logger.Observe(Active() with { State = RuntimeExtensionState.FaultedPassThrough, Reason = "callback-failed" });
        await logger.FlushAsync();
        Assert.Equal(LogLevel.Error, Assert.Single((await ReadAsync(sink)).Entries).Level);
    }

    [Fact]
    public async Task ConcurrentDuplicateObservationsAndUnavailableSamplesAreCoalesced()
    {
        using var temp = new TempDirectory();
        var sink = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var logger = new ExtensionRuntimeDiagnostics(temp.Path, () => sink);
        var status = Active();
        Parallel.For(0, 100, _ => logger.Observe(status));
        logger.Observe(null);
        logger.Observe(null);
        await logger.FlushAsync();
        var entries = (await ReadAsync(sink)).Entries.OrderBy(entry => entry.EventId).ToArray();
        Assert.Equal(2, entries.Length);
        Assert.Equal(LogLevel.Information, entries[1].Level);
        Assert.Null(LogDiagnostics.Parse(entries[1].PayloadJson));
        using var payload = JsonDocument.Parse(entries[1].PayloadJson!);
        Assert.Equal("runtime-status-unavailable", payload.RootElement.GetProperty("reason").GetString());
        Assert.Equal(JsonValueKind.Null, payload.RootElement.GetProperty("failureCode").ValueKind);
    }

    [Fact]
    public async Task LoggingFailureDoesNotEscapeOrRetryOnEveryHeartbeat()
    {
        using var temp = new TempDirectory();
        var calls = 0;
        var logger = new ExtensionRuntimeDiagnostics(temp.Path, () =>
        {
            Interlocked.Increment(ref calls);
            throw new IOException("synthetic log sink failure");
        });
        var status = Active();
        for (var i = 0; i < 100; i++) logger.Observe(status with { AgeMilliseconds = i });
        await logger.FlushAsync();
        Assert.Equal(1, calls);
        logger.Observe(status with { RequestedRevision = 5 });
        await logger.FlushAsync();
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task InvalidStoragePathDoesNotEscapeObserveOrFlush()
    {
        using var temp = new TempDirectory();
        Directory.CreateDirectory(temp.GetPath("logs.db"));
        var logger = new ExtensionRuntimeDiagnostics(temp.Path);
        logger.Observe(Active());
        await logger.FlushAsync();
    }

    private sealed class ManualTime(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private static Task<LogsView> ReadAsync(LogInboxStore sink) =>
        sink.ReadViewAsync(new LogProjectionOptions(LogLevel.Information, 100));

    private static RuntimeExtensionStatus Active() => new(RuntimeExtensionState.Active,
        ProcessSession: "11111111111111111111111111111111", WorldSession: "22222222222222222222222222222222",
        Generation: "33333333333333333333333333333333", AppliedRevision: 4,
        ModuleVersion: "0.2.0", ModuleHash: new string('a', 64), Diagnostics: "rpm=800",
        RequestedRevision: 4, ControlReady: true, AppliedVehicleOptions: new(true, false, true));
}
