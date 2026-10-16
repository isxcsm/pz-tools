using PzTools.App.Core;

namespace PzTools.Backup.Tests;

/// <summary>The startup loader install runs only with no game, and reads what the bridge's install tool says.</summary>
public sealed class StartupLoaderTests
{
    private const string Folder = @"C:\Steam\steamapps\common\ProjectZomboid";

    /// <summary>A stand-in for the install tool: records each call and answers from a script.</summary>
    private sealed class FakeTool(Func<IReadOnlyList<string>, (int, string)> answer)
    {
        public List<string> Calls { get; } = [];
        public Task<(int, string)> Run(IReadOnlyList<string> arguments, CancellationToken token)
        {
            Calls.Add(string.Join(' ', arguments));
            return Task.FromResult(answer(arguments));
        }
    }

    [Theory]
    [InlineData("PZTOOLS-STARTUP\tinstalled\tabc", StartupLoaderStatus.Installed)]
    [InlineData("PZTOOLS-STARTUP\tnot-installed", StartupLoaderStatus.NotInstalled)]
    [InlineData("PZTOOLS-STARTUP\treverted", StartupLoaderStatus.Reverted)]
    [InlineData("PZTOOLS-STARTUP\tforeign", StartupLoaderStatus.Foreign)]
    public async Task Refresh_ReadsTheStateTheToolReports(string line, StartupLoaderStatus expected)
    {
        var tool = new FakeTool(_ => (0, "WARNING: noise\n" + line + "\r\n"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => [], tool.Run);
        int changes = 0;
        loader.Changed += () => changes++;
        await loader.RefreshAsync();
        Assert.Equal(new StartupLoaderState(expected, Folder), loader.State);
        Assert.Equal(["status " + Folder], tool.Calls);
        Assert.Equal(1, changes);
    }

    [Fact]
    public async Task EveryCall_DoesItsWorkOffTheCallersThread()
    {
        // The app calls the loader from its UI thread: the folder lookup, the process scan and the install tool must not
        // run there. Done on the caller's thread, they would see the caller's context.
        var caller = new SynchronizationContext();
        var seen = new System.Collections.Concurrent.ConcurrentBag<SynchronizationContext?>();
        var loader = new StartupLoader(@"C:\App\game-bridge",
            () => { seen.Add(SynchronizationContext.Current); return Folder; },
            () => { seen.Add(SynchronizationContext.Current); return []; },
            (_, _) => { seen.Add(SynchronizationContext.Current); return Task.FromResult((0, "PZTOOLS-STARTUP\tnot-installed")); });
        var previous = SynchronizationContext.Current;
        Task[] calls;
        SynchronizationContext.SetSynchronizationContext(caller);
        try
        {
            calls = [loader.RefreshAsync(), loader.RefreshBridgeAsync(), loader.InstallAsync(), loader.UninstallAsync(),
                loader.UpdateResidentExtensionsAsync(@"C:\App\data")];
        }
        finally { SynchronizationContext.SetSynchronizationContext(previous); }
        await Task.WhenAll(calls);
        Assert.NotEmpty(seen);
        Assert.DoesNotContain(caller, seen);
    }

    [Fact]
    public async Task Refresh_Installed_NamesTheInstallFolder()
    {
        var tool = new FakeTool(_ => (0, "PZTOOLS-STARTUP\tinstalled\tabc\t" + @"C:\ProgramData\PzTools\startup\s-1"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => [], tool.Run);
        await loader.RefreshAsync();
        Assert.Equal(new StartupLoaderState(StartupLoaderStatus.Installed, Folder, @"C:\ProgramData\PzTools\startup\s-1"), loader.State);
    }

    [Theory]
    [InlineData("listed", StartupLauncherEntry.Listed)]
    [InlineData("absent", StartupLauncherEntry.Absent)]
    [InlineData("none", StartupLauncherEntry.None)]
    [InlineData("unreadable", StartupLauncherEntry.Unreadable)]
    [InlineData("something-new", StartupLauncherEntry.Unknown)]
    public void ReadState_Installed_ReadsWhatTheLauncherFileSaysOfTheJarsEntry(string said, StartupLauncherEntry expected)
    {
        var state = StartupLoader.ReadState(@"installed" + "\tabc\t" + @"C:\ProgramData\PzTools\startup\s-1" + "\tlauncher=" + said, Folder);
        Assert.Equal(new StartupLoaderState(StartupLoaderStatus.Installed, Folder, @"C:\ProgramData\PzTools\startup\s-1", LauncherEntry: expected), state);
        // An old tool's result has no such field; and no other state reads one.
        Assert.Equal(StartupLauncherEntry.Unknown, StartupLoader.ReadState("installed\tabc\t" + @"C:\ProgramData\PzTools\startup\s-1", Folder).LauncherEntry);
        Assert.Equal(StartupLauncherEntry.Unknown, StartupLoader.ReadState("reverted\tabc\t" + @"C:\x" + "\tlauncher=" + said, Folder).LauncherEntry);
    }

    [Fact]
    public async Task RefreshBridge_ForAnEntryTheLauncherFileLost_RunsTheToolsRefresh()
    {
        // A reset of the game's files (Steam's file check) put the plain launcher file back: the refresh adds the entry again.
        var tool = new FakeTool(arguments => (0, arguments[0] == "refresh" ? "PZTOOLS-STARTUP\trefreshed\tbridge-1"
            : "PZTOOLS-STARTUP\tinstalled\tabc\t" + @"C:\ProgramData\PzTools\startup\s-1" + "\tlauncher=absent"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => [], tool.Run);
        await loader.RefreshAsync();
        Assert.Equal(StartupLauncherEntry.Absent, loader.State.LauncherEntry);
        Assert.True(await loader.RefreshBridgeAsync());
        Assert.Equal(["status " + Folder, @"refresh C:\App\game-bridge"], tool.Calls);
    }

    [Fact]
    public async Task RefreshBridge_WhileAGameRuns_WaitsForTheGameToEnd()
    {
        bool running = true;
        var tool = new FakeTool(_ => (0, "PZTOOLS-STARTUP\tunchanged"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => running ? [new(1, DateTime.UtcNow)] : [], tool.Run);
        // The game runs its extensions from the install's bridge; a refresh would remove that copy.
        Assert.False(await loader.RefreshBridgeAsync());
        Assert.Empty(tool.Calls);
        running = false;
        Assert.True(await loader.RefreshBridgeAsync());
        Assert.Equal([@"refresh C:\App\game-bridge"], tool.Calls);
    }

    [Fact]
    public async Task Refresh_WithoutAGameFolder_IsNotFound_AndRunsNothing()
    {
        var tool = new FakeTool(_ => throw new InvalidOperationException("not called"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => null, () => [], tool.Run);
        await loader.RefreshAsync();
        Assert.Equal(StartupLoaderStatus.NotFound, loader.State.Status);
        Assert.Empty(tool.Calls);
    }

    [Fact]
    public async Task Refresh_ThatFails_KeepsWhatWasKnown()
    {
        bool fail = false;
        var tool = new FakeTool(_ => fail ? (1, "PZTOOLS-STARTUP-FAILED\tio\tlocked") : (0, "PZTOOLS-STARTUP\tinstalled\tabc"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => [], tool.Run);
        await loader.RefreshAsync();
        fail = true;
        await loader.RefreshAsync();
        Assert.Equal(StartupLoaderStatus.Installed, loader.State.Status);
    }

    [Fact]
    public async Task Install_WhileAGameRuns_IsRefused_BeforeTheJarIsTouched()
    {
        var tool = new FakeTool(_ => (0, "PZTOOLS-STARTUP\tinstalled\tabc"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => [new(1, DateTime.UtcNow)], tool.Run);
        var error = await Assert.ThrowsAsync<StartupLoaderException>(() => loader.InstallAsync());
        Assert.Equal("game-running", error.Code);
        await Assert.ThrowsAsync<StartupLoaderException>(() => loader.UninstallAsync());
        Assert.Empty(tool.Calls);
    }

    [Fact]
    public async Task Install_PassesTheGameAndBridgeFolders_ThenReadsTheJarAgain()
    {
        var tool = new FakeTool(arguments => (0, arguments[0] == "install" ? "PZTOOLS-STARTUP\tinstalled\tabc\tbridge-1"
            : "PZTOOLS-STARTUP\tinstalled\tabc"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => [], tool.Run);
        await loader.InstallAsync();
        Assert.Equal([$@"install {Folder} C:\App\game-bridge", "status " + Folder], tool.Calls);
        Assert.Equal(StartupLoaderStatus.Installed, loader.State.Status);
    }

    [Fact]
    public async Task Install_TheToolRefuses_ThrowsItsCode_AndStillReadsTheJar()
    {
        var tool = new FakeTool(arguments => arguments[0] == "install"
            ? (1, "PZTOOLS-STARTUP-FAILED\tunsupported-game\tThis game version has no single MainScreenState class")
            : (0, "PZTOOLS-STARTUP\tnot-installed"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => [], tool.Run);
        var error = await Assert.ThrowsAsync<StartupLoaderException>(() => loader.InstallAsync());
        Assert.Equal("unsupported-game", error.Code);
        Assert.Equal(StartupLoaderStatus.NotInstalled, loader.State.Status);
    }

    [Theory]
    // A result line counts only from a tool that ended well; output without one is a failure, never a state.
    [InlineData(1, "PZTOOLS-STARTUP\tinstalled")]
    [InlineData(0, "")]
    [InlineData(0, "Exception in thread main")]
    public void Result_WithoutAResultLine_IsAnIoFailure(int exitCode, string output) =>
        Assert.Equal("io", Assert.Throws<StartupLoaderException>(() => StartupLoader.Result(exitCode, output)).Code);

    [Fact]
    public void Parse_AnUnknownState_IsAnIoFailure() =>
        Assert.Equal("io", Assert.Throws<StartupLoaderException>(() => StartupLoader.Parse("half-installed")).Code);

    /// <summary>An install folder with the loader's line as a game would leave it.</summary>
    private sealed class InstallFolder : IDisposable
    {
        public string Path { get; } = Directory.CreateTempSubdirectory("pztools-startup-game").FullName;
        public void Log(string line, DateTime written)
        {
            var file = System.IO.Path.Combine(Path, "startup.log");
            File.WriteAllText(file, line + "\r\n");
            File.SetLastWriteTimeUtc(file, written);
        }
        public void Dispose() => Directory.Delete(Path, recursive: true);
    }

    private static readonly DateTime Started = new(2026, 10, 8, 12, 0, 0, DateTimeKind.Utc);

    [Fact]
    public void ReadGame_WithoutThisRunsLine_StartedWithoutTheLoader()
    {
        using var folder = new InstallFolder();
        var game = new RunningGame(42, Started);
        Assert.Equal(StartupGameStatus.StartedWithout, StartupLoader.ReadGame(folder.Path, game)?.Status);
        // An earlier game's line: this game started before the loader's files were in its folder.
        folder.Log("2026-10-08T11:00:00Z loaded bridge-0123456789abcdef", Started.AddHours(-1));
        Assert.Equal(StartupGameStatus.StartedWithout, StartupLoader.ReadGame(folder.Path, game)?.Status);
    }

    [Fact]
    public void ReadGame_TheLoadersFailure_IsReportedWithItsLine()
    {
        using var folder = new InstallFolder();
        folder.Log("2026-10-08T12:00:00Z missing pztools-game-bridge.jar", Started.AddSeconds(0.5));
        var report = StartupLoader.ReadGame(folder.Path, new RunningGame(42, Started));
        Assert.Equal(new StartupGameReport(StartupGameStatus.LoadFailed, 42, "2026-10-08T12:00:00Z missing pztools-game-bridge.jar"), report);
        Assert.True(report!.HasProblem);
    }

    [Fact]
    public void ReadGame_Loaded_IsWellWithItsLine()
    {
        using var folder = new InstallFolder();
        folder.Log("2026-10-08T12:00:00Z loaded bridge-0123456789abcdef", Started.AddSeconds(0.5));
        var report = StartupLoader.ReadGame(folder.Path, new RunningGame(42, Started));
        Assert.Equal(new StartupGameReport(StartupGameStatus.Loaded, 42, "2026-10-08T12:00:00Z loaded bridge-0123456789abcdef"), report);
        Assert.False(report!.HasProblem);
    }

    [Fact]
    public async Task Refresh_Installed_WithOneGame_ReadsHowTheLoaderWentInIt()
    {
        using var folder = new InstallFolder();
        folder.Log("2026-10-08T12:00:00Z loaded bridge-0123456789abcdef", Started.AddSeconds(0.5));
        IReadOnlyList<RunningGame> running = [new(42, Started)];
        var tool = new FakeTool(_ => (0, "PZTOOLS-STARTUP\tinstalled\tabc\t" + folder.Path));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => running, tool.Run);
        await loader.RefreshAsync();
        Assert.Equal(StartupGameStatus.Loaded, loader.State.Game?.Status);
        // Two games: which one the files speak of is not known.
        running = [new(42, Started), new(43, Started)];
        await loader.RefreshAsync();
        Assert.Null(loader.State.Game);
    }
}
