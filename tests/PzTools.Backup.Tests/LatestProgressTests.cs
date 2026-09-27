using PzTools.App.Core;

namespace PzTools.Backup.Tests;

public sealed class LatestProgressTests
{
    [Fact]
    public void SlowConsumerGetsOnlyLatestSnapshotAndNeverABacklog()
    {
        var progress = new LatestProgress<SaveDeletionProgress>();
        for (var i = 0; i < 100_000; i++)
            progress.Report(new(SaveDeletionPhase.DeletingFiles, i, 100_000));
        Assert.Equal(99_999, progress.TakeLatest()!.CompletedItems);
        Assert.Null(progress.TakeLatest());
        progress.Report(new(SaveDeletionPhase.DeletingBackups));
        Assert.Equal(SaveDeletionPhase.DeletingBackups, progress.TakeLatest()!.Phase);
        Assert.Null(progress.TakeLatest());
    }

    [Fact]
    public async Task ProducerAndConsumerCanExchangeWithoutLosingTheFinalSnapshot()
    {
        var progress = new LatestProgress<SaveDeletionProgress>();
        var producer = Task.Run(() =>
        {
            for (var i = 0; i <= 100_000; i++)
                progress.Report(new(SaveDeletionPhase.DeletingFiles, i, 100_000));
        });
        long last = -1;
        while (!producer.IsCompleted)
        {
            if (progress.TakeLatest() is { } value)
            {
                Assert.True(value.CompletedItems >= last);
                last = value.CompletedItems;
            }
            await Task.Yield();
        }
        await producer;
        last = progress.TakeLatest()?.CompletedItems ?? last;
        Assert.Equal(100_000, last);
        Assert.Null(progress.TakeLatest());
    }
}
