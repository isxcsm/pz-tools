using PzTools.Backup.Storage.Repository;
using PzTools.Backup.Storage.Telemetry;

namespace PzTools.Backup.Engine;

public enum RecoveryIssueKind
{
    OrphanPack,
    MissingPack,
}

public sealed record RecoveryIssue(
    RecoveryIssueKind Kind,
    string RelativePath,
    Guid? PackId);

public sealed record RepositoryRecoveryResult(
    int AbandonedRuns,
    int QuarantinedTemporaryFiles,
    IReadOnlyList<RecoveryIssue> Issues,
    Exception? TelemetryFailure)
{
    public bool HasMissingCommittedData => Issues.Any(item => item.Kind == RecoveryIssueKind.MissingPack);
}

public sealed class RepositoryRecoveryService
{
    public async Task<RepositoryRecoveryResult> RecoverAsync(
        RepositoryDatabase repository,
        TelemetryStore telemetry,
        RepositoryWriterLease lease,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(telemetry);
        ArgumentNullException.ThrowIfNull(lease);
        var abandoned = await repository.RecoverAbandonedRunsAsync(lease, cancellationToken);
        Exception? telemetryFailure = telemetry.Failure;
        if (telemetry.IsAvailable)
        {
            try
            {
                await telemetry.ReconcileRunsAsync(lease, repository, cancellationToken);
                await telemetry.RecoverAbandonedRunsAsync(lease, cancellationToken);
            }
            catch (Exception exception) when (
                exception is IOException
                or UnauthorizedAccessException
                or InvalidDataException
                or Microsoft.Data.Sqlite.SqliteException)
            {
                telemetryFailure = exception;
            }
        }

        var quarantined = QuarantineTemporaryFiles(repository.RepositoryPath);
        var issues = await FindPackIssuesAsync(repository, cancellationToken);
        return new RepositoryRecoveryResult(abandoned, quarantined, issues, telemetryFailure);
    }

    private static int QuarantineTemporaryFiles(string repositoryPath)
    {
        var staging = Path.Combine(repositoryPath, "staging");
        if (!Directory.Exists(staging))
        {
            return 0;
        }

        var files = Directory.GetFiles(staging, "*.tmp", SearchOption.TopDirectoryOnly);
        if (files.Length == 0)
        {
            return 0;
        }

        var quarantine = Path.Combine(staging, "quarantine");
        Directory.CreateDirectory(quarantine);
        foreach (var file in files)
        {
            var destination = Path.Combine(quarantine, Path.GetFileName(file));
            if (File.Exists(destination))
            {
                destination = Path.Combine(
                    quarantine,
                    $"{Path.GetFileNameWithoutExtension(file)}-{Guid.NewGuid():N}.tmp");
            }

            File.Move(file, destination, overwrite: false);
        }

        return files.Length;
    }

    private static async Task<IReadOnlyList<RecoveryIssue>> FindPackIssuesAsync(
        RepositoryDatabase repository,
        CancellationToken cancellationToken)
    {
        var registered = await repository.ReadPacksAsync(cancellationToken);
        var byPath = registered.ToDictionary(
            item => Normalize(item.RelativePath),
            StringComparer.OrdinalIgnoreCase);
        var issues = new List<RecoveryIssue>();
        foreach (var pack in registered.Where(item => item.Status == "Committed"))
        {
            var fullPath = Path.Combine(
                repository.RepositoryPath,
                pack.RelativePath.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(fullPath))
            {
                issues.Add(new RecoveryIssue(
                    RecoveryIssueKind.MissingPack,
                    pack.RelativePath,
                    pack.PackId));
            }
        }

        var packsDirectory = Path.Combine(repository.RepositoryPath, "packs");
        foreach (var fullPath in Directory.EnumerateFiles(
                     packsDirectory,
                     "*.pzpack",
                     SearchOption.TopDirectoryOnly))
        {
            var relative = Normalize(Path.GetRelativePath(repository.RepositoryPath, fullPath));
            if (!byPath.ContainsKey(relative))
            {
                issues.Add(new RecoveryIssue(RecoveryIssueKind.OrphanPack, relative, PackId: null));
            }
        }

        return issues;
    }

    private static string Normalize(string path) => path.Replace('\\', '/');
}
