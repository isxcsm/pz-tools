using PzTools.Backup.Core;
using PzTools.Backup.Storage.Packs;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record RepositoryVerificationIssue(
    Guid PackId,
    string PackRelativePath,
    string Error,
    IReadOnlyList<RevisionReference> AffectedRevisions);

public sealed record RepositoryVerificationResult(
    int VerifiedPacks,
    IReadOnlyList<RepositoryVerificationIssue> Issues)
{
    public bool IsValid => Issues.Count == 0;
}

public sealed class RepositoryVerifier
{
    public async Task<RepositoryVerificationResult> VerifyAsync(
        RepositoryDatabase repository,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(repository);
        var packs = await repository.ReadPacksAsync(cancellationToken);
        var issues = new List<RepositoryVerificationIssue>();
        var verified = 0;
        foreach (var pack in packs.Where(item => item.Status == "Committed"))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var path = ResolveRepositoryPath(repository.RepositoryPath, pack.RelativePath);
                var file = new FileInfo(path);
                if (!file.Exists)
                {
                    throw new FileNotFoundException("Committed pack is missing.", path);
                }

                if (file.Length != pack.ByteLength)
                {
                    throw new InvalidDataException(
                        $"Pack length is {file.Length}, expected {pack.ByteLength}.");
                }

                var validation = await PackReader.ValidateAsync(
                    path,
                    verifyPayloads: true,
                    cancellationToken);
                if (validation.PackId != pack.PackId)
                {
                    throw new InvalidDataException("Pack identity does not match metadata.");
                }

                verified++;
            }
            catch (Exception exception) when (
                exception is IOException or InvalidDataException or UnauthorizedAccessException)
            {
                issues.Add(new RepositoryVerificationIssue(
                    pack.PackId,
                    pack.RelativePath,
                    exception.Message,
                    await repository.ReadAffectedRevisionsAsync(pack.PackId, cancellationToken)));
            }
        }

        return new RepositoryVerificationResult(verified, issues);
    }

    private static string ResolveRepositoryPath(string repositoryPath, string relativePath)
    {
        var normalized = BackupPath.NormalizeRelative(relativePath);
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(repositoryPath));
        var resolved = Path.GetFullPath(Path.Combine(
            root,
            normalized.Replace('/', Path.DirectorySeparatorChar)));
        if (!resolved.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException($"Pack path '{relativePath}' escapes its repository.");
        }

        return resolved;
    }
}
