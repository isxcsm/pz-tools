using Microsoft.Data.Sqlite;
using PzTools.Process.Hosting;

namespace PzTools.Zomboid.Recovery;

public sealed record CharacterRecoveryResult(string Name, bool Resurrected, int RecoveredItems = 0);

public sealed class CharacterRecoveryService
{
    /// <summary>
    /// Reanimated-player inventory is moved with a durable multi-file edit when identified.
    /// No additional backup is retained by this operation.
    /// An exclusive read/write guard rejects a running game and prevents it opening the old DB
    /// during preparation. Each file is atomically replaced; a durable journal coordinates pairs.
    /// </summary>
    public async Task<CharacterRecoveryResult> RecoverAsync(string savesRoot, string saveId,
        CancellationToken cancellationToken = default)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(savesRoot));
        var segments = saveId.Replace('\\', '/').Split('/');
        if (segments.Length != 2 || segments.Any(s => string.IsNullOrWhiteSpace(s) || s is "." or ".."
                || s.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            || segments[0].Equals("Multiplayer", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("recovery-singleplayer-only");
        var save = Path.Combine(root, segments[0], segments[1]);
        var database = Path.Combine(save, "players.db");
        RejectLinks(database);
        if (File.Exists(Path.Combine(Path.GetDirectoryName(save)!, $".{segments[1]}.pztools-restore.json")))
            throw new IOException("recovery-save-busy");
        await SaveFileEditTransaction.RecoverAsync(save, cancellationToken);
        // FileShare.Delete permits atomic replacement, but denies all other reads/writes.
        await using var guard = new FileStream(database, FileMode.Open, FileAccess.ReadWrite,
            FileShare.Delete, 64 * 1024, FileOptions.Asynchronous);
        CheckSidecars(database);
        var staging = Path.Combine(Path.GetDirectoryName(save)!, $".{segments[1]}.pztools-staging-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        var stagedDatabase = Path.Combine(staging, "players.db");
        FileStream? zombieGuard = null;
        var recoveredItems = 0;
        var files = new List<PreparedSaveFile>();
        try
        {
            await using (var staged = new FileStream(stagedDatabase, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 64 * 1024, FileOptions.Asynchronous))
            {
                await guard.CopyToAsync(staged, cancellationToken);
                staged.Flush(true);
            }
            string name;
            bool dead;
            await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = stagedDatabase, Mode = SqliteOpenMode.ReadWrite, Pooling = false,
            }.ToString()))
            {
                await connection.OpenAsync(cancellationToken);
                await using var check = connection.CreateCommand();
                check.CommandText = "PRAGMA integrity_check;";
                if (!Equals(await check.ExecuteScalarAsync(cancellationToken), "ok"))
                    throw new InvalidDataException("recovery-invalid-database");
                await using var network = connection.CreateCommand();
                network.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='networkPlayers';";
                if ((long)(await network.ExecuteScalarAsync(cancellationToken))! > 0)
                {
                    network.CommandText = "SELECT count(*) FROM networkPlayers;";
                    if ((long)(await network.ExecuteScalarAsync(cancellationToken))! > 0)
                        throw new InvalidDataException("recovery-singleplayer-only");
                }
                await using var query = connection.CreateCommand();
                query.CommandText = "SELECT id,name,worldversion,data,isDead FROM localPlayers ORDER BY id;";
                byte[] blob; long id; long version;
                await using (var reader = await query.ExecuteReaderAsync(cancellationToken))
                {
                    if (!await reader.ReadAsync(cancellationToken))
                        throw new InvalidDataException("recovery-no-character");
                    id = reader.GetInt64(0); name = reader.GetString(1); version = reader.GetInt64(2);
                    blob = (byte[])reader.GetValue(3); dead = reader.GetBoolean(4);
                    if (id != 1 || await reader.ReadAsync(cancellationToken))
                        throw new InvalidDataException("recovery-ambiguous-character");
                }
                var healed = PlayerHealthEditor.Heal(blob, version, out var layout);
                var zombiePath = Path.Combine(save, "reanimated.bin");
                if (ZombieInventoryRecovery.IsEmpty(healed, layout) && (dead || File.Exists(zombiePath)))
                {
                    if (!File.Exists(zombiePath)) throw new InvalidDataException("recovery-inventory-unavailable");
                    RejectLinks(zombiePath);
                    zombieGuard = new FileStream(zombiePath, FileMode.Open, FileAccess.ReadWrite, FileShare.Delete);
                    var originalHash = await SaveFileEditTransaction.HashAsync(zombieGuard, cancellationToken);
                    using var contents = new MemoryStream();
                    await zombieGuard.CopyToAsync(contents, cancellationToken);
                    var registryPath = Path.Combine(save, "WorldDictionary.bin");
                    if (!File.Exists(registryPath)) throw new InvalidDataException("recovery-inventory-unavailable");
                    RejectLinks(registryPath);
                    var registry = WorldItemRegistry.Read(await File.ReadAllBytesAsync(registryPath, cancellationToken));
                    InventoryRecovery? recovered = null;
                    try { recovered = ZombieInventoryRecovery.Recover(healed, layout, name, contents.ToArray(), registry); }
                    catch (InvalidDataException exception) when (!dead && exception.Message == "recovery-inventory-unavailable")
                    { /* A living character may legitimately carry nothing. Healing still applies. */ }
                    if (recovered is not null)
                    {
                        healed = recovered.Player;
                        recoveredItems = recovered.Items;
                        var stagedZombies = Path.Combine(staging, "reanimated.bin");
                        await File.WriteAllBytesAsync(stagedZombies, recovered.Zombies, cancellationToken);
                        files.Add(new("reanimated.bin", stagedZombies, originalHash));
                    }
                }
                // Idempotence also re-parses every edited boundary after optional fields shrink.
                if (!PlayerHealthEditor.Heal(healed, version).AsSpan().SequenceEqual(healed))
                    throw new InvalidDataException("recovery-validation-failed");
                await using var journal = connection.CreateCommand();
                journal.CommandText = "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;";
                await journal.ExecuteNonQueryAsync(cancellationToken);
                using var transaction = connection.BeginTransaction();
                await using var update = connection.CreateCommand();
                update.Transaction = transaction;
                update.CommandText = "UPDATE localPlayers SET data=$data,isDead=0 WHERE id=$id;";
                update.Parameters.AddWithValue("$data", healed); update.Parameters.AddWithValue("$id", id);
                if (await update.ExecuteNonQueryAsync(cancellationToken) != 1)
                    throw new InvalidDataException("recovery-validation-failed");
                transaction.Commit();
                if (!Equals(await check.ExecuteScalarAsync(cancellationToken), "ok"))
                    throw new InvalidDataException("recovery-invalid-database");
            }
            CheckSidecars(database);
            cancellationToken.ThrowIfCancellationRequested();
            // The SQLite connection is closed and journal removed before replacing the live file.
            if (files.Count == 0) File.Replace(stagedDatabase, database, null);
            else
            {
                files.Add(new("players.db", stagedDatabase, await SaveFileEditTransaction.HashAsync(guard, cancellationToken)));
                await SaveFileEditTransaction.CommitAsync(save, files, cancellationToken);
            }
            return new(name, dead, recoveredItems);
        }
        finally
        {
            if (zombieGuard is not null) await zombieGuard.DisposeAsync();
            // Exact newly-created staging directory only; never clean the original/save parent.
            try { Directory.Delete(staging, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void CheckSidecars(string database)
    {
        foreach (var suffix in new[] { "-wal", "-journal", "-shm" })
            if (File.Exists(database + suffix) && new FileInfo(database + suffix).Length != 0)
                throw new IOException("recovery-pending-journal");
    }

    private static void RejectLinks(string path)
    {
        for (var current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("recovery-linked-path");
    }
}
