using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using PzTools.Backup.Benchmarks;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;

if (args.FirstOrDefault() is "--tune" or "--tune-generate")
    return await TuningProfile.RunAsync(args);

var workerOptions = WorkerOptions.Extract(args);
var settings = ProfileSettings.Parse(workerOptions.ProfileArguments);
Directory.CreateDirectory(settings.OutputRoot);
if (workerOptions.Scenario is not null)
{
    var scenario = settings.Scenarios.Single(item => item.Name == workerOptions.Scenario);
    var workerResult = await RunScenarioAsync(settings, scenario);
    await File.WriteAllTextAsync(
        workerOptions.OutputPath
            ?? throw new ArgumentException("A profile worker requires --worker-output."),
        JsonSerializer.Serialize(workerResult));
    return 0;
}

var results = new List<ProfileResult>();
foreach (var scenario in settings.Scenarios)
{
    results.Add(await RunScenarioInChildProcessAsync(settings, scenario));
}

var outputPath = Path.Combine(settings.OutputRoot, "profile-results.json");
await File.WriteAllTextAsync(
    outputPath,
    JsonSerializer.Serialize(
        new ProfileReport(DateTimeOffset.UtcNow, Environment.MachineName, results),
        new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
Console.WriteLine(outputPath);
return 0;

static async Task<ProfileResult> RunScenarioInChildProcessAsync(
    ProfileSettings settings,
    ProfileScenario scenario)
{
    var resultPath = Path.Combine(
        settings.OutputRoot,
        $"worker-{scenario.Name}-{Guid.NewGuid():N}.json");
    var executable = Environment.ProcessPath
        ?? throw new InvalidOperationException("The benchmark process path is unavailable.");
    var start = new ProcessStartInfo(executable)
    {
        UseShellExecute = false,
        RedirectStandardError = true,
        RedirectStandardOutput = true,
        CreateNoWindow = true,
    };
    if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
    {
        start.ArgumentList.Add(
            Assembly.GetEntryAssembly()?.Location
            ?? throw new InvalidOperationException("The benchmark assembly path is unavailable."));
    }

    foreach (var argument in settings.ToArguments())
    {
        start.ArgumentList.Add(argument);
    }

    start.ArgumentList.Add("--worker-scenario");
    start.ArgumentList.Add(scenario.Name);
    start.ArgumentList.Add("--worker-output");
    start.ArgumentList.Add(resultPath);
    using var process = Process.Start(start)
        ?? throw new InvalidOperationException("Could not start benchmark worker process.");
    var standardError = process.StandardError.ReadToEndAsync();
    var standardOutput = process.StandardOutput.ReadToEndAsync();
    await process.WaitForExitAsync();
    if (process.ExitCode != 0)
    {
        throw new InvalidOperationException(
            $"Benchmark worker '{scenario.Name}' failed: {await standardError}");
    }

    _ = await standardOutput;
    try
    {
        return JsonSerializer.Deserialize<ProfileResult>(
                await File.ReadAllTextAsync(resultPath))
            ?? throw new InvalidDataException("Benchmark worker returned an empty result.");
    }
    finally
    {
        File.Delete(resultPath);
    }
}

static async Task<ProfileResult> RunScenarioAsync(
    ProfileSettings settings,
    ProfileScenario scenario)
{
    var scenarioRoot = Path.Combine(
        settings.OutputRoot,
        $"run-{scenario.Name}-{Guid.NewGuid():N}");
    var sourcePath = Path.Combine(scenarioRoot, "source");
    var repositoryPath = Path.Combine(scenarioRoot, "repository");
    var restorePath = Path.Combine(scenarioRoot, "restore");
    Directory.CreateDirectory(scenarioRoot);
    var generator = new DeterministicLoadGenerator(settings.Seed);
    var generate = await MeasureAsync(() => generator.GenerateAsync(
        sourcePath,
        settings.FileCount,
        settings.BytesPerFile,
        settings.Compressible));
    var journal = new SyntheticJournal(new UsnJournalState(1, 2, 0, 100, 0));
    var options = new BackupOptions(
        BackupConfiguration.CurrentFormatVersion,
        repositoryPath,
        [new BackupSourceOptions("profile", sourcePath)],
        new StorageOptions(scenario.Checksum, scenario.Compression, false,
            scenario.VerifyStagedCopies),
        new TelemetryOptions(scenario.Telemetry, 256, 250, 100, 256));
    var service = new OneShotBackupService(journal);
    var initial = await MeasureResultAsync(() => service.RunAsync(options, "profile"));
    journal.Records = await generator.MutateAsync(
        sourcePath,
        settings.OperationsPerKind,
        firstUsn: 101);
    journal.State = journal.State with { NextUsn = 1_000_000 };
    var incremental = await MeasureResultAsync(() => service.RunAsync(options, "profile"));
    var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
    var source = await GetSourceAsync(repository, sourcePath);
    var state = await repository.GetSourceStateAsync(source.SourceId);
    var restore = await MeasureResultAsync(() => new RevisionRestorer().RestoreAsync(
        repository,
        source.SourceId,
        state.CurrentRevision,
        restorePath));
    var verify = await MeasureResultAsync(() => new RepositoryVerifier().VerifyAsync(repository));
    var repositoryBytes = Directory.EnumerateFiles(repositoryPath, "*", SearchOption.AllDirectories)
        .Sum(path => new FileInfo(path).Length);
    return new ProfileResult(
        scenario.Name,
        settings.FileCount,
        settings.BytesPerFile,
        settings.Compressible,
        generate,
        initial,
        incremental,
        restore,
        verify,
        repositoryBytes,
        Process.GetCurrentProcess().PeakWorkingSet64);
}

static async Task<RepositorySource> GetSourceAsync(RepositoryDatabase repository, string sourcePath)
{
    await using var connection = await repository.OpenConnectionAsync();
    await using var command = connection.CreateCommand();
    command.CommandText =
        """
        SELECT source_id, source_key, root_path, created_utc FROM sources LIMIT 1;
        """;
    await using var reader = await command.ExecuteReaderAsync();
    await reader.ReadAsync();
    return new RepositorySource(
        reader.GetInt64(0),
        reader.GetString(1),
        sourcePath,
        DateTimeOffset.Parse(reader.GetString(3), System.Globalization.CultureInfo.InvariantCulture));
}

static async Task<Measurement> MeasureAsync(Func<Task> action)
{
    GC.Collect();
    var allocated = GC.GetTotalAllocatedBytes(precise: true);
    var stopwatch = Stopwatch.StartNew();
    await action();
    stopwatch.Stop();
    return new Measurement(stopwatch.Elapsed.TotalMilliseconds, GC.GetTotalAllocatedBytes(true) - allocated);
}

static async Task<Measurement> MeasureResultAsync<T>(Func<Task<T>> action)
{
    GC.Collect();
    var allocated = GC.GetTotalAllocatedBytes(precise: true);
    var stopwatch = Stopwatch.StartNew();
    _ = await action();
    stopwatch.Stop();
    return new Measurement(stopwatch.Elapsed.TotalMilliseconds, GC.GetTotalAllocatedBytes(true) - allocated);
}

internal sealed class SyntheticJournal(UsnJournalState state) : IUsnJournalSource
{
    public UsnJournalState State { get; set; } = state;

    public IReadOnlyList<UsnRecord> Records { get; set; } = [];

    public UsnJournalState Query(string sourcePath) => State;

    public IEnumerable<UsnRecord> ReadRange(
        string sourcePath,
        UsnCheckpoint checkpoint,
        long upperUsnExclusive,
        CancellationToken cancellationToken = default) => Records;
}

internal sealed record Measurement(double ElapsedMilliseconds, long AllocatedBytes);

internal sealed record ProfileResult(
    string Scenario,
    int FileCount,
    int BytesPerFile,
    bool Compressible,
    Measurement Generate,
    Measurement InitialBackup,
    Measurement IncrementalBackup,
    Measurement Restore,
    Measurement Verify,
    long RepositoryBytes,
    long ProcessPeakWorkingSetBytes);

internal sealed record ProfileReport(
    DateTimeOffset CreatedUtc,
    string MachineName,
    IReadOnlyList<ProfileResult> Results);

internal sealed record ProfileScenario(
    string Name,
    ChecksumAlgorithm Checksum,
    CompressionAlgorithm Compression,
    TelemetryMode Telemetry,
    bool VerifyStagedCopies = true);

internal sealed record ProfileSettings(
    string OutputRoot,
    int Seed,
    int FileCount,
    int BytesPerFile,
    bool Compressible,
    int OperationsPerKind,
    IReadOnlyList<ProfileScenario> Scenarios)
{
    public IReadOnlyList<string> ToArguments() =>
    [
        "--output", OutputRoot,
        "--files", FileCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
        "--bytes", BytesPerFile.ToString(System.Globalization.CultureInfo.InvariantCulture),
        "--operations", OperationsPerKind.ToString(System.Globalization.CultureInfo.InvariantCulture),
        "--seed", Seed.ToString(System.Globalization.CultureInfo.InvariantCulture),
        "--compressible", Compressible.ToString(),
    ];

    public static ProfileSettings Parse(string[] args)
    {
        var output = Path.GetFullPath("artifacts/profile");
        var files = 2_000;
        var size = 4 * 1024;
        var operations = 20;
        var seed = 1729;
        var compressible = false;
        for (var index = 0; index < args.Length; index += 2)
        {
            if (index + 1 >= args.Length)
            {
                throw new ArgumentException($"Option '{args[index]}' requires a value.");
            }

            var value = args[index + 1];
            switch (args[index])
            {
                case "--output": output = Path.GetFullPath(value); break;
                case "--files": files = int.Parse(value, System.Globalization.CultureInfo.InvariantCulture); break;
                case "--bytes": size = int.Parse(value, System.Globalization.CultureInfo.InvariantCulture); break;
                case "--operations": operations = int.Parse(value, System.Globalization.CultureInfo.InvariantCulture); break;
                case "--seed": seed = int.Parse(value, System.Globalization.CultureInfo.InvariantCulture); break;
                case "--compressible": compressible = bool.Parse(value); break;
                default: throw new ArgumentException($"Unknown option '{args[index]}'.");
            }
        }

        return new ProfileSettings(
            output,
            seed,
            files,
            size,
            compressible,
            operations,
            [
                new("none-off", ChecksumAlgorithm.None, CompressionAlgorithm.None, TelemetryMode.Off),
                new("xxhash-brotli-off", ChecksumAlgorithm.XxHash64, CompressionAlgorithm.Brotli, TelemetryMode.Off),
                new("xxhash-brotli-metadata-only", ChecksumAlgorithm.XxHash64,
                    CompressionAlgorithm.Brotli, TelemetryMode.Off, VerifyStagedCopies: false),
                new("xxhash-brotli-raw", ChecksumAlgorithm.XxHash64, CompressionAlgorithm.Brotli, TelemetryMode.Raw),
                new("sha256-brotli-off", ChecksumAlgorithm.Sha256, CompressionAlgorithm.Brotli, TelemetryMode.Off),
            ]);
    }
}

internal sealed record WorkerOptions(
    string? Scenario,
    string? OutputPath,
    string[] ProfileArguments)
{
    public static WorkerOptions Extract(string[] args)
    {
        string? scenario = null;
        string? outputPath = null;
        var profileArguments = new List<string>();
        for (var index = 0; index < args.Length; index += 2)
        {
            if (index + 1 >= args.Length)
            {
                throw new ArgumentException($"Option '{args[index]}' requires a value.");
            }

            if (args[index] == "--worker-scenario")
            {
                scenario = args[index + 1];
            }
            else if (args[index] == "--worker-output")
            {
                outputPath = Path.GetFullPath(args[index + 1]);
            }
            else
            {
                profileArguments.Add(args[index]);
                profileArguments.Add(args[index + 1]);
            }
        }

        return new WorkerOptions(scenario, outputPath, profileArguments.ToArray());
    }
}
