using System.ComponentModel;
using System.Text.Json;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Engine;

public sealed record SafeRestoreResult(
    long SourceId,
    long Revision,
    int Files,
    int Directories,
    string TargetPath);

/// <summary>
/// Restores into a sibling staging directory and exposes the result with directory renames.
/// A small durable journal makes an interrupted swap recoverable on the next invocation.
/// </summary>
public sealed class SafeRevisionRestoreService
{
    public async Task<SafeRestoreResult> RestoreReplacingAsync(
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        string targetPath,
        CancellationToken cancellationToken = default)
        => await RestoreReplacingCoreAsync(
            repository, sourceId, revision, targetPath, null, cancellationToken);

    public async Task<SafeRestoreResult> RestoreReplacingAsync(
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        string targetPath,
        Func<RestoreProgress, CancellationToken, Task> observer,
        CancellationToken cancellationToken = default)
        => await RestoreReplacingCoreAsync(
            repository, sourceId, revision, targetPath, observer, cancellationToken);

    private async Task<SafeRestoreResult> RestoreReplacingCoreAsync(
        RepositoryDatabase repository,
        long sourceId,
        long revision,
        string targetPath,
        Func<RestoreProgress, CancellationToken, Task>? observer,
        CancellationToken cancellationToken)
    {
        var target = Path.TrimEndingDirectorySeparator(Path.GetFullPath(targetPath));
        var parent = Path.GetDirectoryName(target)
            ?? throw new ArgumentException("Restore target must have a parent directory.", nameof(targetPath));
        Directory.CreateDirectory(parent);
        await PzTools.Process.Hosting.SaveFileEditTransaction.RecoverAsync(target, cancellationToken);
        await RecoverAsync(target, cancellationToken);
        if (Directory.Exists(target)
            && (File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("A reparse-point save directory cannot be replaced.");
        EnsureSaveIsInactive(target);

        var leaf = Path.GetFileName(target);
        var token = Guid.NewGuid().ToString("N");
        var staging = Path.Combine(parent, $".{leaf}.pztools-staging-{token}");
        var rollback = Path.Combine(parent, $".{leaf}.pztools-rollback-{token}");
        var journalPath = JournalPath(target);
        var journal = new RestoreJournal(2, target, staging, rollback, "restoring");

        try
        {
            await WriteJournalAsync(journalPath, journal, cancellationToken);
            var restorer = new RevisionRestorer();
            var restored = observer is null
                ? await restorer.RestoreAsync(
                    repository, sourceId, revision, staging, cancellationToken)
                : await restorer.RestoreAsync(
                    repository, sourceId, revision, staging, observer, cancellationToken);
            journal = journal with { Phase = "prepared", StagingIdentity = ReadDirectoryIdentity(staging) };
            await WriteJournalAsync(journalPath, journal, cancellationToken);

            if (Directory.Exists(target)) Directory.Move(target, rollback);
            await WriteJournalAsync(journalPath, journal with { Phase = "original-moved" }, cancellationToken);
            Directory.Move(staging, target);
            await WriteJournalAsync(journalPath, journal with { Phase = "installed" }, cancellationToken);

            await RecoverAsync(target, CancellationToken.None);
            return new SafeRestoreResult(
                restored.SourceId, restored.Revision, restored.Files, restored.Directories, target);
        }
        catch
        {
            await RecoverAsync(target, CancellationToken.None);
            if (Directory.Exists(staging)) DeleteOperationDirectory(staging);
            throw;
        }
    }

    public async Task RecoverAsync(string targetPath, CancellationToken cancellationToken = default)
    {
        var target = Path.TrimEndingDirectorySeparator(Path.GetFullPath(targetPath));
        var path = JournalPath(target);
        if (!File.Exists(path)) return;
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException($"Restore journal '{path}' is a reparse point.");
        RestoreJournal? journal;
        await using (var stream = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.Read,
            4096, FileOptions.Asynchronous | FileOptions.SequentialScan))
        {
            journal = await JsonSerializer.DeserializeAsync<RestoreJournal>(
                stream, cancellationToken: cancellationToken);
        }
        journal = ValidateJournal(path, target, journal);
        EnsureSaveIsInactive(target);

        var targetExists = DirectoryIsPresent(target);
        var rollbackExists = DirectoryIsPresent(journal.RollbackPath);
        var stagingExists = DirectoryIsPresent(journal.StagingPath);
        if (targetExists && rollbackExists)
        {
            // Phase may lag a completed rename. Prove directory identity instead of
            // treating an unrelated, newly created target as a successful installation.
            if (stagingExists || journal.StagingIdentity is null
                || !StringComparer.Ordinal.Equals(ReadDirectoryIdentity(target), journal.StagingIdentity))
                throw new IOException("restore-target-conflict: original rollback and staging were preserved");
            EnsureSaveIsInactive(journal.RollbackPath);
            DeleteOperationDirectory(journal.RollbackPath);
        }
        else if (!targetExists && rollbackExists)
        {
            // If recovery itself crashes after the rename, the next recovery can
            // recognize the returned original without trusting a lagging phase.
            journal = journal with { OriginalIdentity = ReadDirectoryIdentity(journal.RollbackPath) };
            await WriteJournalAsync(path, journal, cancellationToken);
            Directory.Move(journal.RollbackPath, target);
        }
        else if ((!targetExists && journal.Phase != "restoring")
            || (stagingExists && journal.Phase is "original-moved" or "installed"
                && (journal.OriginalIdentity is null
                    || !StringComparer.Ordinal.Equals(ReadDirectoryIdentity(target), journal.OriginalIdentity))))
        {
            throw new IOException("restore-target-conflict: recovery inventory was preserved");
        }
        if (stagingExists)
            DeleteOperationDirectory(journal.StagingPath);
        File.Delete(path);
    }

    public Task<SaveRecoverySweep> RecoverUnderSavesRootAsync(
        string savesRoot,
        CancellationToken cancellationToken = default)
        => InterruptedOperationRecoveryService.RecoverSavesAsync(savesRoot, cancellationToken);

    internal static void EnsureSaveIsInactive(string target)
    {
        if (Directory.Exists(target) && (File.GetAttributes(target) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("linked-save-directory");
        var players = Path.Combine(target, "players.db");
        if (!File.Exists(players)) return;
        try
        {
            using var stream = new FileStream(
                players, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException exception)
        {
            throw new IOException("The save is currently in use and cannot be restored.", exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new IOException("The save cannot be opened for an exclusive restore.", exception);
        }
    }

    private static string JournalPath(string target) =>
        Path.Combine(Path.GetDirectoryName(target)!, $".{Path.GetFileName(target)}.pztools-restore.json");

    private static bool DirectoryIsPresent(string path)
    {
        FileAttributes attributes;
        try { attributes = File.GetAttributes(path); }
        catch (FileNotFoundException) { return false; }
        // DirectoryNotFound can also mean a disconnected/missing parent. Do not
        // infer anything about recovery inventory in that case.
        if ((attributes & FileAttributes.ReparsePoint) != 0
            || (attributes & FileAttributes.Directory) == 0)
            throw new IOException($"Invalid restore directory '{path}'.");
        return true;
    }

    private static string ReadDirectoryIdentity(string path)
    {
        if (!DirectoryIsPresent(path)) throw new IOException($"Missing restore directory '{path}'.");
        try { return new WindowsFileMetadataReader().ReadPath(path).Identity; }
        catch (Win32Exception exception)
        { throw new IOException($"Cannot identify restore directory '{path}'.", exception); }
    }

    internal static void DeleteOperationDirectory(string path)
    {
        var pending = new Stack<string>();
        pending.Push(path);
        while (pending.TryPop(out var current))
        {
            var attributes = File.GetAttributes(current);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("linked-operation-inventory");
            if ((attributes & FileAttributes.Directory) != 0)
                foreach (var child in Directory.EnumerateFileSystemEntries(current)) pending.Push(child);
        }
        Directory.Delete(path, recursive: true);
    }

    private static RestoreJournal ValidateJournal(
        string journalPath,
        string target,
        RestoreJournal? journal)
    {
        if (journal is null || journal.Version is not (1 or 2)
            || journal.Phase is not ("restoring" or "prepared" or "original-moved" or "installed")
            || (journal.Version == 2 && journal.Phase != "restoring"
                && string.IsNullOrWhiteSpace(journal.StagingIdentity))
            || !StringComparer.OrdinalIgnoreCase.Equals(
                Path.GetFullPath(journal.TargetPath), target))
            throw new InvalidDataException($"Invalid restore journal '{journalPath}'.");

        var parent = Path.GetDirectoryName(target)!;
        var leaf = Path.GetFileName(target);
        var staging = Path.GetFullPath(journal.StagingPath);
        var rollback = Path.GetFullPath(journal.RollbackPath);
        var stagingPrefix = $".{leaf}.pztools-staging-";
        var stagingName = Path.GetFileName(staging);
        var token = stagingName.StartsWith(stagingPrefix, StringComparison.Ordinal)
            ? stagingName[stagingPrefix.Length..]
            : "";
        if (!StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(staging), parent)
            || !StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(rollback), parent)
            || !Guid.TryParseExact(token, "N", out _)
            || !StringComparer.Ordinal.Equals(
                Path.GetFileName(rollback), $".{leaf}.pztools-rollback-{token}"))
            throw new InvalidDataException($"Invalid restore journal '{journalPath}'.");

        foreach (var path in new[] { staging, rollback })
        {
            if (Directory.Exists(path)
                && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException(
                    $"Restore inventory '{path}' is a reparse point.");
        }
        return journal;
    }

    private static async Task WriteJournalAsync(
        string path, RestoreJournal journal, CancellationToken cancellationToken)
    {
        var temporary = path + ".tmp";
        await using (var stream = new FileStream(
            temporary, FileMode.Create, FileAccess.Write, FileShare.None,
            4096, FileOptions.Asynchronous | FileOptions.WriteThrough))
        {
            await JsonSerializer.SerializeAsync(stream, journal, cancellationToken: cancellationToken);
            await stream.FlushAsync(cancellationToken);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, path, overwrite: true);
    }

    private sealed record RestoreJournal(
        int Version,
        string TargetPath,
        string StagingPath,
        string RollbackPath,
        string Phase,
        string? StagingIdentity = null,
        string? OriginalIdentity = null);
}
