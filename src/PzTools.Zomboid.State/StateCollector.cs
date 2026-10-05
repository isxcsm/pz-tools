using System.Diagnostics;
using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Zomboid.State;

public sealed record SaveDiscoveryResult(
    LaneStatus Status,
    bool Complete,
    IReadOnlyList<DiscoveredSave> Saves,
    string? ErrorCode = null);

public sealed record DiscoveredSave(
    string NormalizedPath,
    string Mode,
    string DisplayName,
    string PlayersDatabasePath,
    bool HasPlayersDatabase,
    bool Invalidated,
    DateTimeOffset? LastPlayedUtc);

public sealed class SaveDiscoveryLane
{
    public SaveDiscoveryResult Collect(string savesRoot)
    {
        var root = Path.GetFullPath(savesRoot);
        if (!Directory.Exists(root))
        {
            return new SaveDiscoveryResult(LaneStatus.Unavailable, false, [], "root-missing");
        }

        var saves = new List<DiscoveredSave>();
        var complete = true;
        try
        {
            foreach (var modePath in Directory.EnumerateDirectories(root))
            {
                if (SaveOperationPaths.IsTemporaryDirectory(modePath)) continue;
                if ((File.GetAttributes(modePath) & FileAttributes.ReparsePoint) != 0) continue;
                var mode = Path.GetFileName(modePath);
                try
                {
                    // The durable journal spans extraction, both renames, and cleanup.
                    // Keep the previous target state until the whole operation is visible.
                    var restoring = SaveOperationPaths.RestoringTargets(modePath)
                        .ToHashSet(StringComparer.OrdinalIgnoreCase);
                    foreach (var savePath in Directory.EnumerateDirectories(modePath))
                    {
                        if (SaveOperationPaths.IsTemporaryDirectory(savePath)
                            || restoring.Contains(Normalize(savePath))) continue;
                        if ((File.GetAttributes(savePath) & FileAttributes.ReparsePoint) != 0) continue;
                        var players = Path.Combine(savePath, "players.db");
                        var mapVersion = Path.Combine(savePath, "map_ver.bin");
                        var hasPlayers = File.Exists(players);
                        var hasMarker = hasPlayers || File.Exists(mapVersion);
                        if (!hasMarker) continue;
                        DateTimeOffset? lastPlayed = null;
                        if (hasPlayers)
                        {
                            try { lastPlayed = File.GetLastWriteTimeUtc(players); }
                            catch (Exception exception) when (
                                exception is IOException or UnauthorizedAccessException)
                            { }
                        }
                        saves.Add(new DiscoveredSave(
                            Normalize(savePath), mode, Path.GetFileName(savePath),
                            players, hasPlayers, Invalidated: !hasPlayers, lastPlayed));
                    }
                    // A restore may have started after enumeration began.
                    restoring.UnionWith(SaveOperationPaths.RestoringTargets(modePath));
                    if (restoring.Count > 0)
                    {
                        complete = false;
                        saves.RemoveAll(save => restoring.Contains(save.NormalizedPath));
                    }
                    // Never read an unresolved swap gap as a deleted save.
                    if (SaveOperationPaths.HasJournalWithoutSave(modePath)) complete = false;
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    complete = false;
                }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            complete = false;
        }

        return new SaveDiscoveryResult(
            complete ? LaneStatus.Succeeded : LaneStatus.Failed,
            complete,
            saves,
            complete ? null : "enumeration-incomplete");
    }

    private static string Normalize(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)).ToUpperInvariant();
}

