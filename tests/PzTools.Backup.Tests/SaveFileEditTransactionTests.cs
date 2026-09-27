using System.Security.Cryptography;
using PzTools.Backup.Engine;
using PzTools.Process.Hosting;

namespace PzTools.Backup.Tests;

public sealed class SaveFileEditTransactionTests
{
    [Fact]
    public async Task Commit_ReplacesBothFilesAndLeavesNoInventory()
    {
        using var w = new Workspace();
        await SaveFileEditTransaction.CommitAsync(w.Save, w.Files, CancellationToken.None);
        w.AssertInstalled();
        Assert.False(SaveFileEditTransaction.IsPending(w.Save));
    }

    [Fact]
    public async Task InterruptedPublication_IsCompletedByStartupSweep()
    {
        using var w = new Workspace();
        await w.Interrupt();
        Assert.Equal(new byte[] { 3 }, File.ReadAllBytes(Path.Combine(w.Save, "reanimated.bin")));
        Assert.Equal(new byte[] { 2 }, File.ReadAllBytes(Path.Combine(w.Save, "players.db")));
        var result = await InterruptedOperationRecoveryService.RecoverSavesAsync(w.Root);
        Assert.Empty(result.Problems); Assert.Equal(1, result.Recovered);
        w.AssertInstalled();
        Assert.False(SaveFileEditTransaction.IsPending(w.Save));
    }

    [Fact]
    public async Task GameChangesAfterInterruption_AreNeverOverwritten()
    {
        using var w = new Workspace();
        await w.Interrupt();
        File.WriteAllBytes(Path.Combine(w.Save, "players.db"), [99]);
        await Assert.ThrowsAsync<InvalidDataException>(() => SaveFileEditTransaction.RecoverAsync(w.Save));
        Assert.Equal(new byte[] { 99 }, File.ReadAllBytes(Path.Combine(w.Save, "players.db")));
        Assert.True(SaveFileEditTransaction.IsPending(w.Save));
    }

    [Fact]
    public async Task CorruptPayload_IsRejectedBeforeAnyFurtherPublication()
    {
        using var w = new Workspace();
        await w.Interrupt();
        File.WriteAllBytes(Path.Combine(SaveFileEditTransaction.DirectoryPath(w.Save), "players.db"), [99]);
        await Assert.ThrowsAsync<InvalidDataException>(() => SaveFileEditTransaction.RecoverAsync(w.Save));
        Assert.Equal(new byte[] { 2 }, File.ReadAllBytes(Path.Combine(w.Save, "players.db")));
    }

    [Fact]
    public async Task InterruptedCleanup_DoesNotRequireAlreadyInstalledPayloads()
    {
        using var w = new Workspace();
        await w.Interrupt();
        var inventory = SaveFileEditTransaction.DirectoryPath(w.Save);
        File.Copy(Path.Combine(inventory, "players.db"), Path.Combine(w.Save, "players.db"), true);
        File.Delete(Path.Combine(inventory, "reanimated.bin"));
        Assert.True(await SaveFileEditTransaction.RecoverAsync(w.Save));
        w.AssertInstalled();
        Assert.False(Directory.Exists(inventory));
    }

    [Fact]
    public async Task CancellationBeforeCommit_DoesNotChangeOriginals()
    {
        using var w = new Workspace();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            SaveFileEditTransaction.CommitAsync(w.Save, w.Files, new CancellationToken(true)));
        Assert.Equal(new byte[] { 1 }, File.ReadAllBytes(Path.Combine(w.Save, "reanimated.bin")));
        Assert.Equal(new byte[] { 2 }, File.ReadAllBytes(Path.Combine(w.Save, "players.db")));
        Assert.False(SaveFileEditTransaction.IsPending(w.Save));
    }

    private sealed class Workspace : IDisposable
    {
        private readonly string directory = Path.Combine(Path.GetTempPath(), "pztools-file-edit-test-" + Guid.NewGuid().ToString("N"));
        public string Root => Path.Combine(directory, "Saves");
        public string Save => Path.Combine(Root, "Sandbox", "Test");
        public PreparedSaveFile[] Files { get; }
        public Workspace()
        {
            Directory.CreateDirectory(Save);
            File.WriteAllBytes(Path.Combine(Save, "reanimated.bin"), [1]);
            File.WriteAllBytes(Path.Combine(Save, "players.db"), [2]);
            var z = Path.Combine(directory, "z-new"); var p = Path.Combine(directory, "p-new");
            File.WriteAllBytes(z, [3]); File.WriteAllBytes(p, [4]);
            Files = [new("reanimated.bin", z, Convert.ToHexString(SHA256.HashData(new byte[] { 1 }))),
                new("players.db", p, Convert.ToHexString(SHA256.HashData(new byte[] { 2 })))];
        }
        public async Task Interrupt()
        {
            using var blocked = new FileStream(Path.Combine(Save, "players.db"), FileMode.Open, FileAccess.Read, FileShare.Read);
            var exception = await Assert.ThrowsAsync<IOException>(() => SaveFileEditTransaction.CommitAsync(Save, Files, CancellationToken.None));
            Assert.Equal("save-edit-pending", exception.Message);
        }
        public void AssertInstalled()
        {
            Assert.Equal(new byte[] { 3 }, File.ReadAllBytes(Path.Combine(Save, "reanimated.bin")));
            Assert.Equal(new byte[] { 4 }, File.ReadAllBytes(Path.Combine(Save, "players.db")));
            Assert.Equal(2, Directory.GetFiles(Save).Length);
        }
        public void Dispose() => Directory.Delete(directory, true);
    }
}
