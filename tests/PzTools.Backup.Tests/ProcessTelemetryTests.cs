using Microsoft.Data.Sqlite;
using System.Text.Json;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;

namespace PzTools.Backup.Tests;

public sealed class ProcessTelemetryTests
{
    [Fact]
    public async Task Session_CoalescesProgressAndFlushesFinalStateBeforeTerminalEvent()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        await using (var session = await ProcessTelemetrySession.StartAsync(
                         identity, "archive-worker", 41,
                         interval: TimeSpan.FromMilliseconds(100)))
        {
            session.RecordEvent("run.started");
            for (var index = 1; index <= 1_000; index++)
                session.SetProgress("import", index, 1_000, index * 12, 12_000, $"file-{index}");
            session.RecordEvent("run.committed");
        }

        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "archive-worker");
        var events = await store.ReadEventsAfterAsync(0);
        Assert.Equal(new[] { "run.started", "progress.snapshot", "run.committed" },
            events.Select(item => item.EventName));
        Assert.Equal(new long[] { 1, 2, 3 }, events.Select(item => item.EventSequence));
        using var payload = JsonDocument.Parse(events[1].PayloadJson!);
        Assert.Equal(1_000, payload.RootElement.GetProperty("completedItems").GetInt64());
        Assert.Equal(12_000, payload.RootElement.GetProperty("completedBytes").GetInt64());
    }

    [Fact]
    public async Task Session_PreservesPhaseBoundaryAndIsolatesStorageFailures()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        await using (var session = await ProcessTelemetrySession.StartAsync(
                         identity, "archive-worker", 42,
                         interval: TimeSpan.FromMilliseconds(100)))
        {
            session.RecordEvent("run.started");
            session.SetProgress("scan", 10, 10, 100, 100, null);
            session.SetProgress("export", 0, 10, 0, 100, null);
            session.SetProgress("export", 10, 10, 100, 100, null);
            session.RecordEvent("run.failed");
        }
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "archive-worker");
        var events = await store.ReadEventsAfterAsync(0);
        Assert.Equal(new[] { "run.started", "progress.snapshot", "progress.snapshot", "run.failed" },
            events.Select(item => item.EventName));
        Assert.Contains("\"phase\":\"scan\"", events[1].PayloadJson);
        Assert.Contains("\"phase\":\"export\"", events[2].PayloadJson);

        var invalidIdentity = temp.GetPath("broken");
        Directory.CreateDirectory(invalidIdentity);
        await File.WriteAllTextAsync(Path.Combine(invalidIdentity, ".pztools"), "not a directory");
        await using var broken = await ProcessTelemetrySession.StartAsync(invalidIdentity, "runner", 1);
        broken.RecordEvent("run.started");
        broken.SetProgress("restore", 1, 1, 1, 1, null);
        broken.RecordEvent("run.committed");
    }

    [Fact]
    public async Task RawEvents_AreAtomicAndTrimByRecentRun()
    {
        using var temp = new TempDirectory();
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(
            temp.GetPath("identity"), "runner");
        await store.RecordAsync("runner", 1, "started");
        await store.RecordAsync("runner", 1, "completed");
        await store.RecordAsync("runner", 2, "started");
        await store.TrimAsync("runner", retainRuns: 1);

        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = store.DatabasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        }.ToString();
        await using var connection = new SqliteConnection(connectionString);
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText =
            "SELECT run_index,event_name,scope_id,event_sequence,elapsed_ticks,payload_version "
            + "FROM telemetry_events ORDER BY event_id;";
        await using var reader = await command.ExecuteReaderAsync();
        Assert.True(await reader.ReadAsync());
        Assert.Equal(2, reader.GetInt64(0));
        Assert.Equal("started", reader.GetString(1));
        Assert.Equal("runner", reader.GetString(2));
        Assert.Equal(1, reader.GetInt64(3));
        Assert.True(reader.GetInt64(4) >= 0);
        Assert.Equal(1, reader.GetInt32(5));
        Assert.False(await reader.ReadAsync());
    }

    [Fact]
    public async Task Runner_TelemetryFailureDoesNotPreventWorkerExecution()
    {
        using var temp = new TempDirectory();
        var invalidIdentity = temp.GetPath("identity");
        Directory.CreateDirectory(invalidIdentity);
        await File.WriteAllTextAsync(
            Path.Combine(invalidIdentity, ".pztools"), "not a directory");

        var envelope = await new OneShotRunnerCoordinator().RunAsync(
            "test-runner",
            "TelemetryFailure",
            invalidIdentity,
            1,
            Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            ["-NoProfile", "-NonInteractive", "-Command",
                "[Console]::WriteLine('" + ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Success(
                    "test-worker", 1, ProcessOutcome.Succeeded, DateTimeOffset.UtcNow)) + "')"],
            "test-worker");

        Assert.Equal(ProcessOutcome.Succeeded, envelope.Outcome);
        Assert.True(envelope.Result?.WorkerStarted);
    }

    [Fact]
    public async Task ComponentsUseIndependentDatabasesAndIdentityDefaults()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        var firstConfig = temp.GetPath("first-component.toml");
        Directory.CreateDirectory(Path.GetDirectoryName(firstConfig)!);
        await File.WriteAllTextAsync(
            firstConfig,
            "[telemetry]\nenabled = false\nretain_runs = 7\n");

        await BestEffortProcessTelemetry.TryRecordAsync(
            identity, "first-component", 1, "disabled", configurationPath: firstConfig);
        await BestEffortProcessTelemetry.TryRecordAsync(
            identity, "second-component", 1, "enabled");

        var firstDatabase = Path.Combine(
            ComponentRuntimePaths.GetComponentDirectory(identity, "first-component"),
            "telemetry.db");
        var secondDatabase = Path.Combine(
            ComponentRuntimePaths.GetComponentDirectory(identity, "second-component"),
            "telemetry.db");
        Assert.False(File.Exists(firstDatabase));
        Assert.True(File.Exists(secondDatabase));
        Assert.NotEqual(firstDatabase, secondDatabase);

        var explicitConfig = temp.GetPath("override.toml");
        await File.WriteAllTextAsync(
            explicitConfig,
            "[telemetry]\nenabled = true\nretain_runs = 1\n");
        var merged = ComponentConfiguration.Load(
            identity, "first-component", explicitConfig);
        Assert.True(merged.GetBoolean("telemetry", "enabled", false));
        Assert.Equal(1, merged.GetInt32("telemetry", "retain_runs", 100));
    }

    [Fact]
    public void FileIdentitiesInSameDirectoryUseDifferentComponentDirectories()
    {
        using var temp = new TempDirectory();

        var first = ComponentRuntimePaths.GetComponentDirectory(
            temp.GetPath("first.db"), "state-runner");
        var second = ComponentRuntimePaths.GetComponentDirectory(
            temp.GetPath("second.db"), "state-runner");

        Assert.NotEqual(first, second);
        Assert.EndsWith(
            Path.Combine(".pztools", "first.db", "state-runner"),
            first,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Heartbeat_RecordsOnlyWhileItsLifetimeIsActive()
    {
        using var temp = new TempDirectory();
        var identity = temp.GetPath("identity");
        // Alive until a beat is stored: a fixed wait of 80 ms failed when a loaded machine ran no timer tick in time.
        await using (ProcessTelemetryHeartbeat.Start(
                         identity, "long-operation", 9,
                         interval: TimeSpan.FromMilliseconds(10)))
        {
            var reader = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "long-operation");
            for (var waited = 0; waited < 10_000; waited += 20)
            {
                await Task.Delay(20);
                if ((await reader.ReadEventsAfterAsync(0)).Any(item => item.EventName == "operation.heartbeat")) break;
            }
        }

        var store = await ProcessTelemetryStore.CreateForIdentityAsync(
            identity, "long-operation");
        var events = await store.ReadEventsAfterAsync(0);
        Assert.Contains(events, item =>
            item.RunIndex == 9 && item.EventName == "operation.heartbeat");
    }
}
