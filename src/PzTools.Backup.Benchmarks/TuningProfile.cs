using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Benchmarks;

/// <summary>Opt-in, synthetic-only tuning runs; the original profile command is unchanged.</summary>
internal static class TuningProfile
{
    private const string FixtureFormat = "pztools-tuning-fixture-v1";
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public static async Task<int> RunAsync(string[] args)
    {
        var generate = args[0] == "--tune-generate";
        var values = ParseArguments(args[1..], generate
            ? ["--output", "--workload"]
            : ["--output", "--config", "--source", "--scenario", "--seed-repository"]);
        var output = FullPath(Required(values, "--output"));
        RequireFreshDirectory(output);
        if (generate)
            await GenerateAsync(output, Required(values, "--workload"));
        else
            await MeasureAsync(output, values);
        return 0;
    }

    private static async Task GenerateAsync(string output, string workload)
    {
        var files = WorkloadFiles(workload).ToArray();
        Directory.CreateDirectory(output);
        var source = Path.Combine(output, "source");
        Directory.CreateDirectory(source);
        const int seed = 1729;
        var random = new Random(seed);
        var buffer = new byte[128 * 1024];
        for (var index = 0; index < files.Length; index++)
        {
            var file = files[index];
            var path = Path.Combine(source, file.RelativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            await using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, bufferSize: buffer.Length, FileOptions.Asynchronous | FileOptions.SequentialScan);
            for (long offset = 0; offset < file.Bytes;)
            {
                var count = (int)Math.Min(buffer.Length, file.Bytes - offset);
                switch (index % 3)
                {
                    case 0: Array.Fill(buffer, (byte)(index % 251), 0, count); break;
                    case 1:
                        for (var b = 0; b < count; b++) buffer[b] = (byte)((offset + b + index * 13L) % 251);
                        break;
                    default: random.NextBytes(buffer.AsSpan(0, count)); break;
                }
                await stream.WriteAsync(buffer.AsMemory(0, count));
                offset += count;
            }
        }
        var fixture = new Fixture(FixtureFormat, Guid.NewGuid().ToString("N"), workload, seed,
            source, files.Length, files.Sum(file => file.Bytes));
        await File.WriteAllTextAsync(Path.Combine(output, "fixture.json"), JsonSerializer.Serialize(fixture, Json));
        Console.WriteLine(JsonSerializer.Serialize(fixture, Json));
    }

