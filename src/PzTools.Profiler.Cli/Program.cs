using System.Globalization;
using System.Text.Json;
using PzTools.Process.Contracts;
using PzTools.Process.Telemetry;
using PzTools.GameBridge;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

// One process is one recording: it asks the game to start, waits for the stop signal, asks the game
// to stop and converts the result. The game does the measuring; nothing here touches game files.
// The rolling recording is the exception: it runs in the game between short commands, each its own process
// (roll-start, roll-save, roll-stop), as it lasts for as long as the app wants it.
const string component = "profiler";
var started = DateTimeOffset.UtcNow;
var runIndex = 1L;
var phase = "arguments";
ProcessTelemetrySession? telemetry = null;
using var cancellation = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };
using var stopRequest = PzTools.Process.Hosting.ProcessStopSignal.Listen(cancellation);
string? recordingPath = null;
try
{
    var command = args.Length == 0 ? "" : args[0];
    if (command is not ("record" or "roll-start" or "roll-save" or "roll-stop"))
        throw new ArgumentException("Expected: record --output <file> --stop-file <file> --mode general|detailed --run-index <n> --telemetry-identity <path>, "
            + "or roll-start --mode general|detailed --seconds <n>, roll-save --output <file> --seconds <n>, roll-stop.");
    runIndex = CommandLine.Int64(Required("--run-index"), "--run-index");
    if (command != "record") return await RollAsync(command);
    var output = Path.GetFullPath(Required("--output"));
    var stopFile = Path.GetFullPath(Required("--stop-file"));
    var mode = Required("--mode");
    if (mode is not ("general" or "detailed")) throw new ArgumentException("--mode must be general or detailed.");
    var maximumSeconds = CommandLine.Int32(Optional("--max-seconds") ?? "600", "--max-seconds", 5, GameProfileClient.MaximumSeconds);
    if (!output.EndsWith(".pzprof", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("--output must end with .pzprof.");
    var bridge = Optional("--bridge") ?? Path.Combine(AppContext.BaseDirectory, "game-bridge");
    var explicitProcess = Optional("--process-id");

    telemetry = await ProcessTelemetrySession.StartAsync(Required("--telemetry-identity"), component, runIndex);
    telemetry.RecordEvent("run.started", JsonSerializer.Serialize(new { operation = "profile", mode }));
    await using var heartbeat = ProcessTelemetryHeartbeat.Start(telemetry);

    phase = "connect";
    var processId = explicitProcess is null ? GameProfileClient.FindGame()
        : CommandLine.Int32(explicitProcess, "--process-id");
    using var game = System.Diagnostics.Process.GetProcessById(processId);
    var directory = Path.GetDirectoryName(output)!;
    Directory.CreateDirectory(directory);
    recordingPath = output + ".jfr";
    var client = new GameProfileClient(bridge);

    phase = "start";
    GameProfileStatus status;
    try { status = await WhenFreeAsync(() => client.StartAsync(processId, recordingPath, mode == "detailed", maximumSeconds, cancellation.Token)); }
    catch (GameSaveException leftover) when (leftover.Code == "already-recording")
    {
        // A recording whose worker died is still running in the game. End it and start the one that was asked for.
        await WhenFreeAsync(() => client.StopAsync(processId, cancellation.Token));
        status = await WhenFreeAsync(() => client.StartAsync(processId, recordingPath, mode == "detailed", maximumSeconds, cancellation.Token));
    }
    RemoveLeftovers(directory, recordingPath);
    var lua = status.Lua.StartsWith("unavailable", StringComparison.Ordinal) ? "unavailable" : status.Lua;
    telemetry.RecordEvent("profile.recording", JsonSerializer.Serialize(new { mode, lua, frames = status.HasFrames }));
    // The app reads this line while the recording runs; the result envelope is the last line.
    Console.WriteLine($"PROFILE\trecording\t{lua}\t{(status.HasFrames ? "frames" : "no-frames")}");

    phase = "recording";
    // No countable progress: a recording lasts until it is stopped.
    telemetry.SetProgress("profile.recording", 0, 0, 0, 0, null);
    var clock = System.Diagnostics.Stopwatch.StartNew();
    var endedBy = "stop";
    var cancelled = false;
    // The game's video memory, read from Windows on each pass; joined to the recording once it is written.
    using var videoMemory = GpuProcessMemory.TryOpen(processId);
    var videoReadings = new List<PzTools.Profiling.VideoMemoryReading>();
    while (true)
    {
        if (videoMemory?.Read() is { } reading)
            videoReadings.Add(new(DateTimeOffset.UtcNow, reading.Dedicated, reading.Shared));
        if (File.Exists(stopFile)) break;
        if (clock.Elapsed.TotalSeconds >= maximumSeconds) { endedBy = "limit"; break; }
        if (game.HasExited) { endedBy = "game-exit"; break; }
        if (cancellation.IsCancellationRequested) { cancelled = true; break; }
        try { await Task.Delay(200, cancellation.Token); } catch (OperationCanceledException) { cancelled = true; break; }
    }

    phase = "stop";
    if (endedBy != "game-exit")
    {
        // Stopping is owed even when this run was cancelled: the game must not keep recording for nobody.
        try { await WhenFreeAsync(() => client.StopAsync(processId, CancellationToken.None), patienceSeconds: 180); }
        catch (GameSaveException gone) when (gone.Code is "not-recording" or "game-not-running" or "connection-timeout" || gone.LinkUnavailable)
        {
            if (!File.Exists(recordingPath)) throw;
        }
    }
    if (cancelled) throw new OperationCanceledException();

    phase = "convert";
    telemetry.SetProgress("profile.converting", 0, 0, 0, 0, null);
    Console.WriteLine("PROFILE\tconverting");
    // The recorder finishes its file a moment after the game is told to stop, or while the game exits.
    for (var attempt = 0; attempt < 50 && !File.Exists(recordingPath); attempt++) await Task.Delay(100, cancellation.Token);
    var exported = await client.ExportAsync(recordingPath, output, new Dictionary<string, string>
    {
        ["mode"] = mode,
        ["lua"] = lua,
        ["hasFrames"] = status.HasFrames ? "true" : "false",
        ["endedBy"] = endedBy,
        ["toolVersion"] = typeof(GameProfileClient).Assembly.GetName().Version?.ToString() ?? "0",
    }, cancellation.Token);
    // Diagnosis only: the raw recording holds full paths and is not meant to be shared.
    if (!args.Contains("--keep-raw")) TryDelete(recordingPath);
    // Optional: a recording without its video memory is still a whole recording.
    var videoMemoryReadings = 0;
    try { videoMemoryReadings = PzTools.Profiling.ProfileVideoMemory.Append(output, videoReadings); }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
    {
        telemetry.RecordEvent("profile.video-memory-skipped", FailureTelemetry.FromException("video-memory-append-failed", exception, phase: phase, operation: "profile"));
    }

    var result = new
    {
        path = output,
        mode,
        lua,
        hasFrames = status.HasFrames,
        endedBy,
        samples = exported.Samples,
        frames = exported.Frames,
        luaSamples = exported.LuaSamples,
        durationMicroseconds = exported.DurationMicroseconds,
        videoMemoryReadings,
    };
    telemetry.RecordEvent("run.committed", JsonSerializer.Serialize(new
    {
        operation = "profile", mode, endedBy, samples = exported.Samples, frames = exported.Frames,
        seconds = exported.DurationMicroseconds / 1_000_000,
    }));
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Success(
        component, runIndex, ProcessOutcome.Succeeded, started, result)));
    return ProcessExitCodes.Success;
}
catch (OperationCanceledException)
{
    if (recordingPath is not null) TryDelete(recordingPath);
    telemetry?.RecordEvent("run.cancelled");
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        component, runIndex, ProcessOutcome.Cancelled, started, "cancelled", "The recording was cancelled.")));
    return ProcessExitCodes.Cancelled;
}
catch (Exception exception) when (exception is ArgumentException or FormatException or OverflowException)
{
    telemetry?.RecordEvent("run.failed", FailureTelemetry.FromException("invalid-arguments", exception, status: "Failed", phase: phase, operation: "profile"));
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        component, Math.Max(1, runIndex), ProcessOutcome.Failed, started, "invalid-arguments", exception.Message)));
    return ProcessExitCodes.InvalidArguments;
}
catch (GameSaveException missing) when (phase == "connect" && missing.Code is "game-not-running" or "multiple-games")
{
    // No game to record, or no way to tell which: nothing was attempted, so nothing failed. The app says why.
    var code = "profile-" + missing.Code;
    telemetry?.RecordEvent("run.unavailable", FailureTelemetry.FromException(code, missing, status: "Unavailable", phase: phase, operation: "profile"));
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        component, runIndex, ProcessOutcome.Failed, started, code, missing.Message)));
    return ProcessExitCodes.Failure;
}
catch (Exception exception)
{
    if (recordingPath is not null) TryDelete(recordingPath);
    // The game's own codes (game-not-running, attach-failed, ...) are what the app explains to the user.
    var code = exception is GameSaveException game ? "profile-" + game.Code : phase == "convert" ? "profile-convert-failed" : "profile-failed";
    telemetry?.RecordEvent("run.failed", FailureTelemetry.FromException(code, exception, status: "Failed", phase: phase, operation: "profile"));
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Failure(
        component, runIndex, ProcessOutcome.Failed, started, code, exception.Message)));
    return ProcessExitCodes.Failure;
}
finally { if (telemetry is not null) await telemetry.DisposeAsync(); }

