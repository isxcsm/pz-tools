using PzTools.GameBridge;
using PzTools.Zomboid.Backup;
using PzTools.Zomboid.State;

namespace PzTools.Backup.Tests;

public sealed class BackupGameSaveTests
{
    [Fact]
    public async Task InactiveSaveDoesNotConnectToTheGameEvenWhenBridgeIsUnavailable()
    {
        using var temp = new TempDirectory();
        await File.WriteAllTextAsync(temp.GetPath("players.db"), "fixture");
        var calls = 0;
        var save = new BackupGameSave((_, _) =>
        {
            calls++;
            throw new GameSaveException("bridge-not-built", "Must not attach to an inactive save");
        });
        Assert.Equal("not-in-world", (await save.PrepareAsync(temp.Path, CancellationToken.None)).Outcome);
        Assert.Equal(0, calls);
        // Exercise the production constructor as well, with no bridge payload.
        Assert.Equal("not-in-world", (await new BackupGameSave(temp.GetPath("missing-bridge"))
            .PrepareAsync(temp.Path, CancellationToken.None)).Outcome);
    }

    [Fact]
    public async Task ActivityIsProbedAgainForEveryBackupAndOnlyForItsSelectedSave()
    {
        using var temp = new TempDirectory();
        var path = temp.GetPath("players.db");
        await File.WriteAllTextAsync(path, "fixture");
        var otherWorld = temp.GetPath("other-world");
        Directory.CreateDirectory(otherWorld);
        await File.WriteAllTextAsync(Path.Combine(otherWorld, "players.db"), "other");
        using var otherGame = new FileStream(Path.Combine(otherWorld, "players.db"),
            FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
        var calls = 0;
        var save = new BackupGameSave((_, _) => { calls++; return Task.FromResult("returned"); });
        Assert.Equal("not-in-world", (await save.PrepareAsync(temp.Path, CancellationToken.None)).Outcome);
        using (var game = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
            Assert.Equal("saved", (await save.PrepareAsync(temp.Path, CancellationToken.None)).Outcome);
        Assert.Equal("not-in-world", (await save.PrepareAsync(temp.Path, CancellationToken.None)).Outcome);
        Assert.Equal(1, calls);
    }

    [Theory]
    [InlineData(ActivityState.Active)]
    [InlineData(ActivityState.Unknown)]
    public async Task UncertainOrActiveWorldStillRequiresGameValidation(ActivityState state)
    {
        var calls = 0;
        var save = new BackupGameSave((_, _) =>
        {
            calls++;
            throw new GameSaveException("completion-unknown", "uncertain");
        }, _ => state);
        var error = await Assert.ThrowsAsync<GameSaveException>(() => save.PrepareAsync("selected", CancellationToken.None));
        Assert.Equal("completion-unknown", error.Code);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task Save_IsAwaitedAndRequestedExactlyOnce()
    {
        var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var save = new BackupGameSave((path, _) =>
        {
            Assert.Equal("selected", path);
            calls++;
            return completion.Task;
        });
        var pending = save.PrepareAsync("selected", CancellationToken.None);
        Assert.False(pending.IsCompleted);
        completion.SetResult("returned");
        Assert.Equal(new GameSaveResult("saved", "returned"), await pending);
        Assert.Equal(1, calls);
    }

    [Theory]
    [InlineData("game-not-running")]
    [InlineData("not-in-world")]
    [InlineData("save-mismatch")]
    public async Task OnlyExplicitInactiveWorldResponsesAllowOrdinaryFileBackup(string code)
    {
        var save = new BackupGameSave((_, _) => throw new GameSaveException(code, "not this world"));
        Assert.Equal(code, (await save.PrepareAsync("selected", CancellationToken.None)).Outcome);
    }

    [Theory]
    [InlineData("save-failed")]
    [InlineData("completion-unknown")]
    [InlineData("queue-timeout")]
    // A game that could not be reached at all, or that the bridge does not fit, is the one exception;
    // see GameLinkFallbackTests.
    [InlineData("bridge-failed")]
    [InlineData("saving-disabled")]
    [InlineData("multiplayer")]
    [InlineData("busy")]
    public async Task FailureIsNeverSilentlyDowngradedToFileBackup(string code)
    {
        var calls = 0;
        var save = new BackupGameSave((_, _) => { calls++; throw new GameSaveException(code, "failed"); });
        var error = await Assert.ThrowsAsync<GameSaveException>(() => save.PrepareAsync("selected", CancellationToken.None));
        Assert.Equal(code, error.Code);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task CancellationIsPropagated()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var save = new BackupGameSave((_, token) => Task.FromCanceled<string>(token));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => save.PrepareAsync("selected", cancellation.Token));
    }
}
