using System.Diagnostics;
using System.IO.Compression;
using Microsoft.Data.Sqlite;
using PzTools.Backup.Core;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class ProcessPipelineIntegrationTests
{
    [PublishedToolsOnlyFact]
    public async Task ScheduledRunnerPreservesDueTimeEvenWithGameSavingDisabled()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        await File.WriteAllTextAsync(Path.Combine(source, "map.bin"), "scheduled disk capture");
        var repositoryPath = temp.GetPath("repository");
        var due = DateTimeOffset.UtcNow.AddSeconds(5);
        var result = await RunProcessAsync(Path.Combine(tools, "PzTools.Backup.Runner.exe"),
        [
            "--repository", repositoryPath, "--source-id", "test", "--source", $"test={source}",
            "--worker-directory", tools, "--control-db", temp.GetPath("control.db"),
            "--save-game", "--save-game-before-backup", "false",
            "--scheduled-utc", due.ToString("O", System.Globalization.CultureInfo.InvariantCulture),
        ]);
        Assert.True(result.ExitCode == 0, result.StandardOutput + result.StandardError);
        var envelope = ProcessResultJson.Deserialize<RunnerExecutionResult>(result.StandardOutput);
        var telemetry = await PzTools.Backup.Storage.Telemetry.TelemetryStore.CreateOrOpenAsync(repositoryPath);
        var events = await telemetry.ReadEventsAsync(envelope.RunIndex);
        var prepared = Assert.Single(events, item => item.Name == "source.prepare.completed");
        Assert.True(prepared.TimestampUtc >= due);
        Assert.Contains(events, item => item.Name == "run.committed");
    }

    [PublishedToolsOnlyFact]
    public async Task PublishedBackupRunner_PreservesSchedulerOriginAcrossProcessBoundary()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "map.bin"), "automatic snapshot");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var workflow = await repository.ReserveWorkflowAsync("backup-maintenance", null, "backup-scheduler");
        var configuration = temp.GetPath("backup.toml");
        await File.WriteAllTextAsync(configuration, "format_version = 1\n[telemetry]\nmode = \"off\"\n");
        var result = await RunProcessAsync(Path.Combine(tools, "PzTools.Backup.Runner.exe"),
            ["--repository", repository.RepositoryPath, "--source-id", "main",
                "--source", $"main={sourcePath}", "--run-index", workflow.RunIndex.ToString(),
                "--worker-directory", tools, "--worker-config", configuration,
                "--name-language", "English", "--control-db", temp.GetPath("control.db")]);
        Assert.True(result.ExitCode == 0, result.StandardError + result.StandardOutput);
        var revision = Assert.Single(Assert.Single((await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions);
        Assert.Equal(BackupKind.Automatic, revision.Kind);
        Assert.Equal("Automatic backup 1", revision.DisplayName);
    }

    [PublishedToolsOnlyFact]
    public async Task RunnerCoordinator_PropagatesChildFailureCodeAndMessage()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var missingArchive = temp.GetPath("missing.zip");
        var envelope = await new OneShotRunnerCoordinator().RunAsync(
            "archive-test-runner", "ArchiveInspect", temp.GetPath("identity"), 7,
            Path.Combine(tools, "PzTools.Zomboid.Archive.Cli.exe"),
            ["inspect", "--archive", missingArchive, "--run-index", "7",
                "--telemetry-identity", temp.GetPath("identity")], "archive-worker");

        Assert.Equal(ProcessOutcome.Failed, envelope.Outcome);
        Assert.Equal("archive-failed", envelope.Error?.Code);
        Assert.Contains("missing.zip", envelope.Error?.Message);
    }

    [PublishedToolsFact]
    public async Task PublishedStateRunner_ExecutesReactorCollectorReactorPipeline()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var saves = Environment.GetEnvironmentVariable("PZTOOLS_REAL_SAVES_ROOT")!;
        var statePath = temp.GetPath("state.db");
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(tools, "PzTools.State.Runner.exe"),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in new[]
        {
            "--state-db", statePath,
            "--saves-root", saves,
            "--run-index", "1",
            "--worker-directory", tools,
        })
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = System.Diagnostics.Process.Start(startInfo)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == 0, await error);
        var envelope = ProcessResultJson.Deserialize<RunnerExecutionResult>(await output);
        Assert.Equal(ProcessOutcome.Succeeded, envelope.Outcome);
        var snapshot = await (await StateDatabase.CreateOrOpenAsync(statePath))
            .ReadCurrentStateIfChangedAsync(-1);
        Assert.NotEmpty(snapshot.Saves);
    }

    [PublishedToolsOnlyFact]
    public async Task DirectBackupRunner_AllocatesRunAndBindsConfiguredSource()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var repositoryPath = temp.GetPath("repository");
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "map.bin"), "first snapshot");

        var configurationDirectory = Path.Combine(
            repositoryPath, ".pztools", "backup-worker");
        Directory.CreateDirectory(configurationDirectory);
        await File.WriteAllTextAsync(
            Path.Combine(configurationDirectory, "default.toml"),
            $$"""
            format_version = 1

            [[sources]]
            id = "main"
            path = "{{sourcePath.Replace('\\', '/')}}"

            [storage]
            checksum = "none"
            compression = "none"
            content_deduplication = false

            [telemetry]
            mode = "off"
            """);
        var runnerConfiguration = temp.GetPath("backup-runner.toml");
        await File.WriteAllTextAsync(
            runnerConfiguration,
            "[telemetry]\nenabled = false\n");

        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(tools, "PzTools.Backup.Runner.exe"),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in new[]
        {
            "--repository", repositoryPath,
            "--source-id", "main",
            "--worker-directory", tools,
            "--config", runnerConfiguration,
            "--worker-config", Path.Combine(configurationDirectory, "default.toml"),
            "--control-db", temp.GetPath("control.db"),
        })
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = System.Diagnostics.Process.Start(startInfo)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        Assert.True(process.ExitCode == ProcessExitCodes.Success, await error);
        var envelope = ProcessResultJson.Deserialize<RunnerExecutionResult>(await output);
        Assert.True(envelope.RunIndex > 1);
        Assert.Equal(ProcessOutcome.Succeeded, envelope.Outcome);

        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var workflow = await repository.ReadWorkflowAsync(envelope.RunIndex);
        Assert.Equal(WorkflowStatus.Succeeded, workflow.Status);
        Assert.NotNull(workflow.SourceId);
        var source = await repository.GetSourceAsync("main");
        Assert.Equal(source.SourceId, workflow.SourceId);
        Assert.Contains(
            await repository.ReadRevisionEntriesAsync(source.SourceId, 1),
            entry => entry.RelativePath == "map.bin");
        Assert.False(File.Exists(Path.Combine(
            ComponentRuntimePaths.GetComponentDirectory(repositoryPath, "backup-runner"),
            "telemetry.db")));
    }

    [PublishedToolsOnlyFact]
    public async Task DirectMaintenanceRunner_AllocatesRunBeforeBusyMutexResult()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var repositoryPath = temp.GetPath("repository");
        var repository = await RepositoryDatabase.CreateOrOpenAsync(repositoryPath);
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repositoryPath))
        {
            sourceId = (await repository.AddOrGetSourceAsync(
                lease, "main", temp.GetPath("source"))).SourceId;
        }

        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var mutexName = NamedMutexRunner.CreateName(
            "RepositoryAccess", Path.GetFullPath(repositoryPath));
        var holder = NamedMutexRunner.TryRunAsync(mutexName, async _ =>
        {
            entered.SetResult();
            await release.Task;
            return 0;
        });
        await entered.Task;

        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(tools, "PzTools.Maintenance.Runner.exe"),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in new[]
        {
            "--repository", repositoryPath,
            "--source-id", sourceId.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--worker-directory", tools,
            "--control-db", temp.GetPath("control.db"),
        })
        {
            startInfo.ArgumentList.Add(argument);
        }

        try
        {
            using var process = System.Diagnostics.Process.Start(startInfo)!;
            var output = process.StandardOutput.ReadToEndAsync();
            var error = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            Assert.True(process.ExitCode == ProcessExitCodes.Busy, await error);
            var envelope = ProcessResultJson.Deserialize<RunnerExecutionResult>(await output);
            Assert.True(envelope.RunIndex > 1);
            Assert.Equal(ProcessOutcome.Busy, envelope.Outcome);
            Assert.Equal(WorkflowStatus.Busy,
                (await repository.ReadWorkflowAsync(envelope.RunIndex)).Status);
        }
        finally
        {
            release.SetResult();
            await holder;
        }
    }

    [PublishedToolsOnlyFact]
    public async Task MaintenanceLane_DispatchesChildWithoutWaitingForIt()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var sourcePath = temp.GetPath("source");
        Directory.CreateDirectory(sourcePath);
        long sourceId;
        await using (var lease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
            sourceId = (await repository.AddOrGetSourceAsync(
                lease, "Sandbox/Save", sourcePath)).SourceId;
        await repository.ReserveWorkflowAsync(
            "backup-maintenance", sourceId, "backup-scheduler", null, 42);
        var adapter = new RunnerProcessAdapter(tools, temp.GetPath("control.db"));
        // 자식이 저장소 쓰기 잠금을 기다려도 레인 판정은 종료를 기다리지 않아야 합니다.
        await using (var heldLease = RepositoryWriterLease.Acquire(repository.RepositoryPath))
        {
            var dispatch = await adapter.RunMaintenanceAsync(
                repository.RepositoryPath,
                new BackupTarget("Sandbox/Save", "Sandbox/Save", sourcePath),
                sourceId, 42, CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(10));
            Assert.True(dispatch.Started);
            Assert.Equal(ProcessOutcome.Succeeded, dispatch.Outcome);
            var startingDeadline = DateTimeOffset.UtcNow.AddSeconds(5);
            while (DateTimeOffset.UtcNow < startingDeadline
                   && !await MaintenanceLaneSignal.IsRunningAsync(
                       repository.RepositoryPath, "ArtifactCleanup"))
                await Task.Delay(50);
            Assert.True(await MaintenanceLaneSignal.IsRunningAsync(
                repository.RepositoryPath, "ArtifactCleanup"));
        }
        var deadline = DateTimeOffset.UtcNow.AddSeconds(15);
        (long RunIndex, string Pipeline, string Status)? workflow = null;
        while (DateTimeOffset.UtcNow < deadline)
        {
            await using var connection = new SqliteConnection(
                $"Data Source={repository.DatabasePath};Mode=ReadOnly;Pooling=False");
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText =
                "SELECT run_index,pipeline,status FROM workflow_runs "
                + "WHERE owner_component='maintenance-lane-ArtifactCleanup' ORDER BY run_index DESC LIMIT 1;";
            await using var reader = await command.ExecuteReaderAsync();
            if (await reader.ReadAsync())
                workflow = (reader.GetInt64(0), reader.GetString(1), reader.GetString(2));
            if (workflow?.Status == WorkflowStatus.Succeeded.ToString()) break;
            await Task.Delay(50);
        }

        Assert.NotNull(workflow);
        Assert.Equal("maintenance-lane", workflow.Value.Pipeline);
        Assert.Equal(WorkflowStatus.Succeeded.ToString(), workflow.Value.Status);
        Assert.NotEqual(42, workflow.Value.RunIndex);
        while (DateTimeOffset.UtcNow < deadline)
        {
            var probe = await NamedMutexRunner.TryRunAsync(
                MaintenanceLaneSignal.MutexName(repository.RepositoryPath, "ArtifactCleanup"),
                _ => Task.FromResult(true));
            if (probe.Acquired) return;
            await Task.Delay(50);
        }
        Assert.Fail("The dispatched maintenance process did not exit.");
    }

    [PublishedToolsOnlyFact]
    public async Task PublishedArchiveCli_ExportsInspectsAndImportsRevision()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var sourcePath = temp.GetPath("source");
        var repositoryPath = temp.GetPath("repository");
        Directory.CreateDirectory(sourcePath);
        await File.WriteAllTextAsync(Path.Combine(sourcePath, "players.db"), "player");
        await File.WriteAllBytesAsync(Path.Combine(sourcePath, "thumb.png"),
            [137, 80, 78, 71, 13, 10, 26, 10, 1]);
        var configurationDirectory = Path.Combine(
            repositoryPath, ".pztools", "backup-worker");
        Directory.CreateDirectory(configurationDirectory);
        await File.WriteAllTextAsync(
            Path.Combine(configurationDirectory, "default.toml"),
            "format_version = 1\n\n[capture]\nalways_include = [\"players.db\", \"thumb.png\"]\n\n"
            + "[storage]\nchecksum = \"none\"\ncompression = \"none\"\n"
            + "content_deduplication = false\n\n[telemetry]\nmode = \"off\"\n"
            + "\n[naming]\nlanguage = \"English\"\n");

        var backup = await RunProcessAsync(
            Path.Combine(tools, "PzTools.Backup.Runner.exe"),
            [
                "--repository", repositoryPath,
                "--source-id", "Sandbox/ArchiveSave",
                "--source", $"Sandbox/ArchiveSave={sourcePath}",
                "--worker-directory", tools,
                "--worker-config", Path.Combine(configurationDirectory, "default.toml"),
                "--name-language", "English",
                "--control-db", temp.GetPath("control.db"),
            ]);
        Assert.True(backup.ExitCode == 0,
            $"stderr: {backup.StandardError}{Environment.NewLine}stdout: {backup.StandardOutput}");
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var source = await repository.GetSourceAsync("Sandbox/ArchiveSave");
        Assert.Equal("Manual backup 1", Assert.Single(Assert.Single(
            (await repository.ReadCatalogIfChangedAsync(-1)).Sources).Revisions).DisplayName);
        var revision = (await repository.GetSourceStateAsync(source.SourceId)).CurrentRevision;
        var archivePath = temp.GetPath("save.zip");

        var exported = await RunProcessAsync(
            Path.Combine(tools, "PzTools.Zomboid.Archive.Cli.exe"),
            [
                "export", "--repository", repositoryPath,
                "--source-id", source.SourceId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--revision", revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--output", archivePath,
                "--run-index", "12",
            ]);
        Assert.Equal(0, exported.ExitCode);
        using (var zip = ZipFile.OpenRead(archivePath))
        {
            Assert.NotNull(zip.GetEntry("Sandbox/ArchiveSave/players.db"));
            Assert.NotNull(zip.GetEntry("Sandbox/ArchiveSave/pztools-manifest.json"));
            Assert.Null(zip.GetEntry("players.db"));
        }
        var inspected = await RunProcessAsync(
            Path.Combine(tools, "PzTools.Zomboid.Archive.Cli.exe"),
            ["inspect", "--archive", archivePath, "--run-index", "13"]);
        var savesRoot = temp.GetPath("Saves");
        var imported = await RunProcessAsync(
            Path.Combine(tools, "PzTools.Zomboid.Archive.Cli.exe"),
            [
                "import", "--archive", archivePath,
                "--saves-root", savesRoot,
                "--run-index", "14",
            ]);

        Assert.True(exported.ExitCode == 0, exported.StandardError);
        Assert.True(inspected.ExitCode == 0, inspected.StandardError);
        Assert.True(imported.ExitCode == 0, imported.StandardError);
        Assert.Equal("player", await File.ReadAllTextAsync(
            Path.Combine(savesRoot, "Sandbox", "ArchiveSave", "players.db")));
        Assert.Equal(ProcessOutcome.Succeeded,
            ProcessResultJson.Deserialize<object>(exported.StandardOutput).Outcome);
        Assert.Equal(ProcessOutcome.Succeeded,
            ProcessResultJson.Deserialize<object>(inspected.StandardOutput).Outcome);
        Assert.Equal(ProcessOutcome.Succeeded,
            ProcessResultJson.Deserialize<object>(imported.StandardOutput).Outcome);
    }

    [PublishedToolsOnlyFact]
    public async Task GameSaveDisabled_SkipsPreparationAndStillCreatesBackupThroughRunner()
    {
        using var temp = new TempDirectory();
        var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR")!;
        var source = temp.GetPath("source");
        Directory.CreateDirectory(source);
        await File.WriteAllTextAsync(Path.Combine(source, "map.bin"), "disk state only");
        var config = temp.GetPath("worker.toml");
        await File.WriteAllTextAsync(config, "format_version = 1\n[telemetry]\nmode = 'phase'\n");
        var runnerConfig = temp.GetPath("runner.toml");
        await File.WriteAllTextAsync(runnerConfig, "[telemetry]\nenabled = false\n");
        var repositoryPath = temp.GetPath("repository");
        var result = await RunProcessAsync(Path.Combine(tools, "PzTools.Backup.Runner.exe"),
        [
            "--repository", repositoryPath, "--source-id", "test", "--source", $"test={source}",
            "--worker-directory", tools, "--worker-config", config, "--config", runnerConfig,
            "--control-db", temp.GetPath("control.db"), "--save-game", "--save-game-before-backup", "false",
        ]);
        Assert.True(result.ExitCode == 0, result.StandardOutput + result.StandardError);
        var envelope = ProcessResultJson.Deserialize<RunnerExecutionResult>(result.StandardOutput);
        Assert.Equal(ProcessOutcome.Succeeded, envelope.Outcome);
        var telemetry = await PzTools.Backup.Storage.Telemetry.TelemetryStore.CreateOrOpenAsync(repositoryPath);
        var events = await telemetry.ReadEventsAsync(envelope.RunIndex);
        Assert.DoesNotContain(events, item => item.Name.StartsWith("source.prepare", StringComparison.Ordinal));
        Assert.Contains(events, item => item.Name == "run.committed");
        var repository = await RepositoryDatabase.OpenExistingAsync(repositoryPath);
        var storedSource = await repository.GetSourceAsync("test");
        var restored = temp.GetPath("restored");
        await new PzTools.Backup.Engine.RevisionRestorer().RestoreAsync(repository, storedSource.SourceId, 1, restored);
        Assert.Equal("disk state only", await File.ReadAllTextAsync(Path.Combine(restored, "map.bin")));
    }

    private static async Task<ProcessOutput> RunProcessAsync(
        string executable,
        IReadOnlyList<string> arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        using var process = System.Diagnostics.Process.Start(startInfo)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        return new ProcessOutput(process.ExitCode, await output, await error);
    }

    private sealed record ProcessOutput(
        int ExitCode,
        string StandardOutput,
        string StandardError);

    private sealed class PublishedToolsFactAttribute : FactAttribute
    {
        public PublishedToolsFactAttribute()
        {
            var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR");
            var saves = Environment.GetEnvironmentVariable("PZTOOLS_REAL_SAVES_ROOT");
            if (string.IsNullOrWhiteSpace(tools)
                || !File.Exists(Path.Combine(tools, "PzTools.State.Runner.exe"))
                || string.IsNullOrWhiteSpace(saves)
                || !Directory.Exists(saves))
            {
                Skip = "Set PZTOOLS_TOOLS_DIR and PZTOOLS_REAL_SAVES_ROOT for process E2E.";
            }
        }
    }

    private sealed class PublishedToolsOnlyFactAttribute : FactAttribute
    {
        public PublishedToolsOnlyFactAttribute()
        {
            var tools = Environment.GetEnvironmentVariable("PZTOOLS_TOOLS_DIR");
            if (string.IsNullOrWhiteSpace(tools)
                || !File.Exists(Path.Combine(tools, "PzTools.Backup.Runner.exe"))
                || !File.Exists(Path.Combine(tools, "PzTools.Maintenance.Runner.exe")))
            {
                Skip = "Set PZTOOLS_TOOLS_DIR for process E2E.";
            }
        }
    }
}
