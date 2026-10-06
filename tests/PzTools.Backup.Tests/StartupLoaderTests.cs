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
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => false, tool.Run);
        int changes = 0;
        loader.Changed += () => changes++;
        await loader.RefreshAsync();
        Assert.Equal(new StartupLoaderState(expected, Folder), loader.State);
        Assert.Equal(["status " + Folder], tool.Calls);
        Assert.Equal(1, changes);
    }

    [Fact]
    public async Task Refresh_WithoutAGameFolder_IsNotFound_AndRunsNothing()
    {
        var tool = new FakeTool(_ => throw new InvalidOperationException("not called"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => null, () => false, tool.Run);
        await loader.RefreshAsync();
        Assert.Equal(StartupLoaderStatus.NotFound, loader.State.Status);
        Assert.Empty(tool.Calls);
    }

    [Fact]
    public async Task Refresh_ThatFails_KeepsWhatWasKnown()
    {
        bool fail = false;
        var tool = new FakeTool(_ => fail ? (1, "PZTOOLS-STARTUP-FAILED\tio\tlocked") : (0, "PZTOOLS-STARTUP\tinstalled\tabc"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => false, tool.Run);
        await loader.RefreshAsync();
        fail = true;
        await loader.RefreshAsync();
        Assert.Equal(StartupLoaderStatus.Installed, loader.State.Status);
    }

    [Fact]
    public async Task Install_WhileAGameRuns_IsRefused_BeforeTheJarIsTouched()
    {
        var tool = new FakeTool(_ => (0, "PZTOOLS-STARTUP\tinstalled\tabc"));
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => true, tool.Run);
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
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => false, tool.Run);
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
        var loader = new StartupLoader(@"C:\App\game-bridge", () => Folder, () => false, tool.Run);
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
}
