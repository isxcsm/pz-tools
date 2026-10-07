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
    public async Task Refresh_Installed_NamesTheInstallFolder()
    {
        var tool = new FakeTool(_ => (0, "PZTOOLS-STARTUP\tinstalled\tabc\t" + @"C:\ProgramData\PzTools\startup\s-1"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => [], tool.Run);
        await loader.RefreshAsync();
        Assert.Equal(new StartupLoaderState(StartupLoaderStatus.Installed, Folder, @"C:\ProgramData\PzTools\startup\s-1"), loader.State);
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

    /// <summary>An install folder with the loader's line and the API's status file as a game would leave them.</summary>
    private sealed class InstallFolder : IDisposable
    {
        public string Path { get; } = Directory.CreateTempSubdirectory("pztools-startup-game").FullName;
        public void Log(string line, DateTime written) => Write("startup.log", line + "\r\n", written);
        public void Api(int pid, DateTime written, params string[] hooks) =>
            Write("api.tsv", $"PZTOOLS-API\t1\npid\t{pid}\n" + string.Concat(hooks.Select(hook => "hook\t" + hook + "\n")), written);
        private void Write(string name, string text, DateTime written)
        {
            var file = System.IO.Path.Combine(Path, name);
            File.WriteAllText(file, text);
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
    public void ReadGame_Loaded_NamesTheHooksThatDidNotGoIn_OfThisGameOnly()
    {
        using var folder = new InstallFolder();
        folder.Log("2026-10-08T12:00:00Z loaded bridge-0123456789abcdef", Started.AddSeconds(0.5));
        var game = new RunningGame(42, Started);
        Assert.Equal(new StartupGameReport(StartupGameStatus.Loaded, 42, "2026-10-08T12:00:00Z loaded bridge-0123456789abcdef"),
            StartupLoader.ReadGame(folder.Path, game));
        // Another process's file says nothing about this game.
        folder.Api(7, Started.AddSeconds(20), "IsoGenerator.update\twhy");
        Assert.False(StartupLoader.ReadGame(folder.Path, game)!.HasProblem);
        folder.Api(42, Started.AddSeconds(20), "LuaManager.init\tapplied", "Food.updateAge:hours\tnot-loaded",
            "IsoGenerator.update\texpected one update()V, found 0", "IsoGridSquare.haveElectricity\tits code could not be built: x");
        var report = StartupLoader.ReadGame(folder.Path, game)!;
        Assert.Equal(StartupGameStatus.Loaded, report.Status);
        Assert.Equal("IsoGenerator.update: expected one update()V, found 0\nIsoGridSquare.haveElectricity: its code could not be built: x",
            report.MissingHooks);
        Assert.Equal(["IsoGenerator.update", "IsoGridSquare.haveElectricity"], report.MissingHookNames);
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
