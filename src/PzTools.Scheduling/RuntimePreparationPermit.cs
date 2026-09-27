using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Scheduling;

/// <summary>Read-only execution fence for an already admitted worker. No schema creation or policy mutation.</summary>
public static class RuntimePreparationPermit
{
    public static async Task<bool> IsCurrentAsync(string databasePath, long generation, string sourcePath,
        CancellationToken token = default, RuntimeSaveTicket? runtimeTicket = null)
    {
        if (!Path.IsPathFullyQualified(databasePath) || generation < 0) return false;
        try
        {
            await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            { DataSource = databasePath, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 1 }.ToString());
            await connection.OpenAsync(token);
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT c.automatic_enabled,c.generation,c.current_source_path,r.enabled "
                + "FROM backup_scheduler_control c JOIN runtime_options r ON r.singleton=c.singleton WHERE c.singleton=1;";
            await using var reader = await command.ExecuteReaderAsync(token);
            if (!await reader.ReadAsync(token) || reader.GetInt64(0) != 1 || reader.GetInt64(1) != generation) return false;
            if (runtimeTicket is not { IsDeath: true })
                return !reader.IsDBNull(2) && StringComparer.OrdinalIgnoreCase.Equals(reader.GetString(2), Path.GetFullPath(sourcePath))
                    && reader.GetInt64(3) == 1;
            await reader.DisposeAsync();
            if (!RuntimeDeathPolicy.ReadEnabled(databasePath)) return false;
            command.CommandText = "SELECT body FROM runtime_facts WHERE singleton=1;";
            var text = await command.ExecuteScalarAsync(token) as string;
            var facts = text is null ? null : RuntimeJson.Read<RuntimeObservation>(text);
            return facts is { IsFresh: true, Snapshot: not null } && runtimeTicket.MatchesDeath(facts.Snapshot)
                && StringComparer.OrdinalIgnoreCase.Equals(facts.Snapshot.SavePath, Path.GetFullPath(sourcePath));
        }
        catch (SqliteException) { return false; }
        catch (IOException) { return false; }
    }
}