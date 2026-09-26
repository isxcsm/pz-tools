using System.Diagnostics;
using System.Text;
using PzTools.Process.Contracts;
using PzTools.SaveBridge;
using PzTools.Zomboid.Backup;
using PzTools.Backup.Core.Configuration;
using PzTools.Backup.ChangeTracking.Windows;
using PzTools.Backup.Engine;
using PzTools.Backup.Storage.Repository;

namespace PzTools.Backup.Tests;

public sealed partial class GameSaveClientTests(Xunit.Abstractions.ITestOutputHelper output)
{
    [BridgeFact]
    public async Task Bridge_StoresStableCharacterAndHandIdsBeforeRequiredSave()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = Client();
        await client.RequestAsync(game.Pid, temp.Path, true);
        var first = await File.ReadAllLinesAsync(temp.GetPath("recovery-stamp.txt"));
        Assert.True(Guid.TryParse(first[0], out _));
        Assert.Equal("777.0", first[1]); Assert.Equal("888.0", first[2]);
        await client.RequestAsync(game.Pid, temp.Path, true);
        Assert.Equal(first, await File.ReadAllLinesAsync(temp.GetPath("recovery-stamp.txt")));
        Assert.Equal(2, File.ReadAllLines(temp.GetPath("calls.txt")).Length);
    }
    [BridgeFact]
    public async Task Bridge_AllCatalogLanguagesUsePackagedUtf8Messages()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        foreach (var language in LanguageCatalog.All)
        {
            await new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
                notificationLanguage: language.Tag, scheduledSaveUtc: DateTimeOffset.UtcNow.AddSeconds(-1))
                .RequestAsync(game.Pid, temp.Path, true);
            var latest = File.ReadAllLines(temp.GetPath("notices.txt")).Last().Split('\t');
            Assert.Equal(language.SaveCompleted, latest[1]);
        }
        await AssertIdleAsync(temp);
    }

    [BridgeFact]
    public async Task Bridge_ScheduledCountdownUsesTheDueTime_NotFiveSecondsAfterAdmission()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var due = DateTimeOffset.UtcNow.AddSeconds(8);
        var client = new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
            completionTimeoutSeconds: 30, queueTimeoutSeconds: 10,
            notificationLanguage: "en", scheduledSaveUtc: due);
        await client.RequestAsync(game.Pid, temp.Path, true);
        var notices = (await File.ReadAllLinesAsync(temp.GetPath("notices.txt")))
            .Select(line => line.Split('\t')).ToArray();
        Assert.Equal(new[] { "Game saving in 5 s", "Game saving in 4 s", "Game saving in 3 s", "Game saving in 2 s", "Game saving in 1 s", "Game save complete" },
            notices.Select(line => line[1]));
        Assert.InRange(long.Parse(notices[0][0]) - due.ToUnixTimeMilliseconds(), -5000, -4000);
        Assert.InRange(long.Parse(await File.ReadAllTextAsync(temp.GetPath("save-time.txt")))
            - due.ToUnixTimeMilliseconds(), 0, 1500);
        await AssertIdleAsync(temp);
    }

    [BridgeFact]
    public async Task Bridge_ScheduledSaveWithNoticesOffWaits_AndLateAdmissionDoesNotAddFiveSeconds()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var due = DateTimeOffset.UtcNow.AddSeconds(4);
        await new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
            scheduledSaveUtc: due).RequestAsync(game.Pid, temp.Path, true);
        Assert.False(File.Exists(temp.GetPath("notices.txt")));
        Assert.InRange(long.Parse(await File.ReadAllTextAsync(temp.GetPath("save-time.txt")))
            - due.ToUnixTimeMilliseconds(), 0, 1500);
        var clock = Stopwatch.StartNew();
        await new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
            notificationLanguage: "en", scheduledSaveUtc: due.AddSeconds(-10))
            .RequestAsync(game.Pid, temp.Path, true);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(4));
        Assert.Contains("\tGame save complete\t", Assert.Single(File.ReadAllLines(temp.GetPath("notices.txt"))));
    }

    [BridgeFact]
    public async Task Bridge_RetiresLegacyHook_AndLoadsChangedPayloadWithoutRestartingTheGame()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal", legacy: true);
        var bridge = temp.GetPath("bridge");
        Directory.CreateDirectory(bridge);
        var original = Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!;
        // Only the payload changes; retain the same private runtime/native bootstrap.
        foreach (var source in Directory.EnumerateFiles(original, "*", SearchOption.AllDirectories))
        {
            var destination = Path.Combine(bridge, Path.GetRelativePath(original, source));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(source, destination);
        }
        var client = new GameSaveClient(bridge, notificationLanguage: "en",
            scheduledSaveUtc: DateTimeOffset.UtcNow.AddSeconds(-1));
        try
        {
            await client.RequestAsync(game.Pid, temp.Path, true);
            await AssertIdleAsync(temp);
            var payload = Path.Combine(bridge, "pztools-save-bridge.jar");
            var replacement = payload + ".new";
            using (var archive = System.IO.Compression.ZipFile.OpenRead(payload))
            using (var rebuilt = System.IO.Compression.ZipFile.Open(replacement, System.IO.Compression.ZipArchiveMode.Create))
            {
                foreach (var entry in archive.Entries)
                {
                    byte[] bytes;
                    using (var stream = entry.Open())
                    using (var memory = new MemoryStream()) { stream.CopyTo(memory); bytes = memory.ToArray(); }
                    if (entry.FullName == "pztools/bridge/runtime/NoticeLanguageData.class")
                    {
                        var index = bytes.AsSpan().IndexOf(Encoding.UTF8.GetBytes("Game save complete"));
                        Assert.True(index >= 0);
                        Encoding.UTF8.GetBytes("Game save finished").CopyTo(bytes, index);
                    }
                    using var updated = rebuilt.CreateEntry(entry.FullName).Open();
                    updated.Write(bytes);
                }
            }
            File.Move(replacement, payload, overwrite: true);
            await client.RequestAsync(game.Pid, temp.Path, true);
            Assert.Contains("Game save finished", await File.ReadAllTextAsync(temp.GetPath("notices.txt")));
            await AssertIdleAsync(temp);
        }
        catch (Exception exception)
        {
            output.WriteLine(exception.ToString());
            output.WriteLine(await game.StopAndReadErrorsAsync());
            throw;
        }
    }

    private static async Task AssertIdleAsync(TempDirectory temp)
    {
        var calls = await ReadHookAsync(temp);
        Assert.Contains("bridgefixture/Inspector.marker", calls);
        Assert.Equal(1, calls.Split('\n').Count(line => line == "pztools/bridge/AgentEntry.poll"));
        Assert.DoesNotContain("pztools/bridge/SaveBridge.poll", calls);
        Assert.Contains("hookInstalls=1", calls);
        Assert.Contains("callbackActive=false", calls);
        Assert.DoesNotContain("bridge-session-active", calls);
    }

    private static async Task<string> ReadHookAsync(TempDirectory temp)
    {
        File.Delete(temp.GetPath("hook-state.txt"));
        await File.WriteAllTextAsync(temp.GetPath("inspect-hook.tmp"), "inspect");
        File.Move(temp.GetPath("inspect-hook.tmp"), temp.GetPath("inspect-hook"));
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (!File.Exists(temp.GetPath("hook-state.txt"))) await Task.Delay(20, timeout.Token);
        return await File.ReadAllTextAsync(temp.GetPath("hook-state.txt"));
    }

    [BridgeFact]
    public async Task Bridge_DisconnectWhileQueuedReleasesSessionBeforeGameResumes()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "stalled");
        using var cancel = new CancellationTokenSource();
        var request = Client().RequestAsync(game.Pid, temp.Path, true, cancel.Token);
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            while (!(await ReadHookAsync(temp)).Contains("bridge-session-active"))
            {
                if (request.IsCompleted) await request;
                await Task.Delay(20, timeout.Token);
            }
            cancel.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => request);
            // Disconnect detection is independent of game-loop ticks and queue expiry.
            while ((await ReadHookAsync(temp)).Contains("bridge-session-active"))
                await Task.Delay(20, timeout.Token);
            await File.WriteAllTextAsync(temp.GetPath("resume"), "resume");
            await Client().RequestAsync(game.Pid, temp.Path, false);
            Assert.False(File.Exists(temp.GetPath("calls.txt")));
        }
        catch (Exception exception)
        {
            output.WriteLine(exception.ToString());
            output.WriteLine(await game.StopAndReadErrorsAsync());
            throw;
        }
    }

    [Fact]
    public void ParseResult_PreservesUnicodeDetails()
    {
        const string detail = "save(true) returned: 한글 세이브";
        Assert.Equal(detail, GameSaveClient.ParseResult("OK\t" + Encode(detail)));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("OK")]
    [InlineData("OK\t!")]
    [InlineData("RUNNING")]
    public void ParseResult_NeverTreatsMissingOrMalformedResponseAsSuccess(string? value) =>
        Assert.Equal("invalid-response", Assert.Throws<GameSaveException>(() =>
            GameSaveClient.ParseResult(value)).Code);

    [Fact]
    public void ParseResult_PreservesFailureCode() =>
        Assert.Equal("queue-timeout", Assert.Throws<GameSaveException>(() =>
            GameSaveClient.ParseResult("ERROR\tqueue-timeout\t" + Encode("cancelled"))).Code);

    [Fact]
    public async Task Request_RejectsMissingBridgeBeforeAttaching()
    {
        using var temp = new TempDirectory();
        var client = new GameSaveClient(temp.Path);
        var error = await Assert.ThrowsAsync<GameSaveException>(() =>
            client.RequestAsync(Environment.ProcessId, temp.Path, save: false));
        Assert.Equal("bridge-not-built", error.Code);
    }

    [BridgeFact]
    public async Task Bridge_BackupWaitsForSaveAndRestoresTheNewDataOnInitialAndIncrementalRuns()
    {
        using var temp = new TempDirectory();
        var sourcePath = temp.GetPath("world");
        Directory.CreateDirectory(sourcePath);
        await using var game = await FakeGame.StartAsync(sourcePath, "normal");
        var client = Client();
        var preparation = new BackupGameSave((path, token) => client.RequestAsync(game.Pid, path, true, token));
        var options = new BackupOptions(BackupConfiguration.CurrentFormatVersion,
            temp.GetPath("repository"), [new BackupSourceOptions("world", sourcePath)],
            new StorageOptions(ChecksumAlgorithm.Sha256, CompressionAlgorithm.None, false),
            new TelemetryOptions(TelemetryMode.Off, 16, 10, 10, 32))
        { AlwaysIncludePaths = ["calls.txt", "memory-only-state.txt"] };
        var service = new OneShotBackupService(new UsnJournalReader(), async (path, token) =>
        {
            var result = await preparation.PrepareAsync(path, token);
            return new(result.Outcome, result.Detail);
        });
        for (var revision = 1; revision <= 2; revision++)
        {
            Assert.Equal(revision, (await service.RunAsync(options, "world")).Revision);
            var repository = await RepositoryDatabase.OpenExistingAsync(options.RepositoryPath);
            var source = await repository.GetSourceAsync("world");
            var restored = temp.GetPath($"restored-{revision}");
            await new RevisionRestorer().RestoreAsync(repository, source.SourceId, revision, restored);
            var lines = await File.ReadAllLinesAsync(Path.Combine(restored, "calls.txt"));
            Assert.Equal(revision, lines.Length);
            Assert.All(lines, line => Assert.Contains("Synthetic-game-thread", line));
            // This state exists only in synthetic game memory until save(true) flushes it.
            Assert.Equal(revision.ToString(System.Globalization.CultureInfo.InvariantCulture),
                await File.ReadAllTextAsync(Path.Combine(restored, "memory-only-state.txt")));
        }
    }

    [BridgeFact]
    public async Task Bridge_ResidentEndpointRejectsUnauthenticatedRequests_WithoutSaving()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        await Client().RequestAsync(game.Pid, temp.Path, false);
        await File.WriteAllTextAsync(temp.GetPath("inspect-control"), "test-only");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (!File.Exists(temp.GetPath("control-state.txt"))) await Task.Delay(20, deadline.Token);
        var fields = (await File.ReadAllTextAsync(temp.GetPath("control-state.txt"))).Split(':');
        Assert.Equal("2", fields[0]);
        using (var socket = new System.Net.Sockets.TcpClient())
        {
            await socket.ConnectAsync(System.Net.IPAddress.Loopback, int.Parse(fields[2]), deadline.Token);
            using var writer = new StreamWriter(socket.GetStream(), new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(socket.GetStream(), leaveOpen: true);
            await writer.WriteLineAsync("invalid\t1\t" + new string('0', 64) + "\t" + Encode(temp.Path));
            Assert.Equal("REJECTED", await reader.ReadLineAsync(deadline.Token));
        }
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        await Client().RequestAsync(game.Pid, temp.Path, true);
        Assert.Single(File.ReadAllLines(temp.GetPath("calls.txt")));
        await AssertIdleAsync(temp);
    }

    [BridgeFact]
    public async Task Bridge_RepeatedSessionsReuseBootstrapPayloadAndHook_AndSaveEveryTime()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = Client();
        for (var index = 0; index < 50; index++)
        {
            await client.RequestAsync(game.Pid, temp.Path, true);
        }
        Assert.Equal(50, File.ReadAllLines(temp.GetPath("calls.txt")).Length);
        Assert.Equal("50", await File.ReadAllTextAsync(temp.GetPath("memory-only-state.txt")));
        var snapshot = await ReadHookAsync(temp);
        Assert.Contains("hookInstalls=1;payloadLoads=1;sessions=50;callbackActive=false", snapshot);
        await AssertIdleAsync(temp);
        // Inspection itself retransforms the class through another agent. Our next request
        // must still work without reinstalling or inserting a second poll callback.
        await client.RequestAsync(game.Pid, temp.Path, true);
        Assert.Equal(51, File.ReadAllLines(temp.GetPath("calls.txt")).Length);
        await AssertIdleAsync(temp);
    }

    [BridgeFact]
    public async Task Bridge_ProbeDoesNotSave_AndRepeatedSaveRunsExactlyOncePerRequestOnGameThread()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = Client();
        var probe = await client.RequestAsync(game.Pid, temp.Path, save: false);
        Assert.Contains("Probe only", probe);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        for (var i = 0; i < 2; i++)
        {
            var result = await client.RequestAsync(game.Pid, temp.Path, save: true);
            Assert.Contains("GameWindow.save(true) returned", result);
            Assert.Contains("thread=Synthetic-game-thread", result);
        }
        Assert.Equal(2, File.ReadAllLines(temp.GetPath("calls.txt")).Length);
        Assert.False(File.Exists(temp.GetPath("notices.txt")));
    }

    [BridgeFact]
    public async Task Bridge_CountdownReplacesHaloOnGameThreadWithoutBlockingFrames()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
            notificationLanguage: "ko");
        await client.RequestAsync(game.Pid, temp.Path, save: false);
        Assert.False(File.Exists(temp.GetPath("notices.txt")));
        var result = await client.RequestAsync(game.Pid, temp.Path, save: true);
        Assert.Contains("GameWindow.save(true) returned", result);
        var notices = (await File.ReadAllLinesAsync(temp.GetPath("notices.txt")))
            .Select(line => line.Split('\t')).ToArray();
        Assert.Equal(new[] { "게임 저장까지 5초", "게임 저장까지 4초", "게임 저장까지 3초", "게임 저장까지 2초", "게임 저장까지 1초", "게임 저장 완료" },
            notices.Select(line => line[1]));
        Assert.All(notices, line => Assert.Equal("Synthetic-game-thread", line[2]));
        Assert.True(long.Parse(notices[5][0]) - long.Parse(notices[0][0]) >= 4900);
        Assert.True(long.Parse(await File.ReadAllTextAsync(temp.GetPath("save-ticks.txt"))) > 100);
        Assert.Single(await File.ReadAllLinesAsync(temp.GetPath("calls.txt")));
    }

    [BridgeFact]
    public async Task Bridge_CountdownCancelsWhenLeavingTheWorld()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
            notificationLanguage: "en");
        var request = client.RequestAsync(game.Pid, temp.Path, true);
        await WaitForNoticeAsync(temp);
        await File.WriteAllTextAsync(temp.GetPath("leave-world"), "leave");
        Assert.Equal("not-in-world", (await Assert.ThrowsAsync<GameSaveException>(() => request)).Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        Assert.DoesNotContain("Game save complete", await File.ReadAllTextAsync(temp.GetPath("notices.txt")));
    }

    [BridgeFact]
    public async Task Bridge_DisconnectedCountdownDoesNotSaveLater()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var client = new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
            notificationLanguage: "en");
        using var cancel = new CancellationTokenSource();
        var request = client.RequestAsync(game.Pid, temp.Path, true, cancel.Token);
        await WaitForNoticeAsync(temp);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => request);
        await Task.Delay(TimeSpan.FromSeconds(6));
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
        Assert.DoesNotContain("Game save complete", await File.ReadAllTextAsync(temp.GetPath("notices.txt")));
        Assert.Contains("Probe only", await client.RequestAsync(game.Pid, temp.Path, false));
        await AssertIdleAsync(temp);
    }

    [BridgeFact]
    public async Task Bridge_NoticeFailureDoesNotBreakSaving_AndSaveFailureNeverShowsCompletion()
    {
        foreach (var mode in new[] { "notice-error", "throw" })
        {
            using var temp = new TempDirectory();
            await using var game = await FakeGame.StartAsync(temp.Path, mode);
            var client = new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
                notificationLanguage: "en");
            if (mode == "notice-error")
            {
                Assert.Contains("notice-unavailable=", await client.RequestAsync(game.Pid, temp.Path, true));
                Assert.Single(await File.ReadAllLinesAsync(temp.GetPath("calls.txt")));
            }
            else
            {
                Assert.Equal("save-failed", (await Assert.ThrowsAsync<GameSaveException>(() =>
                    client.RequestAsync(game.Pid, temp.Path, true))).Code);
                var notices = await File.ReadAllTextAsync(temp.GetPath("notices.txt"));
                Assert.Contains("Game save failed", notices);
                Assert.DoesNotContain("Game save complete", notices);
            }
        }
    }

    private static async Task WaitForNoticeAsync(TempDirectory temp)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        while (!File.Exists(temp.GetPath("notices.txt"))) await Task.Delay(20, timeout.Token);
    }

    [BridgeFact]
    public async Task Bridge_RejectsWrongSelectedSaveWithoutSaving()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "normal");
        var other = temp.GetPath("other");
        Directory.CreateDirectory(other);
        var error = await Assert.ThrowsAsync<GameSaveException>(() =>
            Client().RequestAsync(game.Pid, other, save: true));
        Assert.Equal("save-mismatch", error.Code);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }

    [BridgeFact]
    public async Task Bridge_RejectsUnsafeStatesAndReportsThrownSaveErrors()
    {
        foreach (var (mode, code) in new[] { ("menu", "not-in-world"), ("multiplayer", "multiplayer"),
            ("no-save", "saving-disabled"), ("throw", "save-failed") })
        {
            using var temp = new TempDirectory();
            await using var game = await FakeGame.StartAsync(temp.Path, mode);
            var error = await Assert.ThrowsAsync<GameSaveException>(() =>
                Client().RequestAsync(game.Pid, temp.Path, save: true));
            Assert.Equal(code, error.Code);
            Assert.False(File.Exists(temp.GetPath("calls.txt")));
        }
    }

    [BridgeFact]
    public async Task Bridge_CustomQueueTimeoutExpiresWithoutLateSave()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "stalled");
        var client = new GameSaveClient(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!,
            connectionTimeoutSeconds: 30, completionTimeoutSeconds: 40, queueTimeoutSeconds: 1);
        var clock = Stopwatch.StartNew();
        var error = await Assert.ThrowsAsync<GameSaveException>(() => client.RequestAsync(game.Pid, temp.Path, true));
        Assert.Equal("queue-timeout", error.Code);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10));
        await File.WriteAllTextAsync(temp.GetPath("resume"), "resume");
        await client.RequestAsync(game.Pid, temp.Path, false);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }

    [BridgeFact]
    public async Task Bridge_ExpiredRequestDoesNotSaveAfterGameResumes()
    {
        using var temp = new TempDirectory();
        await using var game = await FakeGame.StartAsync(temp.Path, "stalled");
        var client = Client();
        var error = await Assert.ThrowsAsync<GameSaveException>(() =>
            client.RequestAsync(game.Pid, temp.Path, save: true));
        Assert.Equal("queue-timeout", error.Code);
        await File.WriteAllTextAsync(temp.GetPath("resume"), "resume");
        await client.RequestAsync(game.Pid, temp.Path, save: false);
        Assert.False(File.Exists(temp.GetPath("calls.txt")));
    }

    [LiveProbeFact]
    public async Task LiveGame_ExplicitProbeNeverSaves()
    {
        var pid = int.Parse(Environment.GetEnvironmentVariable("PZTOOLS_LIVE_PROBE_PID")!);
        var path = Environment.GetEnvironmentVariable("PZTOOLS_LIVE_PROBE_SAVE")!;
        var result = await Client().RequestAsync(pid, path, save: false);
        Assert.Contains("Probe only; no save invoked", result);
    }

    private static string Encode(string value) => Convert.ToBase64String(Encoding.UTF8.GetBytes(value));
    private static GameSaveClient Client() => new(Environment.GetEnvironmentVariable("PZTOOLS_SAVE_BRIDGE_DIR")!);

    private sealed class BridgeFactAttribute : FactAttribute
    {
        public BridgeFactAttribute()
        {
            if (new[] { "PZTOOLS_SAVE_BRIDGE_DIR", "PZTOOLS_BRIDGE_TEST_JAVA", "PZTOOLS_BRIDGE_TEST_CLASSES" }
                .Any(key => string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(key))))
                Skip = "Build the Java fixture and set the bridge integration environment variables.";
        }
    }

    private sealed class LiveProbeFactAttribute : FactAttribute
    {
        public LiveProbeFactAttribute()
        {
            if (new[] { "PZTOOLS_SAVE_BRIDGE_DIR", "PZTOOLS_LIVE_PROBE_PID", "PZTOOLS_LIVE_PROBE_SAVE" }
                .Any(key => string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(key))))
                Skip = "Live game probes require explicit PID and save path. Never calls save.";
        }
    }

    private sealed class FakeGame(System.Diagnostics.Process process) : IAsyncDisposable
    {
        private readonly Task<string> errors = process.StandardError.ReadToEndAsync();
        public int Pid => process.Id;
        public async Task<string> StopAndReadErrorsAsync()
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            return await errors;
        }
        public static async Task<FakeGame> StartAsync(string path, string mode, bool legacy = false)
        {
            var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("PZTOOLS_BRIDGE_TEST_JAVA")!)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            start.ArgumentList.Add("-javaagent:" + Path.Combine(Environment.GetEnvironmentVariable("PZTOOLS_BRIDGE_TEST_CLASSES")!, "inspector.jar")
                + (legacy ? "=legacy" : ""));
            foreach (var arg in new[] { "-XX:+EnableDynamicAgentLoading", "-cp",
                Environment.GetEnvironmentVariable("PZTOOLS_BRIDGE_TEST_CLASSES")!, "zombie.GameWindow", path, mode })
                start.ArgumentList.Add(arg);
            var process = System.Diagnostics.Process.Start(start)!;
            var game = new FakeGame(process);
            try
            {
                Assert.Equal("READY", await process.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(15)));
                return game;
            }
            catch { await game.DisposeAsync(); throw; }
        }
        public async ValueTask DisposeAsync()
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            process.Dispose();
            // Windows can signal process exit just before its native image mappings
            // are released. Allow test-owned DLLs to become deletable by TempDirectory.
            await Task.Delay(100);
        }
    }
}