public sealed class GameActivityLane(Func<RuntimeObservation?>? runtime = null)
{
    public (ActivityState State, LaneStatus Status, string? ErrorCode) Probe(string playersDatabasePath)
    {
        var observation = runtime?.Invoke();
        // A running game that cannot be read (a game update, a blocked helper) still locks the players.db of the
        // world it has open. That lock is all that backups without the game's help need to know which save it is.
        if (observation is not null && !observation.IsLinkUnusable)
        {
            if (observation.Quality == RuntimeQuality.Offline) return (ActivityState.Inactive, LaneStatus.Succeeded, null);
            if (!observation.IsFresh || observation.Snapshot is not { } sample)
                return (ActivityState.Unknown, LaneStatus.Unavailable, "runtime-unavailable");
            if (sample.Phase is WorldPhase.Menu or WorldPhase.Unloading)
                return (ActivityState.Inactive, LaneStatus.Succeeded, null);
            if (!sample.IsWorldReady) return (ActivityState.Unknown, LaneStatus.Unsupported, "runtime-world-unavailable");
            bool selected = StringComparer.OrdinalIgnoreCase.Equals(Path.TrimEndingDirectorySeparator(sample.SavePath!),
                Path.TrimEndingDirectorySeparator(Path.GetDirectoryName(Path.GetFullPath(playersDatabasePath))!));
            return (selected ? ActivityState.Active : ActivityState.Inactive, LaneStatus.Succeeded, null);
        }
        if (!File.Exists(playersDatabasePath))
        {
            return (ActivityState.Unknown, LaneStatus.Unavailable, "players-db-missing");
        }

        try
        {
            using var stream = new FileStream(
                playersDatabasePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None,
                bufferSize: 1, FileOptions.None);
            return (ActivityState.Inactive, LaneStatus.Succeeded, null);
        }
        catch (IOException exception) when ((exception.HResult & 0xFFFF) is 32 or 33)
        {
            return (ActivityState.Active, LaneStatus.Succeeded, "sharing-violation");
        }
        catch (UnauthorizedAccessException)
        {
            return (ActivityState.Unknown, LaneStatus.Unavailable, "access-denied");
        }
        catch (IOException)
        {
            return (ActivityState.Unknown, LaneStatus.Failed, "io-error");
        }
    }
}

public sealed class CharacterStateLane
{
    // Collection runs every few seconds over every save, most of them untouched for months. Whether a
    // character is dead changes only when players.db does, and the game writes to its -wal file first,
    // so an answer read while both files were exactly as they are now is still the answer.
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string,
        ((DateTime, long, DateTime, long) Stamp, (CharacterState, LaneStatus, string?) Result)> Known =
        new(StringComparer.OrdinalIgnoreCase);

