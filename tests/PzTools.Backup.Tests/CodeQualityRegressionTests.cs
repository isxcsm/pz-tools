using System.Text.Json;
using PzTools.App.Core;
using PzTools.Backup.Storage.Repository;
using PzTools.Control;
using PzTools.Process.Contracts;
using PzTools.Process.Hosting;
using PzTools.Process.Telemetry;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class CodeQualityRegressionTests
{
    [Theory]
    [InlineData("", 0)]
    [InlineData("not-json", 0)]
    [InlineData("{\"version\":1,\"component\":\"wrong\",\"runIndex\":7,\"outcome\":\"Succeeded\"}", 0)]
    [InlineData("{\"version\":1,\"component\":\"worker\",\"runIndex\":8,\"outcome\":\"Succeeded\"}", 0)]
    [InlineData("{\"version\":1,\"component\":\"worker\",\"runIndex\":7,\"outcome\":\"Succeeded\"}", 1)]
    [InlineData("{\"version\":1,\"component\":\"worker\",\"runIndex\":\"bad\",\"outcome\":\"Succeeded\"}", 0)]
    public void ValidatorRejectsMissingMalformedAndContradictoryResults(string output, int exit)
    {
        var error = Assert.Throws<ProcessResultValidationException>(() =>
            ProcessResultValidator.Read<JsonElement>(output, "worker", 7, exit, "original failure"));
        Assert.Contains("original failure", error.Message);
    }

    [Theory]
    [InlineData("", 0)]
    [InlineData("{\"version\":1,\"component\":\"worker\",\"runIndex\":7,\"outcome\":\"Succeeded\"}", 1)]
    public async Task RunnerDoesNotLaunderChildFailure(string output, int exit)
    {
        using var temp = new TempDirectory();
        if (output.Length != 0) output = ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Success(
            "worker", 7, ProcessOutcome.Succeeded, DateTimeOffset.UtcNow));
        var result = await new OneShotRunnerCoordinator().RunAsync("runner", "audit", temp.Path, 7,
            Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
            ["-NoProfile", "-NonInteractive", "-Command", $"[Console]::WriteLine('{output}'); exit {exit}"], "worker");
        Assert.Equal(ProcessOutcome.Failed, result.Outcome);
        Assert.Equal(7, result.RunIndex);
        Assert.NotNull(result.Error);
    }

    [Fact]
    public void ValidatorAcceptsDiagnosticPrefixAndChecksTypedResult()
    {
        var json = ProcessResultJson.Serialize(ProcessResultEnvelope<int>.Success(
            "worker", 7, ProcessOutcome.NoChange, DateTimeOffset.UtcNow, 42));
        Assert.Equal(42, ProcessResultValidator.Read<int>("diagnostic\n" + json, "worker", 7, 0).Result);
        Assert.Equal(42, ProcessResultValidator.Read<int>(json, "worker", 7, 0).Result);
    }

    [Theory]
    [InlineData("wrong-worker", 7, 0)]
    [InlineData("worker", 8, 0)]
    [InlineData("worker", 7, 1)]
    public void ValidEnvelopeStillRequiresMatchingIdentityAndExit(string component, long run, int exit)
    {
        var json = ProcessResultJson.Serialize(ProcessResultEnvelope<object>.Success(
            component, run, ProcessOutcome.Succeeded, DateTimeOffset.UtcNow));
        Assert.Equal("process-contract-mismatch", Assert.Throws<ProcessResultValidationException>(() =>
            ProcessResultValidator.Read<object>(json, "worker", 7, exit)).Code);
    }

    [Theory]
    [InlineData("outcome")]
    [InlineData("startedUtc")]
    [InlineData("completedUtc")]
    public void MissingRequiredFieldsDoNotBecomeImplicitSuccess(string field)
    {
        var json = System.Text.Json.Nodes.JsonNode.Parse(ProcessResultJson.Serialize(
            ProcessResultEnvelope<object>.Success("worker", 7, ProcessOutcome.Succeeded, DateTimeOffset.UtcNow)))!.AsObject();
        json.Remove(field);
        Assert.Throws<ProcessResultValidationException>(() => ProcessResultValidator.Read<object>(json.ToJsonString(), "worker", 7, 0));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task PartialAdmissionReleasesEarlierLocksOnCancellationOrEnumerationFailure(bool cancel)
    {
        using var first = new SemaphoreSlim(1, 1);
        using var second = new SemaphoreSlim(1, 1);
        using var cancellation = new CancellationTokenSource();
        IEnumerable<SemaphoreSlim> Gates()
        {
            yield return first;
            if (cancel) cancellation.Cancel();
            else throw new IOException("enumeration failed");
            yield return second;
        }
        await Assert.ThrowsAnyAsync<Exception>(() => SemaphoreAdmission.TryAcquireAsync(Gates(), cancellation.Token));
        Assert.Equal(1, first.CurrentCount);
        Assert.Equal(1, second.CurrentCount);
        await using var retry = await SemaphoreAdmission.TryAcquireAsync([first, second]);
        Assert.NotNull(retry);
    }

    [Fact]
    public async Task BusyAdmissionAndRepeatedDisposalDoNotLeakOrOverRelease()
    {
        using var first = new SemaphoreSlim(1, 1);
        using var second = new SemaphoreSlim(0, 1);
        Assert.Null(await SemaphoreAdmission.TryAcquireAsync([first, second]));
        Assert.Equal(1, first.CurrentCount);
        second.Release();
        var admission = (await SemaphoreAdmission.TryAcquireAsync([first, second]))!;
        await admission.DisposeAsync();
        await admission.DisposeAsync();
        Assert.Equal(1, first.CurrentCount);
        Assert.Equal(1, second.CurrentCount);
    }

    [Fact]
    public async Task UnexpectedDispatchFailureFinalizesDurableWorkflowWhileAppIsAlive()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var launcher = new FixtureLauncher(throws: true);
        var coordinator = Coordinator(temp, repository, launcher);
        await Assert.ThrowsAsync<IOException>(() => coordinator.BackupAsync("Sandbox/Test", temp.GetPath("save")));
        Assert.Equal(WorkflowStatus.Failed, (await repository.ReadWorkflowAsync(launcher.RunIndex)).Status);
        await Assert.ThrowsAsync<IOException>(() => coordinator.BackupAsync("Sandbox/Test", temp.GetPath("save")));
        Assert.Equal(WorkflowStatus.Failed, (await repository.ReadWorkflowAsync(launcher.RunIndex)).Status);
    }

    [Fact]
    public async Task InvalidResultRetainsStderrInResultAndDurableDiagnostics()
    {
        using var temp = new TempDirectory();
        var repository = await RepositoryDatabase.CreateOrOpenAsync(temp.GetPath("repository"));
        var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
        var coordinator = Coordinator(temp, repository, new FixtureLauncher(throws: false), inbox);
        var result = await coordinator.BackupAsync("Sandbox/Test", temp.GetPath("save"));
        Assert.Equal("invalid-process-result", result.Error);
        Assert.Contains("invalid --example-option", result.ErrorMessage);
        var logs = await inbox.ReadViewAsync(new(LogLevel.Trace, 100));
        Assert.Contains(logs.Entries, log => log.PayloadJson?.Contains("invalid --example-option") == true);
        Assert.Equal(WorkflowStatus.Failed, (await repository.ReadWorkflowAsync(result.RunIndex)).Status);
    }

    [Fact]
    public async Task TelemetryIsRemovedOnlyAfterDurableImportAndWriterExit()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("operations");
        var id = "archive-export-" + Guid.NewGuid().ToString("N");
        var identity = Path.Combine(root, "archive-worker", id);
        var activity = ProcessTelemetryActivity.Acquire(identity, "archive-worker");
        try
        {
            var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "archive-worker");
            await store.RecordAsync("archive-worker", 1, "run.failed", "{\"message\":\"keep this diagnostic\"}");
            var source = new TelemetrySourceRegistration(id, "archive-worker", identity, store.DatabasePath,
                TelemetryDatabaseKind.Process, true, new(id, "archive", 1, OperationStatus.Failed,
                    DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(-1)), Transient: true, LogsOnly: true);
            var catalog = new TelemetrySourceCatalog();
            catalog.Register(source);
            var inbox = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
            var cleanup = new OperationTelemetryCleanup(root);
            var projection = new TelemetryProjectionHost(catalog, new(), logInbox: inbox, retireSource: cleanup.TryRemove);
            await projection.ProjectOnceAsync();
            Assert.True(Directory.Exists(identity));
            Assert.DoesNotContain(id, await inbox.ReadImportedSourcesAsync());
            activity.Dispose();
            await projection.ProjectOnceAsync();
            Assert.False(Directory.Exists(identity));
            Assert.Empty(catalog.Snapshot());
            Assert.Empty(await inbox.ReadImportedSourcesAsync());
            var reopened = await LogInboxStore.CreateOrOpenAsync(temp.GetPath("logs.db"));
            Assert.Contains((await reopened.ReadViewAsync(new(LogLevel.Trace, 100))).Entries,
                log => log.PayloadJson?.Contains("keep this diagnostic") == true);
        }
        finally { activity.Dispose(); }
    }

    [Fact]
    public async Task TelemetryCleanupPreservesUnknownFilesAndRefusesOutsideRoot()
    {
        using var temp = new TempDirectory();
        var root = temp.GetPath("operations");
        var id = "restore-" + Guid.NewGuid().ToString("N");
        var identity = Path.Combine(root, "restore-worker", id);
        var store = await ProcessTelemetryStore.CreateForIdentityAsync(identity, "restore-worker");
        var source = new TelemetrySourceRegistration(id, "restore-worker", identity, store.DatabasePath,
            TelemetryDatabaseKind.Process, true, new(id, "restore", 1, OperationStatus.Succeeded,
                DateTimeOffset.UtcNow, DateTimeOffset.UtcNow), Transient: true);
        var cleanup = new OperationTelemetryCleanup(root);
        var personalFile = Path.Combine(identity, "keep.txt");
        await File.WriteAllTextAsync(personalFile, "not app-owned");
        Assert.False(cleanup.TryRemove(source));
        Assert.True(File.Exists(store.DatabasePath));
        Assert.True(File.Exists(personalFile));
        Assert.False(new OperationTelemetryCleanup(temp.GetPath("other")).TryRemove(source));
    }

    [Fact]
    public void StructuralViewComparisonDetectsNestedChangesWithoutDependingOnCollectionIdentity()
    {
        var revision = new BackupRevisionView(1, DateTimeOffset.UtcNow, 32, 1, "Active", "thumbnail");
        var first = new SaveDetailView("save", null, [revision]);
        var copy = new SaveDetailView("save", null, [revision with { }]);
        Assert.True(ViewComparers.Detail.Equals(first, copy));
        Assert.Equal(ViewComparers.Detail.GetHashCode(first), ViewComparers.Detail.GetHashCode(copy));
        Assert.False(ViewComparers.Detail.Equals(first, copy with { BackupRevisions = [revision with { CharacterMetadataError = "bad database" }] }));
        var before = new MetricsView([new("worker", 1, 1, 0, 32, 1, new Dictionary<string, TimeSpan> { ["read"] = TimeSpan.FromSeconds(1) })]);
        var after = new MetricsView([before.Producers[0] with { PhaseDurations = new Dictionary<string, TimeSpan> { ["read"] = TimeSpan.FromSeconds(2) } }]);
        Assert.False(ViewComparers.Metrics.Equals(before, after));
    }

    private static OperationCoordinator Coordinator(TempDirectory temp, RepositoryDatabase repository,
        IManagedProcessLauncher launcher, LogInboxStore? inbox = null)
    {
        var telemetry = new TelemetrySourceCatalog();
        telemetry.Register(new("backup-worker", "backup-worker", repository.RepositoryPath,
            Path.Combine(repository.RepositoryPath, "telemetry.db"), TelemetryDatabaseKind.Backup, true));
        return new(repository, temp.Path, telemetry, launcher,
            new RunIndexAllocator(temp.GetPath("control.db")), temp.GetPath("operations"), diagnostics: inbox);
    }

    private sealed class FixtureLauncher(bool throws) : IManagedProcessLauncher
    {
        public long RunIndex { get; private set; }
        public Task<ManagedProcessExit> RunAsync(string executable, IReadOnlyList<string> arguments,
            Action<string>? standardOutput, Action<string>? standardError, CancellationToken cancellationToken)
        {
            RunIndex = long.Parse(arguments[arguments.ToList().IndexOf("--run-index") + 1]);
            if (throws) throw new IOException("dispatch failure");
            standardError?.Invoke("invalid --example-option");
            return Task.FromResult(new ManagedProcessExit(true, 64, "process-exited"));
        }
    }
}
