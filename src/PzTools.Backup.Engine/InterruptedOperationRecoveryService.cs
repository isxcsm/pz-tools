using System.Text.Json;
using PzTools.Backup.Storage.Repository;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Engine;

public sealed record RecoveryProblem(string Path, string Reason);
public sealed record InterruptedOperationRecoveryResult(bool Busy, int RecoveredWorkflows,
    int RecoveredSaves, int DeletedArtifacts, IReadOnlyList<RecoveryProblem> Problems);
public sealed record SaveRecoverySweep(int Recovered, int DeletedArtifacts, IReadOnlyList<RecoveryProblem> Problems);

public sealed class InterruptedOperationRecoveryService
{
    public async Task<InterruptedOperationRecoveryResult> TryRunAsync(
        RepositoryDatabase repository, string savesRoot, CancellationToken cancellationToken = default)
    {
        var result = await OperationMutexSet.TryRunAsync(
            [new OperationMutexRequest(OperationMutexScope.RepositoryAccess, repository.RepositoryPath)],
            token => RunUnderRepositoryLockAsync(repository, savesRoot, token), cancellationToken);
        return result.Acquired ? result.Value! : new(true, 0, 0, 0, []);
    }

    public async Task<InterruptedOperationRecoveryResult> RunUnderRepositoryLockAsync(
        RepositoryDatabase repository, string savesRoot, CancellationToken cancellationToken = default,
        bool collectGarbage = true)
    {
        RepositoryWriterLease lease;
        try { lease = RepositoryWriterLease.Acquire(repository.RepositoryPath); }
        catch (RepositoryBusyException) { return new(true, 0, 0, 0, []); }
        await using (lease)
        {
            var problems = new List<RecoveryProblem>();
            var workflows = await repository.RecoverInterruptedWorkflowsAsync(lease, cancellationToken);
            if (workflows.Unverified > 0)
                problems.Add(new(repository.DatabasePath, $"process-ownership-unverified:{workflows.Unverified}"));
            var deleted = 0;
            try
            {
                var artifacts = await repository.CleanupArtifactsAsync(lease, cancellationToken);
                deleted += artifacts.DeletedTemporaryFiles;
                problems.AddRange(artifacts.FilesThatCouldNotBeDeleted.Select(path => new RecoveryProblem(path, "temporary-file-cleanup-failed")));
                if (collectGarbage)
                {
                    var garbage = await repository.CollectGarbageAsync(lease, cancellationToken);
                    deleted += garbage.DeletedPacks + garbage.DeletedOrphanFiles;
                    problems.AddRange(garbage.FilesThatCouldNotBeDeleted.Select(path => new RecoveryProblem(path, "pack-cleanup-failed")));
                }
            }
            catch (Exception exception) when (IsRecoverableFailure(exception) || exception is Microsoft.Data.Sqlite.SqliteException)
            { problems.Add(new(repository.RepositoryPath, exception.Message)); }
            var saves = await RecoverSavesAsync(savesRoot, cancellationToken);
            problems.AddRange(saves.Problems);
            return new(false, workflows.Recovered, saves.Recovered,
                deleted + saves.DeletedArtifacts,
                problems);
        }
    }

    public static async Task<SaveRecoverySweep> RecoverSavesAsync(string savesRoot, CancellationToken token = default)
    {
        var problems = new List<RecoveryProblem>();
        var recovered = 0;
        var deleted = 0;
        var root = Path.GetFullPath(savesRoot);
        if (!Directory.Exists(root)) return new(0, 0, []);
        try
        {
            for (var ancestor = new DirectoryInfo(root); ancestor is not null; ancestor = ancestor.Parent)
                if ((File.GetAttributes(ancestor.FullName) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("linked-saves-root");
            foreach (var mode in Directory.GetDirectories(root))
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    if ((File.GetAttributes(mode) & FileAttributes.ReparsePoint) != 0) continue;
                    var names = Directory.GetFileSystemEntries(mode).Select(Path.GetFileName)
                        .Select(TryGetSaveName).OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
                    foreach (var name in names)
                    {
                        if (name is "." or ".." || name.EndsWith('.') || name.EndsWith(' ')) continue;
                        token.ThrowIfCancellationRequested();
                        var target = Path.Combine(mode, name);
                        try
                        {
                            await OperationMutexSet.TryRunAsync(
                                [new OperationMutexRequest(OperationMutexScope.SaveWrite, target)], async innerToken =>
                                {
                                    var service = new SafeRevisionRestoreService();
                                    if (await SaveFileEditTransaction.RecoverAsync(target, innerToken)) recovered++;
                                    var journal = Path.Combine(mode, $".{name}.pztools-restore.json");
                                    if (File.Exists(journal))
                                    {
                                        await service.RecoverAsync(target, innerToken);
                                        recovered++;
                                    }
                                    // Without a valid journal, rollback may be the only original.
                                    // Never infer that such a directory is disposable.
                                    var leftovers = Directory.GetFileSystemEntries(mode)
                                        .Where(path => StringComparer.OrdinalIgnoreCase.Equals(TryGetSaveName(Path.GetFileName(path)), name)).ToArray();
                                    if (leftovers.Length == 0) return true;
                                    if (!Directory.Exists(target) || leftovers.Any(path => IsInventory(path, name, "rollback")))
                                        throw new IOException("restore-inventory-without-journal");
                                    SafeRevisionRestoreService.EnsureSaveIsInactive(target);
                                    foreach (var path in leftovers)
                                    {
                                        innerToken.ThrowIfCancellationRequested();
                                        if (IsInventory(path, name, "staging"))
                                            SafeRevisionRestoreService.DeleteOperationDirectory(path);
                                        else if (StringComparer.OrdinalIgnoreCase.Equals(path, journal + ".tmp"))
                                        {
                                            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                                                throw new IOException("linked-restore-journal");
                                            File.Delete(path);
                                        }
                                        else continue;
                                        deleted++;
                                    }
                                    return true;
                                }, token);
                        }
                        catch (Exception exception) when (IsRecoverableFailure(exception))
                        { problems.Add(new(target, exception.Message)); }
                    }
                }
                catch (Exception exception) when (IsRecoverableFailure(exception))
                { problems.Add(new(mode, exception.Message)); }
            }
        }
        catch (Exception exception) when (IsRecoverableFailure(exception))
        { problems.Add(new(root, exception.Message)); }
        return new(recovered, deleted, problems);
    }

    private static bool IsRecoverableFailure(Exception exception) =>
        exception is IOException or InvalidDataException or UnauthorizedAccessException or JsonException or ArgumentException;

    private static string? TryGetSaveName(string? name)
    {
        if (name is null || !name.StartsWith('.')) return null;
        foreach (var suffix in new[] { ".pztools-restore.json", ".pztools-restore.json.tmp", SaveFileEditTransaction.Suffix })
            if (name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) && name.Length > suffix.Length + 1)
                return name[1..^suffix.Length];
        foreach (var kind in new[] { "staging", "rollback" })
        {
            var marker = $".pztools-{kind}-";
            var index = name.LastIndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (index > 1 && Guid.TryParseExact(name[(index + marker.Length)..], "N", out _)) return name[1..index];
        }
        return null;
    }

    private static bool IsInventory(string path, string name, string kind) =>
        Path.GetFileName(path).StartsWith($".{name}.pztools-{kind}-", StringComparison.OrdinalIgnoreCase)
        && StringComparer.OrdinalIgnoreCase.Equals(TryGetSaveName(Path.GetFileName(path)), name);
}
