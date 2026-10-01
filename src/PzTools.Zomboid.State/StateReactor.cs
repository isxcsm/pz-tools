using System.Globalization;
using Microsoft.Data.Sqlite;

namespace PzTools.Zomboid.State;

public sealed class StateReactor
{
    public async Task<ReactorResult> RunAsync(
        StateDatabase database,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await database.OpenAsync(cancellationToken);
        using var transaction = connection.BeginTransaction();
        try
        {
            var (stateRevision, initialized) = await ReadStateInfoAsync(connection, transaction, cancellationToken);
            var beforeRevision = stateRevision;
            var batches = await ReadBatchesAsync(connection, transaction, cancellationToken);
            var applied = new List<string>();
            var transitionCount = 0;
            var outboxCount = 0;

            foreach (var batch in batches)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var observations = await ReadObservationsAsync(
                    connection, transaction, batch.BatchId, cancellationToken);
                var nextRevision = checked(stateRevision + 1);
                var visibleChanged = !initialized;
                var seen = observations.Select(item => item.NormalizedPath)
                    .ToHashSet(StringComparer.OrdinalIgnoreCase);

                foreach (var observation in observations)
                {
                    if (observation.Invalidated)
                    {
                        var invalidated = await ReadCurrentSaveAsync(
                            connection, transaction, observation.NormalizedPath, cancellationToken);
                        if (invalidated is not null)
                        {
                            var transitionId = Guid.NewGuid().ToString("D");
                            await InsertTransitionAsync(
                                connection, transaction, transitionId, batch.BatchId,
                                observation.NormalizedPath, "SaveInvalidated",
                                "Present", "Removed", nextRevision, cancellationToken);
                            await InsertOutboxAsync(
                                connection, transaction, transitionId, "ClearTarget",
                                ToBackupTarget(invalidated), batch.RunIndex, cancellationToken);
                            transitionCount++;
                            outboxCount++;
                        }
                        visibleChanged |= await DeleteCurrentSaveAsync(
                            connection, transaction, observation.NormalizedPath, cancellationToken);
                        await DeleteObservationStateAsync(
                            connection, transaction, observation.NormalizedPath, cancellationToken);
                        continue;
                    }

                    var debounce = await ReadDebounceAsync(
                        connection, transaction, observation.NormalizedPath, cancellationToken);
                    var previousConfirmed = debounce.Confirmed;
                    var confirmed = debounce.Confirmed;
                    var candidate = debounce.Candidate;
                    var count = debounce.Count;
                    if (observation.Activity != ActivityState.Unknown)
                    {
                        if (observation.Activity == confirmed)
                        {
                            candidate = observation.Activity;
                            count = 0;
                        }
                        else if (observation.Activity == candidate)
                        {
                            count++;
                        }
                        else
                        {
                            candidate = observation.Activity;
                            count = 1;
                        }

                        if (count >= 2)
                        {
                            confirmed = candidate;
                            count = 0;
                        }
                    }

                    await WriteDebounceAsync(
                        connection, transaction, observation.NormalizedPath,
                        confirmed, candidate, count, cancellationToken);
                    var current = await ReadCurrentSaveAsync(
                        connection, transaction, observation.NormalizedPath, cancellationToken);
                    var previousCharacter = current?.Character ?? CharacterState.Unknown;
                    var character = observation.Character == CharacterState.Unknown
                        ? previousCharacter
                        : observation.Character;
                    var desired = new CurrentSaveState(
                        observation.NormalizedPath,
                        observation.Mode,
                        observation.DisplayName,
                        confirmed,
                        character,
                        Stale: observation.ActivityLaneStatus != LaneStatus.Succeeded,
                        ChangedRevision: nextRevision,
                        observation.LastPlayedUtc ?? current?.LastPlayedUtc);
                    // A timestamp is evidence of a matching confirmed probe, not merely of
                    // replaying a batch or retaining a previous value during debounce/failure.
                    var verified = observation.ActivityLaneStatus == LaneStatus.Succeeded
                        && observation.Activity != ActivityState.Unknown && observation.Activity == confirmed;
                    var observedUtc = verified ? batch.StartedUtc : current?.ObservedUtc ?? DateTimeOffset.MinValue;
                    if (!SemanticallyEqual(current, desired))
                    {
                        visibleChanged = true;
                        await UpsertCurrentSaveAsync(
                            connection, transaction, desired, observedUtc, cancellationToken);
                    }
                    else if (verified)
                    {
                        // Fresh evidence must be persisted even when the semantic revision does
                        // not change (e.g. still playing the same save after restarting the app).
                        await using var observed = connection.CreateCommand();
                        observed.Transaction = transaction;
                        observed.CommandText = "UPDATE current_save_state SET observed_utc=$time WHERE path=$path;";
                        observed.Parameters.AddWithValue("$time", observedUtc.ToString("O"));
                        observed.Parameters.AddWithValue("$path", observation.NormalizedPath);
                        await observed.ExecuteNonQueryAsync(cancellationToken);
                    }

                    if (previousConfirmed != confirmed
                        && confirmed is ActivityState.Active or ActivityState.Inactive)
                    {
                        var transitionId = Guid.NewGuid().ToString("D");
                        await InsertTransitionAsync(
                            connection, transaction, transitionId, batch.BatchId,
                            observation.NormalizedPath, "Activity",
                            previousConfirmed.ToString(), confirmed.ToString(),
                            nextRevision, cancellationToken);
                        transitionCount++;
                        var commandValue = confirmed switch
                        {
                            ActivityState.Active => "ActivateTarget",
                            ActivityState.Inactive when previousConfirmed == ActivityState.Active => "ClearTarget",
                            _ => null,
                        };
                        if (commandValue is not null)
                        {
                            await InsertOutboxAsync(
                                connection, transaction, transitionId, commandValue,
                                ToBackupTarget(observation),
                                batch.RunIndex, cancellationToken);
                            outboxCount++;
                        }
                    }

                    if (previousCharacter != character
                        && previousCharacter is CharacterState.Alive or CharacterState.Dead
                        && character is CharacterState.Alive or CharacterState.Dead)
                    {
                        var transitionId = Guid.NewGuid().ToString("D");
                        await InsertTransitionAsync(
                            connection,
                            transaction,
                            transitionId,
                            batch.BatchId,
                            observation.NormalizedPath,
                            "Character",
                            previousCharacter.ToString(),
                            character.ToString(),
                            nextRevision,
                            cancellationToken);
                        transitionCount++;
                        // Persisted character changes update save metadata only. Live death commands come from JVM facts.

                    }
                }

                if (batch.DiscoveryComplete)
                {
                    var missing = (await ReadAllCurrentSavesAsync(
                            connection, transaction, cancellationToken))
                        .Where(item => !seen.Contains(item.NormalizedPath)).ToArray();
                    foreach (var removed in missing)
                    {
                        var transitionId = Guid.NewGuid().ToString("D");
                        await InsertTransitionAsync(
                            connection, transaction, transitionId, batch.BatchId,
                            removed.NormalizedPath, "SaveInvalidated", "Present", "Removed",
                            nextRevision, cancellationToken);
                        await InsertOutboxAsync(
                            connection, transaction, transitionId, "ClearTarget",
                            ToBackupTarget(removed), batch.RunIndex, cancellationToken);
                        transitionCount++;
                        outboxCount++;
                    }
                }
                visibleChanged |= await ReconcileMissingSavesAsync(
                    connection, transaction, seen, batch.DiscoveryComplete,
                    nextRevision, cancellationToken);
                var desiredGame = await ComputeGameStateAsync(
                    connection, transaction, batch.DiscoveryComplete, cancellationToken);
                var currentGame = await ReadGameStateAsync(connection, transaction, cancellationToken);
                var activeSaves = (await ReadAllCurrentSavesAsync(
                        connection, transaction, cancellationToken))
                    .Where(item => item.Activity == ActivityState.Active && !item.Stale)
                    .OrderBy(item => item.NormalizedPath, StringComparer.OrdinalIgnoreCase)
                    .ToArray();
                // Only on entering the ambiguous state: it is stored below, and repeating the command
                // every collection (every few seconds, for as long as two saves read as open) only
                // added rows that are never removed.
                if (activeSaves.Length > 1 && currentGame != GameState.Ambiguous)
                {
                    var transitionId = Guid.NewGuid().ToString("D");
                    await InsertTransitionAsync(
                        connection, transaction, transitionId, batch.BatchId,
                        activeSaves[0].NormalizedPath, "ActivitySet", "Single", "Ambiguous",
                        nextRevision, cancellationToken);
                    await InsertOutboxAsync(
                        connection, transaction, transitionId, "SuspendAmbiguous",
                        ToBackupTarget(activeSaves[0]), batch.RunIndex, cancellationToken);
                    transitionCount++;
                    outboxCount++;
                }
                else if (currentGame == GameState.Ambiguous && activeSaves.Length == 1)
                {
                    var transitionId = Guid.NewGuid().ToString("D");
                    await InsertTransitionAsync(
                        connection, transaction, transitionId, batch.BatchId,
                        activeSaves[0].NormalizedPath, "ActivitySet", "Ambiguous", "Single",
                        nextRevision, cancellationToken);
                    await InsertOutboxAsync(
                        connection, transaction, transitionId, "ActivateTarget",
                        ToBackupTarget(activeSaves[0]), batch.RunIndex, cancellationToken);
                    transitionCount++;
                    outboxCount++;
                }
                if (currentGame != desiredGame)
                {
                    visibleChanged = true;
                    await WriteGameStateAsync(
                        connection, transaction, desiredGame, nextRevision, cancellationToken);
                }

                if (visibleChanged)
                {
                    stateRevision = nextRevision;
                    await using var update = connection.CreateCommand();
                    update.Transaction = transaction;
                    update.CommandText =
                        "UPDATE state_info SET state_revision=$revision, initialized=1 WHERE singleton=1;";
                    update.Parameters.AddWithValue("$revision", stateRevision);
                    await update.ExecuteNonQueryAsync(cancellationToken);
                }

                initialized = true;
                await using var delete = connection.CreateCommand();
                delete.Transaction = transaction;
                delete.CommandText = "DELETE FROM pending_batches WHERE batch_id=$batch;";
                delete.Parameters.AddWithValue("$batch", batch.BatchId);
                await delete.ExecuteNonQueryAsync(cancellationToken);
                applied.Add(batch.BatchId);
            }

            transaction.Commit();
            return new ReactorResult(applied, beforeRevision, stateRevision, transitionCount, outboxCount);
        }
        catch
        {
            transaction.Rollback();
            throw;
        }
    }

    private sealed record PendingBatch(string BatchId, long RunIndex, DateTimeOffset StartedUtc, bool DiscoveryComplete);
    private sealed record Debounce(ActivityState Confirmed, ActivityState Candidate, int Count);

    private static async Task<(long Revision, bool Initialized)> ReadStateInfoAsync(
        SqliteConnection connection, SqliteTransaction transaction, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT state_revision,initialized FROM state_info WHERE singleton=1;";
        await using var reader = await command.ExecuteReaderAsync(token);
        await reader.ReadAsync(token);
        return (reader.GetInt64(0), reader.GetInt64(1) != 0);
    }

    private static async Task<List<PendingBatch>> ReadBatchesAsync(
        SqliteConnection connection, SqliteTransaction transaction, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "SELECT batch_id,run_index,started_utc,discovery_complete FROM pending_batches ORDER BY created_utc,batch_id;";
        await using var reader = await command.ExecuteReaderAsync(token);
        var result = new List<PendingBatch>();
        while (await reader.ReadAsync(token))
        {
            result.Add(new PendingBatch(reader.GetString(0), reader.GetInt64(1),
                DateTimeOffset.Parse(reader.GetString(2), CultureInfo.InvariantCulture),
                reader.GetInt64(3) != 0));
        }

        return result;
    }

    private static async Task<List<SaveObservation>> ReadObservationsAsync(
        SqliteConnection connection, SqliteTransaction transaction, string batchId, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT path,mode,display_name,has_players_db,invalidated,activity,
                   character_state,activity_lane_status,character_lane_status,error_code,
                   last_played_utc
            FROM pending_save_observations WHERE batch_id=$batch ORDER BY path;
            """;
        command.Parameters.AddWithValue("$batch", batchId);
        await using var reader = await command.ExecuteReaderAsync(token);
        var result = new List<SaveObservation>();
        while (await reader.ReadAsync(token))
        {
            result.Add(new SaveObservation(
                reader.GetString(0), reader.GetString(1), reader.GetString(2),
                reader.GetInt64(3) != 0, reader.GetInt64(4) != 0,
                Enum.Parse<ActivityState>(reader.GetString(5)),
                Enum.Parse<CharacterState>(reader.GetString(6)),
                Enum.Parse<LaneStatus>(reader.GetString(7)),
                Enum.Parse<LaneStatus>(reader.GetString(8)),
                reader.IsDBNull(9) ? null : reader.GetString(9),
                reader.IsDBNull(10) ? null : DateTimeOffset.Parse(
                    reader.GetString(10), CultureInfo.InvariantCulture)));
        }

        return result;
    }

    private static async Task<Debounce> ReadDebounceAsync(
        SqliteConnection connection, SqliteTransaction transaction, string path, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "SELECT confirmed_activity,candidate_activity,consecutive_count FROM save_observation_state WHERE path=$path;";
        command.Parameters.AddWithValue("$path", path);
        await using var reader = await command.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token)
            ? new Debounce(Enum.Parse<ActivityState>(reader.GetString(0)),
                Enum.Parse<ActivityState>(reader.GetString(1)), reader.GetInt32(2))
            : new Debounce(ActivityState.Unknown, ActivityState.Unknown, 0);
    }

    private static async Task WriteDebounceAsync(
        SqliteConnection connection, SqliteTransaction transaction, string path,
        ActivityState confirmed, ActivityState candidate, int count, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO save_observation_state VALUES($path,$confirmed,$candidate,$count)
            ON CONFLICT(path) DO UPDATE SET confirmed_activity=excluded.confirmed_activity,
                candidate_activity=excluded.candidate_activity,consecutive_count=excluded.consecutive_count;
            """;
        command.Parameters.AddWithValue("$path", path);
        command.Parameters.AddWithValue("$confirmed", confirmed.ToString());
        command.Parameters.AddWithValue("$candidate", candidate.ToString());
        command.Parameters.AddWithValue("$count", count);
        await command.ExecuteNonQueryAsync(token);
    }

    private static async Task<CurrentSaveState?> ReadCurrentSaveAsync(
        SqliteConnection connection, SqliteTransaction transaction, string path, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "SELECT mode,display_name,activity,character_state,stale,changed_revision,last_played_utc,observed_utc "
            + "FROM current_save_state WHERE path=$path;";
        command.Parameters.AddWithValue("$path", path);
        await using var reader = await command.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token)
            ? new CurrentSaveState(path, reader.GetString(0), reader.GetString(1),
                Enum.Parse<ActivityState>(reader.GetString(2)),
                Enum.Parse<CharacterState>(reader.GetString(3)), reader.GetInt64(4) != 0,
                reader.GetInt64(5),
                reader.IsDBNull(6) ? null : DateTimeOffset.Parse(
                    reader.GetString(6), CultureInfo.InvariantCulture),
                DateTimeOffset.Parse(reader.GetString(7), CultureInfo.InvariantCulture))
            : null;
    }

    private static bool SemanticallyEqual(CurrentSaveState? left, CurrentSaveState right) =>
        left is not null
        && left.Mode == right.Mode
        && left.DisplayName == right.DisplayName
        && left.Activity == right.Activity
        && left.Character == right.Character
        && left.Stale == right.Stale
        && left.LastPlayedUtc == right.LastPlayedUtc;

    private static async Task UpsertCurrentSaveAsync(
        SqliteConnection connection, SqliteTransaction transaction, CurrentSaveState state,
        DateTimeOffset observedUtc, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO current_save_state(
                path,mode,display_name,activity,character_state,stale,
                changed_revision,observed_utc,last_played_utc)
            VALUES($path,$mode,$name,$activity,$character,$stale,$revision,$observed,$lastPlayed)
            ON CONFLICT(path) DO UPDATE SET mode=excluded.mode,display_name=excluded.display_name,
                activity=excluded.activity,character_state=excluded.character_state,
                stale=excluded.stale,changed_revision=excluded.changed_revision,
                observed_utc=excluded.observed_utc,last_played_utc=excluded.last_played_utc;
            """;
        command.Parameters.AddWithValue("$path", state.NormalizedPath);
        command.Parameters.AddWithValue("$mode", state.Mode);
        command.Parameters.AddWithValue("$name", state.DisplayName);
        command.Parameters.AddWithValue("$activity", state.Activity.ToString());
        command.Parameters.AddWithValue("$character", state.Character.ToString());
        command.Parameters.AddWithValue("$stale", state.Stale ? 1 : 0);
        command.Parameters.AddWithValue("$revision", state.ChangedRevision);
        command.Parameters.AddWithValue("$observed", observedUtc.ToString("O"));
        command.Parameters.AddWithValue(
            "$lastPlayed", (object?)state.LastPlayedUtc?.ToString("O") ?? DBNull.Value);
        await command.ExecuteNonQueryAsync(token);
    }

    private static async Task<bool> DeleteCurrentSaveAsync(
        SqliteConnection connection, SqliteTransaction transaction, string path, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "DELETE FROM current_save_state WHERE path=$path;";
        command.Parameters.AddWithValue("$path", path);
        return await command.ExecuteNonQueryAsync(token) != 0;
    }

    private static async Task DeleteObservationStateAsync(
        SqliteConnection connection, SqliteTransaction transaction, string path, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "DELETE FROM save_observation_state WHERE path=$path;";
        command.Parameters.AddWithValue("$path", path);
        await command.ExecuteNonQueryAsync(token);
    }

    private static async Task<bool> ReconcileMissingSavesAsync(
        SqliteConnection connection, SqliteTransaction transaction, HashSet<string> seen,
        bool complete, long revision, CancellationToken token)
    {
        await using var query = connection.CreateCommand();
        query.Transaction = transaction;
        query.CommandText = "SELECT path,stale FROM current_save_state;";
        await using var reader = await query.ExecuteReaderAsync(token);
        var missing = new List<(string Path, bool Stale)>();
        while (await reader.ReadAsync(token))
        {
            var path = reader.GetString(0);
            if (!seen.Contains(path)) missing.Add((path, reader.GetInt64(1) != 0));
        }
        await reader.DisposeAsync();
        var changed = false;
        foreach (var item in missing)
        {
            await using var command = connection.CreateCommand();
            command.Transaction = transaction;
            if (complete)
            {
                command.CommandText = "DELETE FROM current_save_state WHERE path=$path; DELETE FROM save_observation_state WHERE path=$path;";
            }
            else if (!item.Stale)
            {
                command.CommandText = "UPDATE current_save_state SET stale=1,changed_revision=$revision WHERE path=$path;";
                command.Parameters.AddWithValue("$revision", revision);
            }
            else
            {
                continue;
            }
            command.Parameters.AddWithValue("$path", item.Path);
            await command.ExecuteNonQueryAsync(token);
            changed = true;
        }
        return changed;
    }

    private static async Task<GameState> ComputeGameStateAsync(
        SqliteConnection connection, SqliteTransaction transaction, bool complete, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            SELECT
                (SELECT COUNT(*) FROM current_save_state WHERE activity='Active' AND stale=0),
                EXISTS(SELECT 1 FROM current_save_state WHERE activity='Unknown' OR stale<>0);
            """;
        await using var reader = await command.ExecuteReaderAsync(token);
        await reader.ReadAsync(token);
        var activeCount = reader.GetInt64(0);
        var anyUnknown = reader.GetInt64(1) != 0;
        return activeCount > 1
            ? GameState.Ambiguous
            : activeCount == 1
            ? GameState.Playing
            : !complete || anyUnknown ? GameState.Unknown : GameState.NotPlaying;
    }

    private static async Task<IReadOnlyList<CurrentSaveState>> ReadAllCurrentSavesAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "SELECT path,mode,display_name,activity,character_state,stale,changed_revision,last_played_utc "
            + "FROM current_save_state;";
        await using var reader = await command.ExecuteReaderAsync(token);
        var result = new List<CurrentSaveState>();
        while (await reader.ReadAsync(token))
        {
            result.Add(new CurrentSaveState(
                reader.GetString(0), reader.GetString(1), reader.GetString(2),
                Enum.Parse<ActivityState>(reader.GetString(3)),
                Enum.Parse<CharacterState>(reader.GetString(4)), reader.GetInt64(5) != 0,
                reader.GetInt64(6),
                reader.IsDBNull(7) ? null : DateTimeOffset.Parse(
                    reader.GetString(7), CultureInfo.InvariantCulture)));
        }
        return result;
    }

    private static async Task<GameState> ReadGameStateAsync(
        SqliteConnection connection, SqliteTransaction transaction, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT game_state FROM current_game_state WHERE singleton=1;";
        var value = await command.ExecuteScalarAsync(token);
        return value is null ? GameState.Unknown : Enum.Parse<GameState>((string)value);
    }

    private static async Task WriteGameStateAsync(
        SqliteConnection connection, SqliteTransaction transaction, GameState game,
        long revision, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT INTO current_game_state VALUES(1,$game,$revision)
            ON CONFLICT(singleton) DO UPDATE SET game_state=excluded.game_state,changed_revision=excluded.changed_revision;
            """;
        command.Parameters.AddWithValue("$game", game.ToString());
        command.Parameters.AddWithValue("$revision", revision);
        await command.ExecuteNonQueryAsync(token);
    }

    private static async Task InsertTransitionAsync(
        SqliteConnection connection, SqliteTransaction transaction, string id, string batchId,
        string path, string kind, string previous, string current, long revision,
        CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            "INSERT INTO state_transitions VALUES($id,$batch,$path,$kind,$previous,$current,$revision,$created);";
        command.Parameters.AddWithValue("$id", id);
        command.Parameters.AddWithValue("$batch", batchId);
        command.Parameters.AddWithValue("$path", path);
        command.Parameters.AddWithValue("$kind", kind);
        command.Parameters.AddWithValue("$previous", previous);
        command.Parameters.AddWithValue("$current", current);
        command.Parameters.AddWithValue("$revision", revision);
        command.Parameters.AddWithValue("$created", DateTimeOffset.UtcNow.ToString("O"));
        await command.ExecuteNonQueryAsync(token);
    }

    private static async Task InsertOutboxAsync(
        SqliteConnection connection, SqliteTransaction transaction, string transitionId,
        string commandValue, BackupTargetIdentity target, long runIndex, CancellationToken token)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText =
            """
            INSERT OR IGNORE INTO scheduler_outbox(
                message_id,idempotency_key,command,save_id,source_key,source_path,
                transition_id,state_run_index,acknowledged_utc,created_utc)
            VALUES($id,$key,$command,$save,$source,$path,$transition,$run,NULL,$created);
            """;
        command.Parameters.AddWithValue("$id", Guid.NewGuid().ToString("D"));
        command.Parameters.AddWithValue("$key", $"state-transition:{transitionId}");
        command.Parameters.AddWithValue("$command", commandValue);
        command.Parameters.AddWithValue("$save", target.SaveId);
        command.Parameters.AddWithValue("$source", target.SourceKey);
        command.Parameters.AddWithValue("$path", target.SourcePath);
        command.Parameters.AddWithValue("$transition", transitionId);
        command.Parameters.AddWithValue("$run", runIndex);
        command.Parameters.AddWithValue("$created", DateTimeOffset.UtcNow.ToString("O"));
        await command.ExecuteNonQueryAsync(token);
    }

    private sealed record BackupTargetIdentity(string SaveId, string SourceKey, string SourcePath);

    private static BackupTargetIdentity ToBackupTarget(SaveObservation observation) =>
        new(CreateSaveId(observation.Mode, observation.DisplayName),
            CreateSaveId(observation.Mode, observation.DisplayName), observation.NormalizedPath);

    private static BackupTargetIdentity ToBackupTarget(CurrentSaveState state) =>
        new(CreateSaveId(state.Mode, state.DisplayName),
            CreateSaveId(state.Mode, state.DisplayName), state.NormalizedPath);

    private static string CreateSaveId(string mode, string displayName) =>
        $"{mode.Trim().Replace('\\', '/')}/{displayName.Trim().Replace('\\', '/')}";
}