// The rolling recording's commands. Saving takes what the game holds, cut to the window, as a recording like any
// other; its video memory is not known, as nothing outside the game was reading it.
async Task<int> RollAsync(string command)
{
    var keepSeconds = command == "roll-stop" ? 0 : CommandLine.Int32(Required("--seconds"), "--seconds",
        GameProfileClient.MinimumRollingSeconds, GameProfileClient.MaximumRollingSeconds);
    var mode = command == "roll-start" ? Required("--mode") : null;
    if (mode is not (null or "general" or "detailed")) throw new ArgumentException("--mode must be general or detailed.");
    var output = command == "roll-save" ? Path.GetFullPath(Required("--output")) : null;
    if (output is not null && !output.EndsWith(".pzprof", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("--output must end with .pzprof.");
    var bridge = Optional("--bridge") ?? Path.Combine(AppContext.BaseDirectory, "game-bridge");
    var explicitProcess = Optional("--process-id");
    var operation = command == "roll-save" ? "profile" : "profile-roll";

    telemetry = await ProcessTelemetrySession.StartAsync(Required("--telemetry-identity"), component, runIndex);
    telemetry.RecordEvent("run.started", JsonSerializer.Serialize(new { operation, command, mode }));
    await using var heartbeat = ProcessTelemetryHeartbeat.Start(telemetry);

    phase = "connect";
    var processId = explicitProcess is null ? GameProfileClient.FindGame() : CommandLine.Int32(explicitProcess, "--process-id");
    var client = new GameProfileClient(bridge);
    object result;
    switch (command)
    {
        case "roll-start":
        {
            phase = "start";
            var megabytes = Optional("--max-megabytes") is { } limit
                ? CommandLine.Int32(limit, "--max-megabytes", GameProfileClient.MinimumRollingMegabytes, GameProfileClient.MaximumRollingMegabytes) : 0;
            var owner = Optional("--owner-pid") is { } ownerText ? CommandLine.Int32(ownerText, "--owner-pid", 1, int.MaxValue) : 0;
            var status = await WhenFreeAsync(() => client.StartRollingAsync(processId, mode == "detailed", keepSeconds, cancellation.Token, megabytes, owner));
            var lua = status.Lua.StartsWith("unavailable", StringComparison.Ordinal) ? "unavailable" : status.Lua;
            result = new { mode, keepSeconds, lua, hasFrames = status.HasFrames };
            break;
        }
        case "roll-save":
        {
            phase = "save";
            Directory.CreateDirectory(Path.GetDirectoryName(output)!);
            recordingPath = output + ".jfr";
            // The game writes what it holds when asked, so the window ends no earlier than this: it begins this long
            // before, and the converter cuts there without reading the file to find its end.
            var asked = DateTimeOffset.UtcNow;
            var status = await WhenFreeAsync(() =>
            {
                // Each try: a wait for the channel is not part of the window.
                asked = DateTimeOffset.UtcNow;
                return client.SaveRollingAsync(processId, recordingPath, cancellation.Token);
            }, patienceSeconds: 60);
            var lua = status.Lua.StartsWith("unavailable", StringComparison.Ordinal) ? "unavailable" : status.Lua;
            phase = "convert";
            telemetry.SetProgress("profile.converting", 0, 0, 0, 0, null);
            var exported = await client.ExportAsync(recordingPath, output!, new Dictionary<string, string>
            {
                ["mode"] = status.Mode,
                ["lua"] = lua,
                ["hasFrames"] = status.HasFrames ? "true" : "false",
                ["endedBy"] = "rolling",
                ["toolVersion"] = typeof(GameProfileClient).Assembly.GetName().Version?.ToString() ?? "0",
            }, cancellation.Token, keepFrom: asked.AddSeconds(-keepSeconds));
            TryDelete(recordingPath);
            result = new
            {
                path = output, mode = status.Mode, lua, hasFrames = status.HasFrames, endedBy = "rolling",
                samples = exported.Samples, frames = exported.Frames, luaSamples = exported.LuaSamples,
                durationMicroseconds = exported.DurationMicroseconds,
            };
            break;
        }
        default:
        {
            phase = "stop";
            // A rolling recording only: one someone asked for is left to its own worker.
            var status = await WhenFreeAsync(() => client.StopRollingAsync(processId, cancellation.Token), patienceSeconds: 60);
            result = new { state = status.State };
            break;
        }
    }
    telemetry.RecordEvent("run.committed", JsonSerializer.Serialize(new { operation, command, mode }));
    Console.WriteLine(ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Success(
        component, runIndex, ProcessOutcome.Succeeded, started, result)));
    return ProcessExitCodes.Success;
}

// A backup's save request may hold the game's request channel for a while; recording control simply waits its turn.
// Starting gives up after 20 seconds. Stopping waits out a whole game save (a backup allows it 150 seconds by default):
// giving up there would leave the game recording for nobody until its limit.
async Task<GameProfileStatus> WhenFreeAsync(Func<Task<GameProfileStatus>> request, int patienceSeconds = 20)
{
    var waited = System.Diagnostics.Stopwatch.StartNew();
    while (true)
    {
        try { return await request(); }
        catch (GameSaveException busy) when (busy.Code == "busy" && waited.Elapsed.TotalSeconds < patienceSeconds)
        {
            await Task.Delay(500);
        }
    }
}

// Raw recordings of runs that never finished. They are large and hold full file paths, so they are not kept. Only
// ones an hour old: a save of the last minutes may be converting its raw file in the same folder right now.
void RemoveLeftovers(string directory, string current)
{
    try
    {
        var before = DateTime.UtcNow.AddHours(-1);
        foreach (var file in Directory.EnumerateFiles(directory, "*.pzprof.jfr"))
            if (!file.Equals(current, StringComparison.OrdinalIgnoreCase) && File.GetLastWriteTimeUtc(file) < before) TryDelete(file);
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
}

void TryDelete(string path)
{
    try { File.Delete(path); }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
}

string Required(string key) => CommandLine.Required(args, key);

string? Optional(string key) => CommandLine.Optional(args, key);