    public async Task<(CharacterState State, LaneStatus Status, string? ErrorCode)> CollectAsync(
        string playersDatabasePath,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(playersDatabasePath))
        {
            Known.TryRemove(playersDatabasePath, out _);
            return (CharacterState.Unknown, LaneStatus.Unavailable, "players-db-missing");
        }
        var stamp = Stamp(playersDatabasePath);
        if (stamp is { } current && Known.TryGetValue(playersDatabasePath, out var known) && known.Stamp == current)
            return known.Result;
        var result = await ReadAsync(playersDatabasePath, cancellationToken);
        // Only definite answers are kept; a failed read is tried again next time.
        if (stamp is { } read && result.Item2 is LaneStatus.Succeeded or LaneStatus.Unsupported)
            Known[playersDatabasePath] = (read, result);
        else Known.TryRemove(playersDatabasePath, out _);
        return result;
    }

    private static (DateTime, long, DateTime, long)? Stamp(string path)
    {
        try
        {
            var main = new FileInfo(path);
            var wal = new FileInfo(path + "-wal");
            return (main.LastWriteTimeUtc, main.Length,
                wal.Exists ? wal.LastWriteTimeUtc : default, wal.Exists ? wal.Length : -1);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static async Task<(CharacterState State, LaneStatus Status, string? ErrorCode)> ReadAsync(
        string playersDatabasePath,
        CancellationToken cancellationToken)
    {
        try
        {
            var connectionString = new SqliteConnectionStringBuilder
            {
                DataSource = playersDatabasePath,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false,
                // Microsoft.Data.Sqlite retries SQLITE_BUSY using its command timeout,
                // not just the PRAGMA below. Do not stall all save discovery for 30 seconds.
                DefaultTimeout = 1,
            }.ToString();
            await using var connection = new SqliteConnection(connectionString);
            await connection.OpenAsync(cancellationToken);
            await using var timeout = connection.CreateCommand();
            timeout.CommandText = "PRAGMA busy_timeout=100;";
            await timeout.ExecuteNonQueryAsync(cancellationToken);

            var values = new List<long>();
            foreach (var table in new[] { "localPlayers", "networkPlayers" })
            {
                await using var schema = connection.CreateCommand();
                schema.CommandText =
                    "SELECT 1 FROM pragma_table_info($table) WHERE name = 'isDead';";
                schema.Parameters.AddWithValue("$table", table);
                if (await schema.ExecuteScalarAsync(cancellationToken) is null) continue;
                await using var query = connection.CreateCommand();
                query.CommandText = $"SELECT isDead FROM \"{table}\";";
                await using var reader = await query.ExecuteReaderAsync(cancellationToken);
                while (await reader.ReadAsync(cancellationToken))
                {
                    if (!reader.IsDBNull(0)) values.Add(reader.GetInt64(0));
                }
            }

            if (values.Count == 0)
            {
                return (CharacterState.Unknown, LaneStatus.Unsupported, "no-player-state");
            }

            return values.All(value => value != 0)
                ? (CharacterState.Dead, LaneStatus.Succeeded, null)
                : (CharacterState.Alive, LaneStatus.Succeeded, null);
        }
        catch (SqliteException)
        {
            return (CharacterState.Unknown, LaneStatus.Failed, "sqlite-unavailable");
        }
    }
}

public sealed class StateCollector(
    SaveDiscoveryLane discovery,
    GameActivityLane activity,
    CharacterStateLane character)
{
    public StateCollector() : this(new SaveDiscoveryLane(), new GameActivityLane(), new CharacterStateLane()) { }

    public async Task<StateCollectionResult> RunAsync(
        StateDatabase database,
        string savesRoot,
        long? runIndex = null,
        CancellationToken cancellationToken = default)
    {
        var seen = await ObserveAsync(savesRoot, cancellationToken);
        var batch = new CollectionBatch(
            Guid.NewGuid().ToString("D"),
            runIndex ?? await database.AllocateRunIndexAsync(cancellationToken),
            seen.StartedUtc,
            DateTimeOffset.UtcNow,
            seen.ElapsedMilliseconds,
            seen.DiscoveryComplete,
            seen.Saves);
        await database.WritePendingBatchAsync(batch, cancellationToken);
        return new StateCollectionResult(batch, seen.DiscoveryStatus);
    }

    /// <summary>Looks at the saves without writing anything.</summary>
    public async Task<StateObservationSet> ObserveAsync(string savesRoot, CancellationToken cancellationToken = default)
    {
        var started = DateTimeOffset.UtcNow;
        var timer = Stopwatch.StartNew();
        var discovered = discovery.Collect(savesRoot);
        var complete = discovered.Complete;
        var observations = new List<SaveObservation>(discovered.Saves.Count);
        foreach (var save in discovered.Saves)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (SaveOperationPaths.IsRestoring(save.NormalizedPath))
            {
                complete = false;
                continue;
            }
            var activityResult = save.Invalidated
                ? (ActivityState.Unknown, LaneStatus.Unavailable, "invalidated")
                : activity.Probe(save.PlayersDatabasePath);
            // The exclusive probe's handle is closed before Probe returns, so it never overlaps the SQLite read.
            var characterResult = save.Invalidated
                ? (CharacterState.Unknown, LaneStatus.Unavailable, "invalidated")
                : await character.CollectAsync(save.PlayersDatabasePath, cancellationToken);
            observations.Add(new SaveObservation(
                save.NormalizedPath, save.Mode, save.DisplayName, save.HasPlayersDatabase,
                save.Invalidated, activityResult.Item1, characterResult.Item1,
                activityResult.Item2, characterResult.Item2,
                activityResult.Item3 ?? characterResult.Item3,
                save.LastPlayedUtc));
        }

        // Probing SQLite can overlap the start of a restore. Never publish that
        // transitional observation or interpret the swap gap as a deleted save.
        if (observations.RemoveAll(save => SaveOperationPaths.IsRestoring(save.NormalizedPath)) > 0)
            complete = false;

        return new StateObservationSet(started, timer.ElapsedMilliseconds, complete, observations, discovered.Status);
    }
}
