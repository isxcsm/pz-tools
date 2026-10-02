using System.IO.Compression;
using PzTools.Process.Contracts.GameRuntime;
using PzTools.GameBridge;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests
{
    [BridgeFact]
    public async Task CompatibleModuleReload_PreservesWatchAndOwnedSave_ThenReplacesPayloadWithoutRestart()
    {
        using var temp = new TempDirectory();
        string bridge = temp.GetPath("bridge");
        CopyReloadTree(RuntimeBridgeDirectory(), bridge);
        InstallTestSaveProvider(bridge);
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var watch = new RuntimeWatchCapture(game.Pid, bridge);
        bool stoppedForDiagnostic = false;
        try
        {
            var ready = await watch.WaitAsync(s => s.CharacterLife == RuntimeCharacterLife.Alive);
            var client = new GameSaveClient(bridge);
            var first = client.RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
            await AwaitExtensionFileAsync(temp.GetPath("extension-started"));
            ChangeReloadArchive(Path.Combine(bridge, "extensions", "pztools-test-save.jar"), "module-two");
            // File replacement alone must not complete/dispose the accepted write.
            await watch.WaitAsync(s => s.Sequence > ready.Sequence + 1);
            Assert.False(first.IsCompleted);
            Assert.False(File.Exists(temp.GetPath("extension-closed")));
            await File.WriteAllTextAsync(temp.GetPath("release-extension"), "release");
            var one = await first;
            var two = await client.RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
            if (two.ProviderId != "pztools.test-save")
            {
                stoppedForDiagnostic = true;
                Assert.Fail($"Unexpected fallback: {two.FallbackReason}; {await game.StopAndReadErrorsAsync()}");
            }
            Assert.Equal(one.ProviderId, two.ProviderId);
            var unchanged = await client.RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
            Assert.Equal(two.ProviderId, unchanged.ProviderId);
            var continuing = await watch.WaitAsync(s => s.Sequence > ready.Sequence + 2);
            Assert.Equal(ready.ObserverEpoch, continuing.ObserverEpoch); // Module reload did not disconnect WATCH.
            Assert.False(File.Exists(temp.GetPath("calls.txt")));

            await File.WriteAllTextAsync(temp.GetPath("die-player"), "die");
            var dead = await watch.WaitAsync(s => s.CharacterLife == RuntimeCharacterLife.Dead && s.DeathId is not null);
            string moved = temp.GetPath("updated-install"); CopyReloadTree(bridge, moved);
            var updated = new GameSaveClient(moved);
            var relocated = await updated.RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
            Assert.Equal(two.ProviderId, relocated.ProviderId); // Same bytes, new folder.
            ChangeReloadArchive(Path.Combine(moved, "pztools-game-bridge.jar"), "bridge-two");
            // A no-save probe drives a compatible payload update. Nothing replays as a save.
            await updated.RequestAsync(game.Pid, temp.Path, false);
            Assert.False(File.Exists(temp.GetPath("calls.txt")));
            await using var resumed = new RuntimeWatchCapture(game.Pid, moved);
            var after = await resumed.WaitAsync(s => s.CharacterLife == RuntimeCharacterLife.Dead);
            Assert.NotEqual(dead.ObserverEpoch, after.ObserverEpoch);
            Assert.Equal(dead.ProcessSession, after.ProcessSession);
            Assert.Equal(dead.WorldSession, after.WorldSession);
            Assert.Equal(dead.CharacterSession, after.CharacterSession);
            Assert.Equal(dead.DeathId, after.DeathId); // Reload is not another death event.
            var stale = await Assert.ThrowsAsync<GameSaveException>(() =>
                new GameSaveClient(moved, runtimeTicket: Ticket(dead, 200)).RequestAsync(game.Pid, temp.Path, true));
            Assert.Equal("runtime-deferred", stale.Code);
            Assert.False(File.Exists(temp.GetPath("calls.txt")));
            var beforeHost = await resumed.WaitAsync(s => s.Sequence > after.Sequence + 1);
            ChangeReloadArchive(Path.Combine(moved, "extensions", "pztools-extension-runtime.jar"), "host-two");
            var runtimeReloaded = await updated.RequestProviderAsync(game.Pid, temp.Path, "pztools.test-save");
            Assert.Equal(two.ProviderId, runtimeReloaded.ProviderId);
            var last = await resumed.WaitAsync(s => s.Sequence > beforeHost.Sequence + 1);
            Assert.Equal(after.ObserverEpoch, last.ObserverEpoch); // Extension-host update also preserves WATCH.
            var hooks = await ReadHookAsync(temp);
            Assert.Contains("hookInstalls=1", hooks);
            Assert.Contains("payloadLoads=2", hooks);
        }
        finally
        {
            await File.WriteAllTextAsync(temp.GetPath("release-extension"), "release");
            try { await watch.DisposeAsync(); }
            catch (IOException) when (stoppedForDiagnostic) { }
            catch (EndOfStreamException) { } // The explicit payload update intentionally retired this subscription.
        }
    }
    private static void ChangeReloadArchive(string path, string value)
    {
        // Publish a new CLOSED archive, as deployment does. Updating a JDK archive in-place with
        // ZipArchive.Update can retain incompatible old data descriptors; that is corrupt input, not hot reload.
        string replacement = path + ".next";
        using (var source = ZipFile.OpenRead(path))
        using (var output = ZipFile.Open(replacement, ZipArchiveMode.Create))
        {
            foreach (var entry in source.Entries)
            {
                if (entry.FullName == "META-INF/reload-test.txt") continue;
                var next = output.CreateEntry(entry.FullName, CompressionLevel.Fastest);
                using var input = entry.Open(); using var target = next.Open(); input.CopyTo(target);
            }
            using var writer = new StreamWriter(output.CreateEntry("META-INF/reload-test.txt").Open());
            writer.Write(value);
        }
        File.Move(replacement, path, true);
    }
    private static void CopyReloadTree(string source, string target)
    {
        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var next = Path.Combine(target, Path.GetRelativePath(source, file));
            Directory.CreateDirectory(Path.GetDirectoryName(next)!); File.Copy(file, next);
        }
    }
}
