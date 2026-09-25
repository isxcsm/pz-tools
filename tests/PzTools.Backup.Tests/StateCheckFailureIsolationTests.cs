using Microsoft.Data.Sqlite;
using PzTools.Process.Contracts;
using PzTools.Scheduling;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class StateCheckFailureIsolationTests
{
    [Fact]
    public async Task TemporaryCollectorFailure_DoesNotStopScheduler_AndNextTickRecovers()
    {
        using var temp = new TempDirectory();
        Directory.CreateDirectory(temp.GetPath("saves"));
        var state = await StateDatabase.CreateOrOpenAsync(temp.GetPath("state.db"));
        var schedulerDb = await SchedulerDatabase.CreateOrOpenAsync(temp.GetPath("scheduler.db"));
        var pipeline = new StateCheckPipeline();
        long run = 0;
        var scheduler = new StateScheduler(schedulerDb, TimeSpan.FromSeconds(3),
            _ => Task.FromResult(++run), (id, token) => pipeline.RunAsync(state, temp.GetPath("saves"), id, token));
        await ExecuteAsync("CREATE TRIGGER fail_collection BEFORE INSERT ON pending_batches BEGIN SELECT RAISE(ABORT,'fixture IO failure'); END;");
        var now = DateTimeOffset.UtcNow;
        var failure = await scheduler.TickAsync(now, force: true);
        Assert.True(failure.Due);
        Assert.Equal(ProcessOutcome.Failed, failure.Runner!.Outcome);
        Assert.Equal("state-check-failed", failure.Runner.FailureCode);
        Assert.False(await state.HasPendingBatchesAsync());
        await ExecuteAsync("DROP TRIGGER fail_collection;");
        var recovered = await scheduler.TickAsync(now.AddSeconds(4), force: true);
        Assert.Equal(ProcessOutcome.Succeeded, recovered.Runner!.Outcome);
        Assert.False(await state.HasPendingBatchesAsync());
        Assert.True((await state.ReadCurrentStateIfChangedAsync(-1)).Modified);
        Assert.Equal(2, run);

        async Task ExecuteAsync(string sql)
        {
            await using var connection = new SqliteConnection($"Data Source={state.DatabasePath};Pooling=False");
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = sql;
            await command.ExecuteNonQueryAsync();
        }
    }
}
