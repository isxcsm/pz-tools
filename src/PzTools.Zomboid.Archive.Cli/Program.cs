using System.Globalization;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Zomboid.Archive;

// Launch check only: proves Windows allows this executable to start. No work, no output.
if (args is ["--probe"]) return 0;

return await RunAsync(args);

static async Task<int> RunAsync(string[] args)
{
    using var cancellation = new CancellationTokenSource();
    Console.CancelKeyPress += (_, eventArgs) =>
    {
        eventArgs.Cancel = true;
        cancellation.Cancel();
    };
    var started = DateTimeOffset.UtcNow;
    var runIndex = 1L;
    var operation = args.Length == 0 ? "unknown" : args[0];
    string? diagnosticPath = null;
    string? currentRelativePath = null;
    string? saveId = null;
    ProcessTelemetrySession? telemetry = null;
    try
    {
        if (args.Length == 0 || args[0] is "help" or "--help" or "-h")
            return Help();
        runIndex = ReadInt64(args, "--run-index")
            ?? await new RunIndexAllocator(Optional(args, "--control-db"))
                .AllocateAsync(cancellationToken: cancellation.Token);
        object result;
        var identity = operation switch
        {
            "inspect" => Required(args, "--archive"),
            "export" => Required(args, "--repository"),
            "export-live" => Required(args, "--source"),
            "import" => Required(args, "--saves-root"),
            _ => throw new ArgumentException($"Unknown command '{operation}'."),
        };
        diagnosticPath = operation is "inspect" or "import"
            ? Path.GetFileName(Required(args, "--archive"))
            : Path.GetFileName(Required(args, "--output"));
        if (operation == "export-live") saveId = Required(args, "--save-id");
        var telemetryIdentity = Optional(args, "--telemetry-identity")
            ?? PzToolsPathLayout.CreateDefault().CreateOperationIdentity(
                "archive-worker", $"archive-{operation}-{runIndex}");
        var configurationPath = Optional(args, "--config");
        var configuration = ComponentConfiguration.Load(
            telemetryIdentity, "archive-worker", configurationPath);
        var settings = ArchiveWorkerOptions.Read(configuration);
        var service = new ZomboidArchiveService(
            settings.PlayersDatabaseMib * 1024L * 1024, settings.ThumbnailMib * 1024L * 1024);
        var safety = new ArchiveSafetyOptions(
            MaximumEntries: settings.MaximumEntries,
            MaximumSingleFileBytes: settings.MaximumSingleFileBytes,
            MinimumFreeSpaceReserveBytes: settings.MinimumFreeSpaceReserveBytes,
            MinimumFreeSpaceReservePercent: settings.MinimumFreeSpaceReservePercent);
        safety.Validate();
        telemetry = await ProcessTelemetrySession.StartAsync(
            telemetryIdentity, "archive-worker", runIndex, configurationPath);
        telemetry.RecordEvent("run.started");
        await using var heartbeat = ProcessTelemetryHeartbeat.Start(telemetry);
        switch (args[0])
        {
            case "inspect":
                result = await service.InspectAsync(identity, cancellation.Token, safety);
                break;
            case "export":
            case "export-live":
                {
                    var live = operation == "export-live";
                    Task ReportAsync(ArchiveProgress value, CancellationToken _)
                    {
                        currentRelativePath = value.RelativePath;
                        telemetry.SetProgress(value.Phase, value.CompletedItems,
                            value.TotalItems, value.CompletedBytes, value.TotalBytes,
                            value.RelativePath);
                        return Task.CompletedTask;
                    }
                    async Task<ArchiveExportResult> ExportRevisionAsync(CancellationToken token)
                    {
                        // Background cleanup rewrites and removes packs under the writer lease. Hold it
                        // while the revision is read, as a restore does, so no pack moves underneath.
                        await using var lease = RepositoryWriterLease.Acquire(identity);
                        return await service.ExportAsync(
                            await RepositoryDatabase.OpenExistingAsync(identity, token),
                            RequiredInt64(args, "--source-id"), RequiredInt64(args, "--revision"),
                            Required(args, "--output"), ReportAsync, token);
                    }
                    var locked = await OperationMutexSet.TryRunAsync(
                        [new OperationMutexRequest(live ? OperationMutexScope.SaveWrite : OperationMutexScope.RepositoryAccess, identity)],
                        async token => live
                            ? await service.ExportLiveAsync(identity, Required(args, "--save-id"),
                                Required(args, "--output"), ReportAsync, token)
                            : await ExportRevisionAsync(token),
                        cancellation.Token);
                    if (!locked.Acquired)
                    {
                        telemetry.RecordEvent("run.busy");
                        return Busy(runIndex, started);
                    }
                    result = locked.Value!;
                    break;
                }
            case "import":
                {
                    var savesRoot = Required(args, "--saves-root");
                    Task ReportAsync(ArchiveProgress value, CancellationToken _)
                    {
                        currentRelativePath = value.RelativePath;
                        telemetry.SetProgress(value.Phase, value.CompletedItems,
                            value.TotalItems, value.CompletedBytes, value.TotalBytes,
                            value.RelativePath);
                        return Task.CompletedTask;
                    }
                    var locked = await OperationMutexSet.TryRunAsync(
                        [new OperationMutexRequest(OperationMutexScope.SaveWrite, savesRoot)],
                        token => service.ImportAsync(
                            Required(args, "--archive"), savesRoot, ReportAsync, token, safety),
                        cancellation.Token);
                    if (!locked.Acquired)
                    {
                        telemetry.RecordEvent("run.busy");
                        return Busy(runIndex, started);
                    }
                    result = locked.Value!;
                    break;
                }
            default:
                throw new InvalidOperationException("Unreachable archive command.");
        }

        telemetry.RecordEvent("run.committed",
            System.Text.Json.JsonSerializer.Serialize(new { operation }));
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Success(
                "archive-worker", runIndex, ProcessOutcome.Succeeded, started, result)));
        return ProcessExitCodes.Success;
    }
    catch (RepositoryBusyException)
    {
        // Cleanup or a backup holds the repository; the export can simply be tried again.
        telemetry?.RecordEvent("run.busy");
        return Busy(runIndex, started);
    }
    catch (OperationCanceledException)
    {
        telemetry?.RecordEvent("run.cancelled");
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Failure(
                "archive-worker", runIndex, ProcessOutcome.Cancelled, started,
                "cancelled", "Archive operation was cancelled.")));
        return ProcessExitCodes.Cancelled;
    }
    catch (Exception exception) when (exception is ArgumentException or FormatException)
    {
        telemetry?.RecordEvent("run.failed", FailureTelemetry.FromException(
            "invalid-arguments", exception, status: "Failed",
            phase: operation, path: currentRelativePath ?? diagnosticPath,
            operation: operation, saveId: saveId));
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Failure(
                "archive-worker", Math.Max(1, runIndex), ProcessOutcome.Failed, started,
                "invalid-arguments", exception.Message)));
        return ProcessExitCodes.InvalidArguments;
    }
    catch (Exception exception) when (IsDamagedBackupData(exception))
    {
        // Exporting a backup whose stored data fails its integrity checks.
        telemetry?.RecordEvent("run.failed", FailureTelemetry.FromException(
            "backup-data-damaged", exception, status: "Failed",
            phase: operation, path: currentRelativePath ?? diagnosticPath,
            operation: operation, saveId: saveId));
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Failure(
                "archive-worker", runIndex, ProcessOutcome.Failed, started,
                "backup-data-damaged", "backup-data-damaged: " + exception.Message)));
        return ProcessExitCodes.Failure;
    }
    catch (Exception exception)
    {
        telemetry?.RecordEvent("run.failed", FailureTelemetry.FromException(
            "archive-failed", exception, status: "Failed",
            phase: operation, path: currentRelativePath ?? diagnosticPath,
            operation: operation, saveId: saveId));
        Console.WriteLine(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Failure(
                "archive-worker", runIndex, ProcessOutcome.Failed, started,
                "archive-failed", exception.Message)));
        return ProcessExitCodes.Failure;
    }
    finally
    {
        if (telemetry is not null) await telemetry.DisposeAsync();
    }
}

