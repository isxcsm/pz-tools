using PzTools.App.Core;
using PzTools.Projections;

namespace PzTools.Backup.Tests;

public sealed class OperationCardStackTests
{
    [Fact]
    public void StacksByPriority_ThenOldestOnTop_WithTheNewestUserCardAtTheBottom()
    {
        var cleanup = Operation("maintenance-lane-ArtifactCleanup", 20, OperationStatus.Running);
        var firstAutomatic = Operation("backup-worker", 11, OperationStatus.Succeeded);
        var secondAutomatic = Operation("backup-worker", 15, OperationStatus.Running);
        var restore = Operation("restore", 12, OperationStatus.Succeeded, "restore-worker");
        var export = Operation("export", 18, OperationStatus.Running, "archive-worker");

        var cards = OperationCardStack.Build(
            new([export, cleanup, secondAutomatic, restore, firstAutomatic]), null, 0, limit: 10);

        Assert.Equal(
            [OperationCardGroup.Maintenance, OperationCardGroup.Backup, OperationCardGroup.Backup,
                OperationCardGroup.Restore, OperationCardGroup.Export],
            cards.Select(card => card.Group));
        Assert.Equal([20L, 11, 15, 12, 18], cards.Select(card => card.Operation.RunIndex));
        Assert.Equal(
            [OperationCardTier.Other, OperationCardTier.Backup, OperationCardTier.Backup,
                OperationCardTier.User, OperationCardTier.User],
            cards.Select(card => card.Tier));
    }

    [Fact]
    public void OneBackupIsOneCard_EvenWhenSchedulerAndWorkerBothReportIt()
    {
        var scheduler = Operation("backup-scheduler", 7, OperationStatus.Succeeded);
        var worker = Operation("backup-worker", 7, OperationStatus.Running) with { TotalItems = 10 };

        var card = Assert.Single(OperationCardStack.Build(new([scheduler, worker]), null, 0));

        Assert.Same(worker, card.Operation);
        Assert.Equal(OperationCardTier.Backup, card.Tier);
        // A finished scheduler entry alone still shows the run's result through the worker when present.
        var finished = worker with { Status = OperationStatus.NoChange };
        Assert.Same(finished, Assert.Single(OperationCardStack.Build(new([scheduler, finished]), null, 0)).Operation);
    }

    [Fact]
    public void ManualBackupIsUserWork_AndSitsBelowAnAutomaticBackup()
    {
        var automatic = Operation("backup-worker", 9, OperationStatus.Succeeded);
        var manual = Operation("backup", 8, OperationStatus.Running, "backup-worker");

        var cards = OperationCardStack.Build(new([automatic, manual]), null, 0);

        Assert.Equal([9L, 8], cards.Select(card => card.Operation.RunIndex));
        Assert.Equal(OperationCardTier.User, cards[1].Tier);
    }

    [Fact]
    public void SeparateCleanupProcessesShareOneCard_WorkingWhileAnyOfThemWorks()
    {
        var finished = Operation("maintenance-lane-RevisionReclamation", 30, OperationStatus.Succeeded)
            with { CompletedUtc = DateTimeOffset.UtcNow };
        var running = Operation("maintenance-lane-OrphanBackups", 29, OperationStatus.Running);

        var card = Assert.Single(OperationCardStack.Build(new([finished, running]), null, 0));
        Assert.Equal(OperationCardGroup.Maintenance, card.Group);
        Assert.Same(running, card.Operation);

        // "OrphanBackups" must not be mistaken for a backup because of its name.
        Assert.Equal(OperationCardGroup.Maintenance, OperationCardStack.GroupOf(running));
    }

    [Fact]
    public void UnrelatedBackgroundProducersGetNoCard()
    {
        Assert.Empty(OperationCardStack.Build(new([
            Operation("state-runner", 1, OperationStatus.Running),
            Operation("inspect", 2, OperationStatus.Running, "archive-worker")]), null, 0));
    }

    [Theory]
    [InlineData("restore")]
    [InlineData("import")]
    [InlineData("character-recovery")]
    public void PlaceholderIsReplacedOnlyByItsOwnNewWorkerRun(string kind)
    {
        var local = Operation(kind, 0, OperationStatus.Running, "app") with { OperationId = "mine" };
        var old = local with { RunIndex = 10 };
        var current = local with { RunIndex = 11, TotalItems = 10, TelemetryHealth = TelemetryHealth.Healthy };

        Assert.Same(local, Assert.Single(OperationCardStack.Build(new([old]), local, 10)).Operation);
        Assert.Same(current, Assert.Single(OperationCardStack.Build(new([old, current]), local, 10)).Operation);
    }

    [Fact]
    public void FinishedPlaceholderKeepsItsResult_AndNewerWorkGetsItsOwnCard()
    {
        var failed = Operation("restore", 0, OperationStatus.Failed, "app") with { OperationId = "mine" };
        var staleSameWork = failed with { RunIndex = 11, Status = OperationStatus.Running };
        var next = Operation("export", 13, OperationStatus.Running, "archive-worker");

        var cards = OperationCardStack.Build(new([staleSameWork, next]), failed, 10);

        Assert.Equal(2, cards.Count);
        Assert.Same(next, cards[0].Operation);
        Assert.Same(failed, cards[1].Operation); // The placeholder is the newest user card.
    }

