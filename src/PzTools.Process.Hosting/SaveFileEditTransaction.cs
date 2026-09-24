using System.Security.Cryptography;
using System.Text.Json;

namespace PzTools.Process.Hosting;

public sealed record PreparedSaveFile(string Name, string PreparedPath, string OriginalHash);

/// <summary>
/// Durable roll-forward for a small set of save files. The caller holds the save-write mutex
/// and exclusive (delete-sharing) original handles. Completed edits retain no backup copies.
/// After a crash, hashes prevent overwriting a save subsequently changed by the game.
/// </summary>
public static class SaveFileEditTransaction
{
    public const string Suffix = ".pztools-file-edit";
    public static string DirectoryPath(string save)
    {
        var target = Path.TrimEndingDirectorySeparator(Path.GetFullPath(save));
        return Path.Combine(Path.GetDirectoryName(target)!, $".{Path.GetFileName(target)}{Suffix}");
    }
    public static bool IsPending(string save) => Directory.Exists(DirectoryPath(save));

    public static async Task CommitAsync(string save, IReadOnlyList<PreparedSaveFile> files, CancellationToken token)
    {
        var directory = DirectoryPath(save);
        if (Directory.Exists(directory)) throw new IOException("save-edit-pending");
        ValidateNames(files.Select(f => f.Name).ToArray());
        Directory.CreateDirectory(directory);
        var ready = false;
        try
        {
            var entries = new List<Entry>();
            foreach (var file in files)
            {
                RejectLinks(file.PreparedPath);
                var staged = Path.Combine(directory, file.Name);
                await CopyDurableAsync(file.PreparedPath, staged, token);
                entries.Add(new(file.Name, file.OriginalHash, await HashFileAsync(staged, token)));
            }
            var temporary = Path.Combine(directory, "manifest.tmp");
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await JsonSerializer.SerializeAsync(stream, new Manifest(1, entries.ToArray()), cancellationToken: token);
                stream.Flush(true);
            }
            token.ThrowIfCancellationRequested();
            File.Move(temporary, Path.Combine(directory, "manifest.json"));
            ready = true;
            // Cancellation is no longer honored after the durable commit decision.
            await InstallAsync(save, directory, entries, CancellationToken.None);
            DeleteInventory(directory);
        }
        catch (Exception exception) when (ready)
        {
            // Never remove recovery payloads after a partially published multi-file edit.
            throw new IOException("save-edit-pending", exception);
        }
        finally
        {
            if (!ready && Directory.Exists(directory)) DeleteInventory(directory);
        }
    }

    public static async Task<bool> RecoverAsync(string save, CancellationToken token = default)
    {
        var directory = DirectoryPath(save);
        if (!Directory.Exists(directory)) return false;
        RejectLinks(save); RejectLinks(directory);
        var handles = new List<FileStream>();
        try
        {
            // players.db is also the game's active-save lock, even for an edit of another file.
            handles.Add(OpenGuard(Path.Combine(save, "players.db")));
            var manifestPath = Path.Combine(directory, "manifest.json");
            if (!File.Exists(manifestPath)) { DeleteInventory(directory); return true; }
            RejectLinks(manifestPath);
            var manifest = JsonSerializer.Deserialize<Manifest>(await File.ReadAllBytesAsync(manifestPath, token));
            if (manifest is null || manifest.Version != 1 || manifest.Files is null)
                throw new InvalidDataException("save-edit-invalid-journal");
            ValidateNames(manifest.Files.Select(e => e.Name).ToArray());
            var pending = new List<Entry>();
            foreach (var entry in manifest.Files)
            {
                var path = Path.Combine(save, entry.Name);
                RejectLinks(path);
                var handle = entry.Name == "players.db" ? handles[0] : OpenGuard(path);
                if (entry.Name != "players.db") handles.Add(handle);
                var hash = await HashAsync(handle, token);
                if (hash == entry.After) continue; // also tolerates interrupted cleanup after full installation
                if (hash != entry.Before) throw new InvalidDataException("save-edit-conflict");
                var payload = Path.Combine(directory, entry.Name); RejectLinks(payload);
                if (await HashFileAsync(payload, token) != entry.After) throw new InvalidDataException("save-edit-conflict");
                pending.Add(entry);
            }
            token.ThrowIfCancellationRequested();
            await InstallAsync(save, directory, pending, CancellationToken.None);
            DeleteInventory(directory);
            return true;
        }
        finally { foreach (var handle in handles) await handle.DisposeAsync(); }
    }

    public static async Task<string> HashAsync(Stream stream, CancellationToken token)
    {
        stream.Position = 0;
        var result = Convert.ToHexString(await SHA256.HashDataAsync(stream, token));
        stream.Position = 0;
        return result;
    }

    private static async Task<string> HashFileAsync(string path, CancellationToken token)
    { await using var stream = File.OpenRead(path); return await HashAsync(stream, token); }

    private static async Task InstallAsync(string save, string directory, IEnumerable<Entry> entries, CancellationToken token)
    {
        foreach (var entry in entries)
        {
            var temporary = Path.Combine(directory, "install.tmp");
            if (File.Exists(temporary)) { RejectLinks(temporary); File.Delete(temporary); }
            await CopyDurableAsync(Path.Combine(directory, entry.Name), temporary, token);
            File.Replace(temporary, Path.Combine(save, entry.Name), null);
        }
    }

    private static async Task CopyDurableAsync(string source, string target, CancellationToken token)
    {
        await using var input = File.OpenRead(source);
        await using var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        await input.CopyToAsync(output, token); output.Flush(true);
    }

    private static FileStream OpenGuard(string path)
    {
        RejectLinks(path);
        foreach (var suffix in new[] { "-wal", "-shm", "-journal" })
            if (File.Exists(path + suffix) && new FileInfo(path + suffix).Length > 0)
                throw new IOException("save-edit-pending-database-journal");
        return new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Delete);
    }

    private static void ValidateNames(string[] names)
    {
        if (names.Length is < 1 or > 32 || names.Distinct(StringComparer.OrdinalIgnoreCase).Count() != names.Length
            || names.Any(n => string.IsNullOrEmpty(n) || Path.GetFileName(n) != n || n is "." or ".."
                || n.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0
                || n.EndsWith('.') || n.EndsWith(' ') || n is "manifest.json" or "manifest.tmp" or "install.tmp"))
            throw new InvalidDataException("save-edit-invalid-journal");
    }

    private static void RejectLinks(string path)
    {
        for (var current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("linked-save-edit-path");
    }

    private static void DeleteInventory(string directory)
    {
        RejectLinks(directory);
        var files = Directory.GetFileSystemEntries(directory);
        foreach (var file in files)
            if ((File.GetAttributes(file) & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                throw new IOException("invalid-save-edit-inventory");
        foreach (var file in files) File.Delete(file);
        Directory.Delete(directory);
    }

    private sealed record Entry(string Name, string Before, string After);
    private sealed record Manifest(int Version, Entry[] Files);
}
