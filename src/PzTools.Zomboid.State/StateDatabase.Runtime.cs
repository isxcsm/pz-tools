using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.Zomboid.State;

public sealed partial class StateDatabase
{
    private const string RuntimeSchema = """
        CREATE TABLE IF NOT EXISTS runtime_identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1), epoch TEXT NOT NULL) STRICT;
        INSERT OR IGNORE INTO runtime_identity VALUES(1, lower(hex(randomblob(16))));
        CREATE TABLE IF NOT EXISTS runtime_pending(singleton INTEGER PRIMARY KEY CHECK(singleton=1), body TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS runtime_current(singleton INTEGER PRIMARY KEY CHECK(singleton=1), semantic_key TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL) STRICT;
        CREATE TABLE IF NOT EXISTS runtime_outbox(revision INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT;
        """;

    public async Task StageRuntimeAsync(RuntimeObservation observation, CancellationToken token = default)
    {
        observation.Validate();
        await using var connection = await OpenAsync(token);
        await using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO runtime_pending VALUES(1,$body) ON CONFLICT(singleton) DO UPDATE SET body=$body;";
        command.Parameters.AddWithValue("$body", RuntimeJson.Write(observation));
        await command.ExecuteNonQueryAsync(token);
    }

    // Reducer owns the authoritative commit; a pending observation is not a published state.
    internal async Task<RuntimeObservation?> ReduceRuntimeAsync(CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        using var transaction = connection.BeginTransaction();
        await using var command = connection.CreateCommand(); command.Transaction = transaction;
        command.CommandText = "SELECT body FROM runtime_pending WHERE singleton=1;";
        var pending = await command.ExecuteScalarAsync(token) as string;
        if (pending is null) return null;
        var observation = RuntimeJson.Read<RuntimeObservation>(pending).Validate();
        command.CommandText = "SELECT epoch FROM runtime_identity WHERE singleton=1;";
        var authority = (string)(await command.ExecuteScalarAsync(token))!;
        observation = observation with { AuthorityEpoch = authority };
        command.CommandText = "SELECT body FROM runtime_current WHERE singleton=1;";
        var existing = await command.ExecuteScalarAsync(token) as string;
        var prior = existing is null ? null : RuntimeJson.Read<RuntimeObservation>(existing);
        if (prior?.SemanticKey != observation.SemanticKey)
        {
            command.CommandText = "UPDATE state_info SET state_revision=state_revision+1 WHERE singleton=1; SELECT state_revision FROM state_info WHERE singleton=1;";
            var revision = Convert.ToInt64(await command.ExecuteScalarAsync(token), System.Globalization.CultureInfo.InvariantCulture);
            observation = observation with { StateRevision = revision };
            command.CommandText = "INSERT INTO runtime_current VALUES(1,$key,$revision,$body) ON CONFLICT(singleton) DO UPDATE SET semantic_key=$key,revision=$revision,body=$body; INSERT INTO runtime_outbox VALUES($revision,$body);";
            command.Parameters.AddWithValue("$key", observation.SemanticKey);
            command.Parameters.AddWithValue("$revision", revision);
            command.Parameters.AddWithValue("$body", RuntimeJson.Write(observation));
            await command.ExecuteNonQueryAsync(token);
        }
        else observation = observation with { StateRevision = prior!.StateRevision };
        command.CommandText = "DELETE FROM runtime_pending WHERE singleton=1;";
        await command.ExecuteNonQueryAsync(token);
        token.ThrowIfCancellationRequested(); transaction.Commit();
        return observation;
    }
    public async Task<IReadOnlyList<RuntimeObservation>> ReadRuntimeOutboxAsync(CancellationToken token = default)
    {
        await using var connection = await OpenAsync(token);
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT body FROM runtime_outbox ORDER BY revision LIMIT 64;";
        var results = new List<RuntimeObservation>();
        await using var reader = await command.ExecuteReaderAsync(token);
        while (await reader.ReadAsync(token)) results.Add(RuntimeJson.Read<RuntimeObservation>(reader.GetString(0)));
        return results;
    }
    public async Task AcknowledgeRuntimeAsync(long revision, CancellationToken token = default)
    {
        await using var connection = await OpenAsync(token); await using var command = connection.CreateCommand();
        command.CommandText = "DELETE FROM runtime_outbox WHERE revision=$revision;";
        command.Parameters.AddWithValue("$revision", revision); await command.ExecuteNonQueryAsync(token);
    }
}

public sealed class RuntimeStateReactor
{
    public Task<RuntimeObservation?> RunAsync(StateDatabase database, CancellationToken token = default) => database.ReduceRuntimeAsync(token);
}