    private static async Task MeasureAsync(string output, Dictionary<string, string> values)
    {
        var scenario = values.GetValueOrDefault("--scenario") ?? "initial";
        if (scenario is not ("initial" or "fallback"))
            throw new ArgumentException("--scenario must be initial or fallback.");
        var source = FullPath(Required(values, "--source"));
        var fixture = await ValidateFixtureAsync(source);
        RequireDisjoint(output, source);
        var configPath = FullPath(Required(values, "--config"));
        RejectReparseAncestors(configPath);
        var configText = await File.ReadAllTextAsync(configPath);
        var repositoryPath = Path.Combine(output, "repository");
        // Parse the real production configuration while pinning the experiment's safety/integrity policy.
        var options = BackupConfiguration.Parse(configText, repositoryPath, configPath,
            new BackupOptionOverrides
            {
                Sources = [new("tune", source)],
                Checksum = ChecksumAlgorithm.XxHash64,
                Compression = CompressionAlgorithm.Brotli,
                ContentDeduplication = false,
                VerifyStagedCopies = true,
                FullScanHashComparison = true,
                SaveGameBeforeBackup = false,
                AlwaysIncludePaths = [],
                TelemetryEnabled = true,
                TelemetryMode = TelemetryMode.Phase,
            }) with { GameSaveCountdown = false };
        BackupConfiguration.Validate(options);
        if (scenario == "fallback")
        {
            var seed = FullPath(Required(values, "--seed-repository"));
            RequireDisjoint(output, seed);
            RequireDisjoint(source, seed);
            await ValidateSeedAsync(seed, source, fixture);
            Directory.CreateDirectory(output);
            CopySeed(seed, repositoryPath);
        }
        else
        {
            if (values.ContainsKey("--seed-repository"))
                throw new ArgumentException("--seed-repository is only valid with --scenario fallback.");
            Directory.CreateDirectory(output);
        }

        using var process = System.Diagnostics.Process.GetCurrentProcess();
        GC.Collect();
        GC.WaitForPendingFinalizers();
        var allocatedBefore = GC.GetTotalAllocatedBytes(precise: true);
        var cpuBefore = process.TotalProcessorTime;
        var clock = Stopwatch.StartNew();
        var result = await new OneShotBackupService(new ProfileJournal(scenario == "fallback"))
            .RunAsync(options, "tune");
        clock.Stop();
        var cpuMilliseconds = (process.TotalProcessorTime - cpuBefore).TotalMilliseconds;
        var allocatedBytes = GC.GetTotalAllocatedBytes(precise: true) - allocatedBefore;
        process.Refresh();
        var peakWorkingSetBytes = process.PeakWorkingSet64;

        // Keep all validation/telemetry reads outside the measured production backup call.
        if (result.Warnings.Count != 0)
            throw new InvalidDataException("The tuning run reported warnings: " + JsonSerializer.Serialize(result.Warnings, Json));
        if (scenario == "initial" && (result.Mode != "InitialFullScan" || result.Revision != 1)
            || scenario == "fallback" && (result.Mode != "FullScan" || result.Revision is not null || result.ChangedEntries != 0))
            throw new InvalidDataException("The run did not execute the requested initial/unchanged-fallback scenario.");
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var totals = await ReadTotalsAsync(repository);
        if (totals.Objects != fixture.FileCount || totals.Hashes != fixture.FileCount || totals.Bytes != fixture.SourceBytes)
            throw new InvalidDataException("Stored object/hash/byte totals differ from the immutable synthetic fixture.");
        var telemetry = await TelemetryStore.CreateOrOpenAsync(repositoryPath);
        var events = await telemetry.ReadEventsAsync(result.RunIndex, limit: 100_000);
        double At(string name) => TimeSpan.FromTicks(events.Single(item => item.Name == name).ElapsedTicks).TotalMilliseconds;
        var scanMilliseconds = scenario == "initial" ? At("scan.completed") - At("scan.started") : 0;
        var planningMilliseconds = scenario == "fallback" ? At("changes.planned") - At("planning.started") : 0;
        var hasCapture = events.Any(item => item.Name == "capture.started");
        var captureMilliseconds = hasCapture ? At("capture.completed") - At("capture.started") : 0;
        var sealCommitMilliseconds = hasCapture
            ? At("run.committed") - At("capture.completed")
            : At("run.no_changes") - At("changes.planned");
        var report = new
        {
            format = "pztools-tuning-run-v1", createdUtc = DateTimeOffset.UtcNow,
            scenario, workload = fixture.Workload, fixtureId = fixture.FixtureId,
            sourcePath = source, repositoryPath, configPath,
            configSha256 = Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(configText))),
            effectiveRuntime = options.EffectiveTuning,
            effectiveStorage = new { checksum = "XxHash64", compression = "Brotli", contentDeduplication = false,
                verifyStagedCopies = true, recordContentHash = true },
            effectiveTelemetry = options.Telemetry,
            totalMilliseconds = clock.Elapsed.TotalMilliseconds,
            scanMilliseconds, planningMilliseconds,
            scanOrPlanningMilliseconds = scanMilliseconds + planningMilliseconds,
            captureMilliseconds, sealCommitMilliseconds, cpuMilliseconds, allocatedBytes, peakWorkingSetBytes,
            sourceFileCount = fixture.FileCount, sourceBytes = fixture.SourceBytes,
            sourceChangedEntries = result.ChangedEntries, runIndex = result.RunIndex, revision = result.Revision, mode = result.Mode,
            storedObjects = totals.Objects, recordedHashes = totals.Hashes, storedOriginalBytes = totals.Bytes,
            validationComplete = true, warnings = result.Warnings, telemetryDatabase = telemetry.DatabasePath,
            measurementNotes = "Seal/commit includes pack promotion for initial runs and checkpoint commit for unchanged fallback. "
                + "Peak working set is process-wide and includes setup; sourceChangedEntries includes directories. "
                + "Production integrity checks are enabled; no additional RepositoryVerifier pass is timed or run.",
            milestones = events.Where(item => item.Name is "scan.started" or "scan.completed" or "planning.started"
                or "changes.planned" or "capture.started" or "capture.completed" or "run.committed" or "run.no_changes")
                .Select(item => new { name = item.Name, milliseconds = TimeSpan.FromTicks(item.ElapsedTicks).TotalMilliseconds }),
        };
        var json = JsonSerializer.Serialize(report, Json);
        await File.WriteAllTextAsync(Path.Combine(output, "metrics.json"), json);
        Console.WriteLine(json);
    }

    private static async Task<Fixture> ValidateFixtureAsync(string source)
    {
        RejectReparseAncestors(source);
        if (!Directory.Exists(source) || Path.GetFileName(source) != "source")
            throw new InvalidDataException("--source must be the source directory created by --tune-generate.");
        var manifestPath = Path.Combine(Path.GetDirectoryName(source)!, "fixture.json");
        RejectReparseAncestors(manifestPath);
        var fixture = JsonSerializer.Deserialize<Fixture>(await File.ReadAllTextAsync(manifestPath), Json)
            ?? throw new InvalidDataException("Missing synthetic fixture manifest.");
        if (fixture.Format != FixtureFormat || fixture.Seed != 1729 || !Guid.TryParseExact(fixture.FixtureId, "N", out _)
            || !SamePath(fixture.SourcePath, source))
            throw new InvalidDataException("Synthetic fixture identity/path mismatch.");
        var expected = WorkloadFiles(fixture.Workload).ToDictionary(file => file.RelativePath, file => file.Bytes,
            StringComparer.OrdinalIgnoreCase);
        var actual = EnumerateFilesNoLinks(source).ToArray();
        if (actual.Length != fixture.FileCount || expected.Count != fixture.FileCount
            || expected.Values.Sum() != fixture.SourceBytes)
            throw new InvalidDataException("Synthetic fixture file totals differ from its manifest.");
        foreach (var file in actual)
        {
            if (!expected.TryGetValue(Path.GetRelativePath(source, file.FullName), out var bytes) || file.Length != bytes)
                throw new InvalidDataException("The fixture contains an unexpected or resized file.");
        }
        return fixture;
    }

    private static async Task ValidateSeedAsync(string seed, string source, Fixture fixture)
    {
        RejectReparseAncestors(seed);
        if (!Directory.Exists(seed) || Path.GetFileName(seed) != "repository")
            throw new InvalidDataException("The seed must be a completed tuning initial run's repository directory.");
        var metricsPath = Path.Combine(Path.GetDirectoryName(seed)!, "metrics.json");
        RejectReparseAncestors(metricsPath);
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(metricsPath));
        var value = document.RootElement;
        if (value.GetProperty("format").GetString() != "pztools-tuning-run-v1"
            || value.GetProperty("scenario").GetString() != "initial"
            || value.GetProperty("mode").GetString() != "InitialFullScan"
            || value.GetProperty("revision").GetInt64() != 1
            || !value.GetProperty("validationComplete").GetBoolean()
            || value.GetProperty("fixtureId").GetString() != fixture.FixtureId
            || !SamePath(value.GetProperty("sourcePath").GetString()!, source)
            || !SamePath(value.GetProperty("repositoryPath").GetString()!, seed)
            || value.GetProperty("sourceFileCount").GetInt64() != fixture.FileCount
            || value.GetProperty("sourceBytes").GetInt64() != fixture.SourceBytes)
            throw new InvalidDataException("Seed identity does not match this synthetic fixture's successful initial run.");
    }

    private static void CopySeed(string seed, string target)
    {
        // Read-only access to an existing lease file prevents a repository writer during the copy.
        using var guard = new FileStream(Path.Combine(seed, ".writer.lock"), FileMode.Open, FileAccess.Read, FileShare.Read);
        var files = EnumerateFilesNoLinks(seed).ToArray();
        Directory.CreateDirectory(target);
        foreach (var file in files)
        {
            var relative = Path.GetRelativePath(seed, file.FullName);
            if (relative == ".writer.lock") continue;
            var destination = Path.Combine(target, relative);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(file.FullName, destination, overwrite: false);
        }
    }

    private static async Task<(long Objects, long Hashes, long Bytes)> ReadTotalsAsync(RepositoryDatabase repository)
    {
        await using var connection = await repository.OpenConnectionAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*), COUNT(content_hash), COALESCE(SUM(original_length), 0) FROM stored_objects;";
        await using var reader = await command.ExecuteReaderAsync();
        await reader.ReadAsync();
        return (reader.GetInt64(0), reader.GetInt64(1), reader.GetInt64(2));
    }

    private static IEnumerable<FixtureFile> WorkloadFiles(string workload)
    {
        var count = workload switch { "small" => 6000, "mixed" => 6000, "large" => 12000,
            _ => throw new ArgumentException("--workload must be small, mixed or large.") };
        for (var index = 0; index < count; index++)
        {
            var kib = workload switch
            {
                "small" => 9,
                "large" => 64 + index * 37 % 49,
                _ => index % 20 < 16 ? 1 + index * 7 % 8
                    : index % 20 < 19 ? 32 + index * 11 % 33 : 96 + index * 13 % 33,
            };
            yield return new(Path.Combine($"d{index % 64:D2}", $"s{index % 7:D2}", $"file-{index:D7}.bin"), kib * 1024L);
        }
        if (workload == "mixed")
            for (var index = 0; index < 2; index++)
                yield return new(Path.Combine("databases", $"fixture-db-{index}.bin"), 16L * 1024 * 1024);
    }

    private static IEnumerable<FileInfo> EnumerateFilesNoLinks(string root)
    {
        var pending = new Stack<DirectoryInfo>();
        pending.Push(new DirectoryInfo(root));
        while (pending.TryPop(out var directory))
        {
            foreach (var entry in directory.EnumerateFileSystemInfos())
            {
                if ((entry.Attributes & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Synthetic fixtures and repositories cannot contain links/reparse points.");
                if (entry is DirectoryInfo child) pending.Push(child);
                else if (entry is FileInfo file) yield return file;
            }
        }
    }

    private static Dictionary<string, string> ParseArguments(string[] args, string[] allowed)
    {
        if (args.Length % 2 != 0) throw new ArgumentException("Each tuning option requires one value.");
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < args.Length; index += 2)
            if (!allowed.Contains(args[index], StringComparer.Ordinal) || !result.TryAdd(args[index], args[index + 1]))
                throw new ArgumentException($"Unknown or repeated tuning option '{args[index]}'.");
        return result;
    }

    private static string Required(Dictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value : throw new ArgumentException($"Missing required option {key}.");
    private static string FullPath(string value) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(value));
    private static bool SamePath(string first, string second) =>
        string.Equals(FullPath(first), FullPath(second), StringComparison.OrdinalIgnoreCase);
    private static void RequireFreshDirectory(string output)
    {
        RejectReparseAncestors(output);
        if (Directory.Exists(output) || File.Exists(output))
            throw new IOException("--output must be a fresh, nonexistent directory.");
    }
    private static void RequireDisjoint(string first, string second)
    {
        if (SamePath(first, second) || first.StartsWith(second + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            || second.StartsWith(first + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Output, source and seed directories must not overlap.");
    }
    private static void RejectReparseAncestors(string path)
    {
        for (string? current = path; current is not null; current = Path.GetDirectoryName(current))
            if ((Directory.Exists(current) || File.Exists(current))
                && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Tuning paths cannot contain links/reparse points.");
    }

    private sealed record Fixture(string Format, string FixtureId, string Workload, int Seed,
        string SourcePath, int FileCount, long SourceBytes);
    private sealed record FixtureFile(string RelativePath, long Bytes);
    private sealed class ProfileJournal(bool disabled) : IUsnJournalSource
    {
        public UsnJournalState Query(string sourcePath) => disabled
            ? throw new PlatformNotSupportedException("The tuning fallback intentionally disables USN.")
            : new(1, 2, 0, 100, 0);
        public IEnumerable<UsnRecord> ReadRange(string sourcePath, UsnCheckpoint checkpoint,
            long upperUsnExclusive, CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("This tuning profile never requests incremental USN records.");
    }
}
