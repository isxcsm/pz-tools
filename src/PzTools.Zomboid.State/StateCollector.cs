using System.Diagnostics;
using Microsoft.Data.Sqlite;

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

public sealed class GameActivityLane
{
    public (ActivityState State, LaneStatus Status, string? ErrorCode) Probe(string playersDatabasePath)
    {
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
    public async Task<(CharacterState State, LaneStatus Status, string? ErrorCode)> CollectAsync(
        string playersDatabasePath,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(playersDatabasePath))
        {
            return (CharacterState.Unknown, LaneStatus.Unavailable, "players-db-missing");
        }

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
            // 배타 probe의 핸들은 Probe 반환 전에 닫히므로 SQLite 읽기와 겹치지 않습니다.
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

        var batch = new CollectionBatch(
            Guid.NewGuid().ToString("D"),
            runIndex ?? await database.AllocateRunIndexAsync(cancellationToken),
            started,
            DateTimeOffset.UtcNow,
            timer.ElapsedMilliseconds,
            complete,
            observations);
        await database.WritePendingBatchAsync(batch, cancellationToken);
        return new StateCollectionResult(batch, discovered.Status);
    }
}
