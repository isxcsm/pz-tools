using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.State;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

var started = DateTimeOffset.UtcNow;
var runIndex = 1L;
string? statePath = null;
string? configurationPath = null;
var hasRunIndex = false;
try
{
    var values = Parse(args);
    statePath = Required(values, "--state-db");
    configurationPath = values.GetValueOrDefault("--config");
    var database = await StateDatabase.CreateOrOpenAsync(statePath);
    runIndex = values.TryGetValue("--run-index", out var run)
        ? long.Parse(run)
        : await new RunIndexAllocator(values.GetValueOrDefault("--control-db")).AllocateAsync();
    if (runIndex <= 0) throw new ArgumentOutOfRangeException("--run-index");
    hasRunIndex = true;
    var result = await new StateReactor().RunAsync(database);
    await TryTelemetryAsync(
        statePath, runIndex, "reactor.completed", configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<ReactorResult>.Success(
            "state-reactor", runIndex, ProcessOutcome.Succeeded, started, result)));
    return 0;
}
catch (Exception exception)
{
    if (hasRunIndex && statePath is not null)
        await BestEffortProcessTelemetry.TryRecordAsync(
            statePath, "state-reactor", runIndex, "reactor.failed",
            FailureTelemetry.FromException(
                "reactor-failed", exception, phase: "state-reaction",
                operation: "state-reaction"),
            configurationPath);
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Failure(
            "state-reactor", runIndex, ProcessOutcome.Failed, started, "reactor-failed", exception.Message)));
    return 1;
}
static Dictionary<string, string> Parse(string[] arguments)
{
    var allowed = new HashSet<string>(StringComparer.Ordinal)
    {
        "--state-db", "--run-index", "--config", "--control-db",
    };
    var values = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var index = 0; index < arguments.Length; index++)
    {
        var name = arguments[index];
        if (!allowed.Contains(name)) throw new ArgumentException($"Unknown option '{name}'.");
        if (++index >= arguments.Length) throw new ArgumentException($"{name} requires a value.");
        var value = arguments[index];
        values.Add(name, value);
    }
    return values;
}
static string Required(Dictionary<string, string> values, string name) =>
    values.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value)
        ? value : throw new ArgumentException($"{name} is required.");
static async Task TryTelemetryAsync(
    string identity,
    long run,
    string name,
    string? configurationPath)
{
    await BestEffortProcessTelemetry.TryRecordAsync(
        identity, "state-reactor", run, name,
        configurationPath: configurationPath);
}