static bool IsDamagedBackupData(Exception? exception)
{
    for (; exception is not null; exception = exception.InnerException)
        if (exception is PzTools.Backup.Storage.Packs.PackFormatException) return true;
    return false;
}

static int Busy(long runIndex, DateTimeOffset started)
{
    Console.WriteLine(ProcessResultJson.Serialize(
        ProcessResultEnvelope<object>.Success(
            "archive-worker", runIndex, ProcessOutcome.Busy, started)));
    return ProcessExitCodes.Busy;
}

static int Help()
{
    Console.WriteLine("PzTools Zomboid archive");
    Console.WriteLine("  inspect --archive <file> [--run-index <n>] [--control-db <path>]");
    Console.WriteLine("  export --repository <path> --source-id <id> --revision <n> --output <file> [--run-index <n>] [--control-db <path>]");
    Console.WriteLine("  export-live --source <save-directory> --save-id <mode/name> --output <file> [--run-index <n>] [--control-db <path>]");
    Console.WriteLine("  import --archive <file> --saves-root <path> [--run-index <n>] [--control-db <path>]");
    return 0;
}

static string Required(string[] args, string name)
{
    var indexes = args.Select((value, index) => (value, index))
        .Where(item => item.value == name).Select(item => item.index).ToArray();
    if (indexes.Length != 1 || indexes[0] + 1 >= args.Length)
        throw new ArgumentException($"{name} is required exactly once.");
    return args[indexes[0] + 1];
}

static string? Optional(string[] args, string name)
{
    var indexes = args.Select((value, index) => (value, index))
        .Where(item => item.value == name).Select(item => item.index).ToArray();
    if (indexes.Length > 1 || indexes.Length == 1 && indexes[0] + 1 >= args.Length)
        throw new ArgumentException($"{name} may be specified at most once and requires a value.");
    return indexes.Length == 0 ? null : args[indexes[0] + 1];
}

static long RequiredInt64(string[] args, string name) =>
    ReadInt64(args, name) ?? throw new ArgumentException($"{name} is required.");

static long? ReadInt64(string[] args, string name)
{
    var index = Array.IndexOf(args, name);
    if (index < 0) return null;
    if (index + 1 >= args.Length
        || !long.TryParse(args[index + 1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var value)
        || value <= 0)
        throw new ArgumentException($"{name} must be a positive integer.");
    return value;
}
