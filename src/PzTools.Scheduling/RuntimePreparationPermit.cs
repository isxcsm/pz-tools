using Microsoft.Data.Sqlite;

namespace PzTools.Scheduling;

/// <summary>Read-only execution fence for an already admitted worker. No schema creation or policy mutation.</summary>
public static class RuntimePreparationPermit
{
    public static async Task<bool> IsCurrentAsync(string databasePath, long generation, string sourcePath,
        CancellationToken token = default)
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
            return await reader.ReadAsync(token) && reader.GetInt64(0) == 1 && reader.GetInt64(1) == generation
                && !reader.IsDBNull(2) && StringComparer.OrdinalIgnoreCase.Equals(reader.GetString(2), Path.GetFullPath(sourcePath))
                && reader.GetInt64(3) == 1;
        }
        catch (SqliteException) { return false; }
        catch (IOException) { return false; }
    }
}