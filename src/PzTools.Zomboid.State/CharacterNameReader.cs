using Microsoft.Data.Sqlite;

namespace PzTools.Zomboid.State;

public sealed record CharacterSnapshot(
    string? Name, CharacterState State, double? HoursSurvived = null, bool ReadSucceeded = true,
    string? ReadError = null);

/// <summary>One row of a single-player save's localPlayers table.</summary>
public sealed record LocalCharacter(long Id, string Name, bool Dead, double? HoursSurvived);

/// <summary>Reads the selected playable character from one players.db snapshot.</summary>
public sealed class CharacterNameReader
{
    /// <summary>
    /// Every character of a single-player save, by id. Several only with local split screen; the game
    /// reuses a dead character's row for the next one, so earlier characters are not listed.
    /// </summary>
    public async Task<IReadOnlyList<LocalCharacter>> ListLocalAsync(
        string playersDatabasePath,
        CancellationToken cancellationToken = default)
    {
        var connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = playersDatabasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
            DefaultTimeout = 1,
        }.ToString();
        await using var connection = new SqliteConnection(connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var query = connection.CreateCommand();
        query.CommandText = "SELECT id, name, isDead, data, worldversion FROM localPlayers ORDER BY id;";
        var characters = new List<LocalCharacter>();
        await using var reader = await query.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
            characters.Add(new LocalCharacter(
                reader.GetInt64(0),
                reader.IsDBNull(1) ? "" : reader.GetString(1).Trim(),
                !reader.IsDBNull(2) && reader.GetBoolean(2),
                reader.IsDBNull(3) || reader.IsDBNull(4)
                    ? null
                    : PlayerBlobDurationReader.ReadHoursSurvived(reader.GetFieldValue<byte[]>(3), reader.GetInt64(4))));
        return characters;
    }

    public async Task<string?> ReadAsync(
        string playersDatabasePath,
        CancellationToken cancellationToken = default) =>
        (await ReadSnapshotAsync(playersDatabasePath, cancellationToken)).Name;

    public async Task<CharacterSnapshot> ReadSnapshotAsync(
        string playersDatabasePath,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(playersDatabasePath))
            return new CharacterSnapshot(null, CharacterState.Unknown);

        try
        {
            var connectionString = new SqliteConnectionStringBuilder
            {
                DataSource = playersDatabasePath,
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false,
                DefaultTimeout = 1,
            }.ToString();
            await using var connection = new SqliteConnection(connectionString);
            await connection.OpenAsync(cancellationToken);
            await using var timeout = connection.CreateCommand();
            timeout.CommandText = "PRAGMA busy_timeout=100;";
            await timeout.ExecuteNonQueryAsync(cancellationToken);

            CharacterSnapshot? fallback = null;
            foreach (var table in new[] { "localPlayers", "networkPlayers" })
            {
                await using var schema = connection.CreateCommand();
                schema.CommandText = "SELECT name FROM pragma_table_info($table);";
                schema.Parameters.AddWithValue("$table", table);
                var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                await using (var reader = await schema.ExecuteReaderAsync(cancellationToken))
                {
                    while (await reader.ReadAsync(cancellationToken))
                        columns.Add(reader.GetString(0));
                }
                if (!columns.Contains("name")) continue;

                var order = new List<string>();
                if (columns.Contains("isDead"))
                    order.Add("CASE WHEN isDead = 0 THEN 0 ELSE 1 END");
                if (columns.Contains("id")) order.Add("id DESC");
                await using var query = connection.CreateCommand();
                query.CommandText = $"SELECT name, {(columns.Contains("isDead") ? "isDead" : "NULL")}, "
                    + $"{(columns.Contains("data") ? "data" : "NULL")}, "
                    + $"{(columns.Contains("worldversion") ? "worldversion" : "NULL")} "
                    + $"FROM \"{table}\" "
                    + "WHERE name IS NOT NULL AND trim(name) <> ''"
                    + (order.Count == 0 ? "" : " ORDER BY " + string.Join(", ", order))
                    + " LIMIT 1;";
                await using var result = await query.ExecuteReaderAsync(cancellationToken);
                if (!await result.ReadAsync(cancellationToken)) continue;
                var name = result.GetString(0).Trim();
                var state = result.IsDBNull(1)
                    ? CharacterState.Unknown
                    : result.GetInt64(1) == 0 ? CharacterState.Alive : CharacterState.Dead;
                var hoursSurvived = result.IsDBNull(2) || result.IsDBNull(3)
                    ? null
                    : PlayerBlobDurationReader.ReadHoursSurvived(
                        result.GetFieldValue<byte[]>(2), result.GetInt64(3));
                if (state == CharacterState.Alive)
                    return new CharacterSnapshot(name, state, hoursSurvived);
                fallback ??= new CharacterSnapshot(name, state, hoursSurvived);
            }
            if (fallback is not null) return fallback;
            var fallbackState = await new CharacterStateLane().CollectAsync(
                playersDatabasePath, cancellationToken);
            return new CharacterSnapshot(null, fallbackState.State);
        }
        catch (Exception exception) when (exception is SqliteException or IOException or UnauthorizedAccessException)
        {
            return new CharacterSnapshot(null, CharacterState.Unknown, ReadSucceeded: false,
                ReadError: exception.GetType().Name + ": " + exception.Message);
        }
    }
}