    [Fact]
    public void OverTheLimit_FinishedLowPriorityCardsLeaveFirst_AndActiveWorkNeverLeaves()
    {
        var cleanupDone = Operation("maintenance-lane-ArtifactCleanup", 1, OperationStatus.Succeeded);
        var automaticDone = Operation("backup-worker", 2, OperationStatus.Succeeded);
        var automaticRunning = Operation("backup-worker", 3, OperationStatus.Running);
        var restoreDone = Operation("restore", 4, OperationStatus.Succeeded, "restore-worker");
        var exportRunning = Operation("export", 5, OperationStatus.Running, "archive-worker");
        var all = new OperationsView([cleanupDone, automaticDone, automaticRunning, restoreDone, exportRunning]);

        Assert.Equal([3L, 4, 5], OperationCardStack.Build(all, null, 0, limit: 3).Select(card => card.Operation.RunIndex));
        // Two active cards stay even when the limit is one.
        Assert.Equal([3L, 5], OperationCardStack.Build(all, null, 0, limit: 1).Select(card => card.Operation.RunIndex));
    }

    [Fact]
    public void CardKeysAreStableAcrossRefreshes()
    {
        var running = Operation("backup-worker", 7, OperationStatus.Running);
        var key = Assert.Single(OperationCardStack.Build(new([running]), null, 0)).Key;
        Assert.Equal(key, Assert.Single(OperationCardStack.Build(
            new([running with { Status = OperationStatus.Succeeded, CompletedItems = 9 }]), null, 0)).Key);
    }

    [Fact]
    public void ActionResults_SitWithTheUsersWork_NewestClosestToTheScheduleLine()
    {
        var automatic = Operation("backup-worker", 9, OperationStatus.Running);
        var export = Operation("export", 12, OperationStatus.Running, "archive-worker");
        var local = Operation("restore", 0, OperationStatus.Running, "app") with { OperationId = "mine" };
        var now = DateTimeOffset.UtcNow;
        var older = new OperationNotice("a", "Rename backup", "Could not rename.", OperationStatus.Failed, now.AddSeconds(-2));
        var newer = new OperationNotice("b", "Settings", "Saved.", OperationStatus.Succeeded, now);

        var cards = OperationCardStack.Build(new([automatic, export]), local, 12, limit: 10, notices: [newer, older]);

        Assert.Equal(["backup:9", "Export:export:12", "local", "notice:a", "notice:b"], cards.Select(card => card.Key));
        Assert.All(cards.Skip(1), card => Assert.Equal(OperationCardTier.User, card.Tier));
        var notice = cards[3];
        Assert.Equal((OperationCardGroup.Notice, "Rename backup", "Could not rename.", OperationStatus.Failed),
            (notice.Group, notice.Title, notice.Operation.Message, notice.Operation.Status));
        // Finished notices give way to active work like any finished card.
        Assert.Equal(["backup:9", "Export:export:12", "local"],
            OperationCardStack.Build(new([automatic, export]), local, 12, limit: 3, notices: [older, newer]).Select(card => card.Key));
    }

    [Fact]
    public void WorkShownOnItsPlaceholder_DoesNotReturnAsASecondCard_OnceThePlaceholderHasGone()
    {
        var now = DateTimeOffset.UtcNow;
        var success = TimeSpan.FromSeconds(5);
        var failure = TimeSpan.FromSeconds(10);
        // The projection still lists the finished export the placeholder already showed.
        var sameWork = Operation("export", 21, OperationStatus.Succeeded, "archive-worker") with
            { OperationId = "mine", CompletedUtc = now.AddSeconds(-1) };
        var other = Operation("restore", 22, OperationStatus.Succeeded, "restore-worker") with { CompletedUtc = now.AddSeconds(-1) };
        var view = new OperationsView([sameWork, other]);

        Assert.Equal(2, OperationCardStack.Build(OperationCardStack.Visible(view, [], now, success, failure), null, 0).Count);
        var visible = OperationCardStack.Visible(view, [new RetiredWork("mine", 21, now)], now, success, failure);
        Assert.Same(other, Assert.Single(OperationCardStack.Build(visible, null, 0)).Operation);
        // Matched by run as well, for a projection that names the work differently.
        visible = OperationCardStack.Visible(view, [new RetiredWork("placeholder-id", 21, now)], now, success, failure);
        Assert.Same(other, Assert.Single(visible.Operations));
    }

    [Fact]
    public void AFinishedCardLeavesWhenItsTimeIsUp_EvenFromAnOlderProjection()
    {
        var now = DateTimeOffset.UtcNow;
        var success = TimeSpan.FromSeconds(5);
        var failure = TimeSpan.FromSeconds(10);
        var succeeded = Operation("restore", 1, OperationStatus.Succeeded) with { CompletedUtc = now.AddSeconds(-6) };
        var failed = Operation("export", 2, OperationStatus.Failed) with { CompletedUtc = now.AddSeconds(-6) };
        var postponed = Operation("maintenance-lane-ArtifactCleanup", 3, OperationStatus.Cancelled) with { CompletedUtc = now.AddSeconds(-6) };
        var running = Operation("backup-worker", 4, OperationStatus.Running);

        var visible = OperationCardStack.Visible(new([succeeded, failed, postponed, running]), [], now, success, failure);

        // Success and postponed cleanup use the success lifetime; a failure stays for the longer one.
        Assert.Equal([2L, 4], visible.Operations.Select(operation => operation.RunIndex));
    }

    private static OperationView Operation(string kind, long run, OperationStatus status, string? producer = null) =>
        new(producer ?? kind, $"{kind}:{run}", kind, producer ?? kind, run, status,
            null, 0, null, 0, null, TelemetryHealth.Healthy, null, null);
}
