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

    private static Task<LogsView> ReadAsync(LogInboxStore sink) =>
        sink.ReadViewAsync(new LogProjectionOptions(LogLevel.Information, 100));

    private static RuntimeExtensionStatus Active() => new(RuntimeExtensionState.Active,
        ProcessSession: "11111111111111111111111111111111", WorldSession: "22222222222222222222222222222222",
        Generation: "33333333333333333333333333333333", AppliedRevision: 4,
        ModuleVersion: "0.2.0", ModuleHash: new string('a', 64), Diagnostics: "rpm=800",
        RequestedRevision: 4, ControlReady: true, AppliedVehicleOptions: new(true, false, true));
}
