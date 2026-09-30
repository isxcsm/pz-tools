using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Scheduling;

public sealed record RuntimeScheduleStorage(bool Enabled, ActiveTimeScheduleState? Checkpoint, RuntimeObservation? Facts);

public sealed partial class SchedulerDatabase
{
    private const string RuntimeSchema = """
        CREATE TABLE IF NOT EXISTS runtime_options(singleton INTEGER PRIMARY KEY CHECK(singleton=1), enabled INTEGER NOT NULL CHECK(enabled IN(0,1))) STRICT;
        INSERT OR IGNORE INTO runtime_options VALUES(1,0);
        CREATE TABLE IF NOT EXISTS runtime_death_cursor(singleton INTEGER PRIMARY KEY CHECK(singleton=1), event_key TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS runtime_schedule(singleton INTEGER PRIMARY KEY CHECK(singleton=1), generation INTEGER NOT NULL, body TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS runtime_facts(singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL, body TEXT NOT NULL) STRICT;
        """;
    private static async Task<bool> RuntimeEnabledAsync(SqliteConnection c, SqliteTransaction t, CancellationToken token)
    {
        await using var q = c.CreateCommand(); q.Transaction = t;
        q.CommandText = "SELECT enabled FROM runtime_options WHERE singleton=1;";
        return Convert.ToInt64(await q.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture) == 1;
    }
    private static async Task<bool> ConfigureRuntimeCoreAsync(SqliteConnection c, SqliteTransaction t,
        bool enabled, CancellationToken token)
    {
        var previous = await RuntimeEnabledAsync(c,t,token);
        if (previous == enabled) return false;
        await using var q = c.CreateCommand(); q.Transaction = t;
        q.CommandText = "UPDATE runtime_options SET enabled=$enabled WHERE singleton=1; DELETE FROM runtime_schedule;";
        q.Parameters.AddWithValue("$enabled", enabled ? 1 : 0); await q.ExecuteNonQueryAsync(token);
        return true;
    }
    public async Task<RuntimeScheduleStorage> ReadRuntimeScheduleAsync(CancellationToken token = default)
    {
        await using var c = await OpenAsync(token); using var t = c.BeginTransaction(deferred: true);
        bool enabled = await RuntimeEnabledAsync(c,t,token);
        await using var q = c.CreateCommand(); q.Transaction = t;
        q.CommandText = "SELECT body FROM runtime_schedule WHERE singleton=1;";
        var saved = await q.ExecuteScalarAsync(token) as string;
        q.CommandText = "SELECT body FROM runtime_facts WHERE singleton=1;";
        var facts = await q.ExecuteScalarAsync(token) as string;
        t.Commit();
        return new(enabled, saved is null ? null : RuntimeJson.Read<ActiveTimeScheduleState>(saved),
            facts is null ? null : RuntimeJson.Read<RuntimeObservation>(facts));
    }
    /// <summary>
    /// The save the game's file locks last pointed at. Runtime scheduling ignores these weaker
    /// transitions, but they are all that is left when the game itself cannot be observed.
    /// </summary>
    public async Task<BackupTarget?> ReadFileDerivedTargetAsync(CancellationToken token = default)
    {
        await using var c = await OpenAsync(token);
        await using var q = c.CreateCommand();
        q.CommandText = """
            SELECT command,save_id,source_key,source_path FROM backup_target_commands
            WHERE command IN ('ActivateTarget','FinalizeTarget','ClearTarget','SuspendAmbiguous')
            ORDER BY received_utc DESC, rowid DESC LIMIT 1;
            """;
        await using var reader = await q.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token) && reader.GetString(0) == "ActivateTarget"
            ? new(reader.GetString(1), reader.GetString(2), reader.GetString(3)) : null;
    }
    public async Task WriteRuntimeCheckpointAsync(ActiveTimeScheduleState state, CancellationToken token = default)
    {
        await using var c = await OpenAsync(token); using var t = c.BeginTransaction();
        var current = await TryReadControlAsync(c,t,token);
        if (current?.Generation != state.Generation || !await RuntimeEnabledAsync(c,t,token)) return;
        await using var q = c.CreateCommand(); q.Transaction = t;
        q.CommandText = "INSERT INTO runtime_schedule VALUES(1,$generation,$body) ON CONFLICT(singleton) DO UPDATE SET generation=$generation,body=$body;";
        q.Parameters.AddWithValue("$generation", state.Generation); q.Parameters.AddWithValue("$body", RuntimeJson.Write(state));
        await q.ExecuteNonQueryAsync(token); t.Commit();
    }
    public async Task ApplyRuntimeTransitionAsync(RuntimeObservation observation, BackupTarget? resolvedTarget, CancellationToken token = default, bool backupOnDeath = false)
    {
        observation.Validate();
        await using var c = await OpenAsync(token); using var t = c.BeginTransaction();
        await using var q = c.CreateCommand(); q.Transaction = t;
        q.CommandText = "SELECT body FROM runtime_facts WHERE singleton=1;";
        var text = await q.ExecuteScalarAsync(token) as string;
        var previous = text is null ? null : RuntimeJson.Read<RuntimeObservation>(text);
        if (previous is not null && observation.AuthorityEpoch == previous.AuthorityEpoch && observation.StateRevision <= previous.StateRevision) return;
        q.CommandText = "INSERT INTO runtime_facts VALUES(1,$revision,$body) ON CONFLICT(singleton) DO UPDATE SET revision=$revision,body=$body;";
        q.Parameters.AddWithValue("$revision", observation.StateRevision); q.Parameters.AddWithValue("$body", RuntimeJson.Write(observation));
        await q.ExecuteNonQueryAsync(token);
        var control = await TryReadControlAsync(c,t,token);
        if (control is not null && await RuntimeEnabledAsync(c,t,token))
        {
            BackupTarget? target = control.CurrentTarget;
            if (observation.Quality == RuntimeQuality.Offline || observation.IsFresh && observation.Snapshot?.Phase is WorldPhase.Menu or WorldPhase.Unloading)
                target = null;
            else if (observation.IsFresh && observation.Snapshot is { IsWorldReady: true } snapshot)
                target = resolvedTarget;
            bool switched = target != control.CurrentTarget;
            // World/clock epochs fence game execution and the active-time reducer independently.
            // Losing transport quality must not reset the configured interval on reconnect.
            if (switched)
            {
                q.CommandText = "UPDATE backup_scheduler_control SET current_save_id=$id,current_source_key=$id,current_source_path=$path,mode=$mode,generation=generation+1,attempts_remaining=0 WHERE singleton=1; DELETE FROM runtime_schedule; DELETE FROM pending_backup_runs;";
                q.Parameters.AddWithValue("$id", (object?)target?.SaveId ?? DBNull.Value);
                q.Parameters.AddWithValue("$path", (object?)target?.SourcePath ?? DBNull.Value);
                q.Parameters.AddWithValue("$mode", target is null ? "Paused" : "Continuous");
                await q.ExecuteNonQueryAsync(token);
            }
            await IncrementRevisionAsync(c,t,token);
        }
        await ApplyDeathAsync(c, t, observation, resolvedTarget, backupOnDeath, token);
        t.Commit();
    }
}
