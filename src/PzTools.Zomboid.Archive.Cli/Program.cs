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
    using var stopRequest = ProcessStopSignal.Listen(cancellation);
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
        // A misspelled option is refused, not ignored: ignored, it would silently run with a default.
        string[] common = ["--run-index", "--control-db", "--config", "--telemetry-identity"];
        var values = CommandLine.Parse(args, operation switch
        {
            "inspect" => ["--archive", .. common],
            "export" => ["--repository", "--source-id", "--revision", "--output", .. common],
            "export-live" => ["--source", "--save-id", "--output", .. common],
            "import" => ["--archive", "--saves-root", .. common],
            _ => throw new ArgumentException($"Unknown command '{operation}'."),
        }, start: 1);
        // Read first, so a failure below still answers with the caller's run number.
        var givenRunIndex = CommandLine.OptionalInt64(values.GetValueOrDefault("--run-index"), "--run-index");
        runIndex = givenRunIndex ?? runIndex;
        string Required(string name) => CommandLine.Required(values, name);
        long RequiredInt64(string name) => CommandLine.Int64(Required(name), name);
        var identity = operation switch
        {
            "inspect" => Required("--archive"),
            "export" => Required("--repository"),
            "export-live" => Required("--source"),
            _ => Required("--saves-root"),
        };
        diagnosticPath = operation is "inspect" or "import"
            ? Path.GetFileName(Required("--archive"))
            : Path.GetFileName(Required("--output"));
        if (operation == "export-live") saveId = Required("--save-id");
        var (sourceId, revision) = operation == "export"
            ? (RequiredInt64("--source-id"), RequiredInt64("--revision")) : (0, 0);
        runIndex = givenRunIndex
            ?? await new RunIndexAllocator(values.GetValueOrDefault("--control-db"))
                .AllocateAsync(cancellationToken: cancellation.Token);
        object result;
        var telemetryIdentity = values.GetValueOrDefault("--telemetry-identity")
            ?? PzToolsPathLayout.CreateDefault().CreateOperationIdentity(
                "archive-worker", $"archive-{operation}-{runIndex}");
        var configurationPath = values.GetValueOrDefault("--config");
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
                        // Opened first: a path that is not a backup folder is refused before the lease
                        // would create it and its lock file.
                        var repository = await RepositoryDatabase.OpenExistingAsync(identity, token);
                        // Background cleanup rewrites and removes packs under the writer lease. Hold it
                        // while the revision is read, as a restore does, so no pack moves underneath.
                        await using var lease = RepositoryWriterLease.Acquire(identity);
                        return await service.ExportAsync(
                            repository, sourceId, revision, Required("--output"), ReportAsync, token);
                    }
                    var locked = await OperationMutexSet.TryRunAsync(
                        [new OperationMutexRequest(live ? OperationMutexScope.SaveWrite : OperationMutexScope.RepositoryAccess, identity)],
                        async token => live
                            ? await service.ExportLiveAsync(identity, Required("--save-id"),
                                Required("--output"), ReportAsync, token)
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
                    var savesRoot = Required("--saves-root");
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
                            Required("--archive"), savesRoot, ReportAsync, token, safety),
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
    Console.WriteLine("  inspect --archive <file>");
    Console.WriteLine("  export --repository <path> --source-id <id> --revision <n> --output <file>");
    Console.WriteLine("  export-live --source <save-directory> --save-id <mode/name> --output <file>");
    Console.WriteLine("  import --archive <file> --saves-root <path>");
    Console.WriteLine("  Each also takes [--run-index <n>] [--control-db <path>] [--config <file>] [--telemetry-identity <folder>].");
    return 0;
}
