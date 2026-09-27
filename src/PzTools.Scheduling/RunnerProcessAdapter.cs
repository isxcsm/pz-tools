using System.Text.Json;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.Process.Hosting;

namespace PzTools.Scheduling;

public sealed class RunnerProcessAdapter(
    ChildProcessHost host, string workerDirectory, string? controlDatabasePath = null)
{
    public RunnerProcessAdapter(string workerDirectory, string? controlDatabasePath = null)
        : this(new ChildProcessHost(), Path.GetFullPath(workerDirectory), controlDatabasePath) { }

    public Task<WorkerInvocation> RunBackupAsync(string repositoryPath, BackupTarget target, long runIndex,
        DateTimeOffset? scheduledUtc, CancellationToken token) =>
        RunBackupAsync(repositoryPath, target, runIndex, scheduledUtc, token, null);

    public Task<WorkerInvocation> RunBackupAsync(
        string repositoryPath,
        BackupTarget target,
        long runIndex,
        DateTimeOffset? scheduledUtc,
        CancellationToken cancellationToken,
        RuntimeSaveTicket? runtimeTicket, string? runtimeAuthority = null, long? runtimeGeneration = null)
    {
        List<string> arguments =
            [
                "--repository", repositoryPath,
                "--source-id", target.SourceKey,
                "--save-game", "--require-active-game",
                "--source", $"{target.SourceKey}={target.SourcePath}",
                "--run-index", runIndex.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--worker-directory", workerDirectory,
            ];
        if (runtimeTicket is not null)
        {
            if (runtimeAuthority is null || runtimeGeneration is null) throw new InvalidOperationException("A guarded request requires its scheduling authority.");
            arguments.AddRange(["--runtime-authority", runtimeAuthority, "--runtime-generation",
                runtimeGeneration.Value.ToString(System.Globalization.CultureInfo.InvariantCulture)]);
            arguments.Add("--runtime-ticket");
            arguments.Add((runtimeTicket with { CommandSequence = runIndex }).Encode());
        }
        else if (scheduledUtc is { } due)
        {
            arguments.Add("--scheduled-utc");
            arguments.Add(due.ToString("O", System.Globalization.CultureInfo.InvariantCulture));
        }
        return RunAsync("PzTools.Backup.Runner.exe", "backup-runner", runIndex,
            arguments, cancellationToken);
    }

    public Task<WorkerInvocation> RunGuardedBackupAsync(BackupTickAdmission admission, long runIndex, CancellationToken token, string authority) =>
        RunBackupAsync(admission.RepositoryPath, admission.Target, runIndex, null, token, admission.RuntimeTicket, authority, admission.Generation);

    public Task<WorkerInvocation> RunMaintenanceAsync(
        string repositoryPath,
        BackupTarget target,
        long sourceId,
        long runIndex,
        CancellationToken cancellationToken)
    {
        if (sourceId <= 0) throw new ArgumentOutOfRangeException(nameof(sourceId));
        var arguments = new List<string>
        {
            "--repository", repositoryPath,
            "--source-id", sourceId.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--run-index", runIndex.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--worker-directory", workerDirectory,
            "--dispatch-lanes", "true",
        };
        if (!string.IsNullOrWhiteSpace(controlDatabasePath))
        {
            arguments.Add("--control-db");
            arguments.Add(Path.GetFullPath(controlDatabasePath));
        }
        return RunAsync(
            "PzTools.Maintenance.Runner.exe", "maintenance-runner",
            runIndex, arguments, cancellationToken);
    }

    public Task<WorkerInvocation> RunStateAsync(
        string stateDatabasePath, string savesRoot, long runIndex,
        CancellationToken cancellationToken)
    {
        var arguments = new List<string>
        {
            "--state-db", stateDatabasePath, "--saves-root", savesRoot,
            "--run-index", runIndex.ToString(System.Globalization.CultureInfo.InvariantCulture),
            "--worker-directory", workerDirectory,
        };
        return RunAsync(
            "PzTools.State.Runner.exe",
            "state-runner",
            runIndex,
            arguments,
            cancellationToken);
    }

    private async Task<WorkerInvocation> RunAsync(
        string executableName,
        string expectedComponent,
        long expectedRunIndex,
        IReadOnlyList<string> arguments,
        CancellationToken token)
    {
        if (expectedRunIndex <= 0)
            throw new ArgumentOutOfRangeException(nameof(expectedRunIndex));
        var result = await host.RunAsync(
            Path.Combine(workerDirectory, executableName), arguments, token);
        if (!result.Started)
            return new WorkerInvocation(false, ProcessOutcome.Failed, result.FailureCode);
        try
        {
            var envelope = ProcessResultValidator.Read<RunnerExecutionResult>(result.StandardOutput,
                expectedComponent, expectedRunIndex, result.ExitCode, result.StandardError);
            return new WorkerInvocation(
                envelope.Result?.WorkerStarted == true,
                envelope.Outcome,
                envelope.Error?.Code ?? (envelope.ScheduleDisposition == ScheduleDisposition.Preserve ? "runtime-deferred" : null),
                envelope.ScheduleDisposition);
        }
        catch (ProcessResultValidationException exception)
        {
            return new WorkerInvocation(false, ProcessOutcome.Failed, exception.Code);
        }
    }

}
