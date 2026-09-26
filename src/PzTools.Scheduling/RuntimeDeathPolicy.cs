using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Scheduling;

/// <summary>Live death policy; persisted save-file flags never enter this path.</summary>
public static class RuntimeDeathPolicy
{
    internal const string Prefix = "runtime-death:";
    public static string? EventKey(RuntimeSnapshot? value) => value is
        { IsWorldReady: true, CharacterLife: RuntimeCharacterLife.Dead, CharacterSession: not null, DeathId: not null }
        ? $"{Prefix}{value.ProcessSession}:{value.WorldSession}:{value.CharacterSession}:{value.DeathId}" : null;
    public static bool ReadEnabled(string databasePath) => ComponentConfiguration.Load(databasePath, "state-reactor", null,
        Path.Combine(PzToolsPathLayout.CreateDefault().DataRoot, "settings.toml")).GetBoolean("state", "backup_on_death", false);
}

public sealed partial class SchedulerDatabase
{
    private static async Task ApplyDeathAsync(SqliteConnection c, SqliteTransaction t, RuntimeObservation observation,
        BackupTarget? target, bool enabled, CancellationToken token)
    {
        if (!observation.IsFresh || RuntimeDeathPolicy.EventKey(observation.Snapshot) is not { } key) return;
        await using var q = c.CreateCommand(); q.Transaction = t;
        q.CommandText = "SELECT event_key FROM runtime_death_cursor WHERE singleton=1;";
        if ((string?)await q.ExecuteScalarAsync(token) == key) return;
        // Advance even when disabled: enabling later must not replay the death of an old character.
        q.CommandText = "INSERT INTO runtime_death_cursor VALUES(1,$key) ON CONFLICT(singleton) DO UPDATE SET event_key=$key;";
        q.Parameters.AddWithValue("$key", key); await q.ExecuteNonQueryAsync(token);
        var control = await TryReadControlAsync(c, t, token);
        if (!enabled || target is null || control is not { AutomaticEnabled: true }) return;
        await InsertPendingAsync(c, t, new BackupTargetCommand(key, BackupTargetCommandKind.RunOnceNow, target),
            BackupAdmissionKind.RunOnce, token);
        await IncrementRevisionAsync(c, t, token);
    }
    private static async Task<RuntimeSaveTicket?> ReadDeathTicketAsync(SqliteConnection c, SqliteTransaction t,
        string eventKey, string sourcePath, CancellationToken token)
    {
        await using var q = c.CreateCommand(); q.Transaction = t;
        q.CommandText = "SELECT body FROM runtime_facts WHERE singleton=1;";
        var text = await q.ExecuteScalarAsync(token) as string;
        var observation = text is null ? null : RuntimeJson.Read<RuntimeObservation>(text);
        if (observation?.Snapshot is not { } s || !observation.IsFresh
            || RuntimeDeathPolicy.EventKey(s) != eventKey || !StringComparer.OrdinalIgnoreCase.Equals(s.SavePath, sourcePath)) return null;
        return new(s.ProcessSession, s.ObserverEpoch, s.WorldSession, s.ClockEpoch, s.EligibilityEpoch,
            0, 1, s.DeathId!, s.CharacterSession, s.DeathId);
    }
}