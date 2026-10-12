using PzTools.App.Core;

namespace PzTools.Backup.Tests;

/// <summary>
/// PZ Tools helps install PZ Extension API, a program of its own: it runs the release's installer only with no game and
/// reads what the installer and the API's install folder say.
/// </summary>
public sealed class ExtensionApiInstallTests : IDisposable
{
    private const string Folder = @"C:\Steam\steamapps\common\ProjectZomboid";
    private readonly string release = Directory.CreateTempSubdirectory("pztools-extension-api").FullName;

    public ExtensionApiInstallTests() => File.WriteAllText(Path.Combine(release, ExtensionApiInstall.Installer), "");

    public void Dispose() => Directory.Delete(release, recursive: true);

    /// <summary>A stand-in for the installer: records each call and answers from a script.</summary>
    private sealed class FakeTool(Func<IReadOnlyList<string>, (int, string)> answer)
    {
        public List<string> Calls { get; } = [];
        public Task<(int, string)> Run(IReadOnlyList<string> arguments, CancellationToken token)
        {
            Calls.Add(string.Join(' ', arguments));
            return Task.FromResult(answer(arguments));
        }
    }

    private ExtensionApiInstall Api(FakeTool tool, Func<IReadOnlyList<RunningGame>>? games = null, Func<string?>? folder = null) =>
        new(release, @"C:\App\java.exe", folder ?? (() => Folder), games ?? (() => []), tool.Run);

    [Theory]
    [InlineData("PZEXT-INSTALL\tinstalled\tapi-0123456789abcdef\tC:\\ProgramData\\PZExtAPI\\s-1", ExtensionApiStatus.Installed)]
    [InlineData("PZEXT-INSTALL\tnot-installed", ExtensionApiStatus.NotInstalled)]
    [InlineData("PZEXT-INSTALL\treverted", ExtensionApiStatus.Reverted)]
    public async Task Refresh_ReadsTheStateTheInstallerReports(string line, ExtensionApiStatus expected)
    {
        var tool = new FakeTool(_ => (0, "WARNING: noise\n" + line + "\r\n"));
        var api = Api(tool);
        int changes = 0;
        api.Changed += () => changes++;
        await api.RefreshAsync();
        Assert.Equal(expected, api.State.Status);
        Assert.Equal(Folder, api.State.GameFolder);
        Assert.Equal(["status " + Folder], tool.Calls);
        Assert.Equal(1, changes);
    }

    [Fact]
    public async Task Refresh_Installed_NamesTheInstallFolder()
    {
        var tool = new FakeTool(_ => (0, "PZEXT-INSTALL\tinstalled\tapi-1\t" + @"C:\ProgramData\PZExtAPI\s-1"));
        var api = Api(tool);
        await api.RefreshAsync();
        Assert.Equal(new ExtensionApiState(ExtensionApiStatus.Installed, Folder, @"C:\ProgramData\PZExtAPI\s-1"), api.State);
    }

    [Fact]
    public async Task WithoutARelease_IsNotBundled_AndRunsNothing()
    {
        File.Delete(Path.Combine(release, ExtensionApiInstall.Installer));
        var tool = new FakeTool(_ => throw new InvalidOperationException("not called"));
        var api = Api(tool);
        await api.RefreshAsync();
        Assert.Equal(ExtensionApiStatus.NotBundled, api.State.Status);
        Assert.Equal("not-bundled", (await Assert.ThrowsAsync<ExtensionApiException>(() => api.InstallAsync())).Code);
        Assert.Empty(tool.Calls);
    }

    [Fact]
    public async Task Refresh_WithoutAGameFolder_IsNotFound_AndRunsNothing()
    {
        var tool = new FakeTool(_ => throw new InvalidOperationException("not called"));
        var api = Api(tool, folder: () => null);
        await api.RefreshAsync();
        Assert.Equal(ExtensionApiStatus.NotFound, api.State.Status);
        Assert.Empty(tool.Calls);
    }

    [Fact]
    public async Task Refresh_ThatFails_KeepsWhatWasKnown()
    {
        bool fail = false;
        var tool = new FakeTool(_ => fail ? (1, "PZEXT-INSTALL-FAILED\tio\tlocked") : (0, "PZEXT-INSTALL\tnot-installed"));
        var api = Api(tool);
        await api.RefreshAsync();
        fail = true;
        await api.RefreshAsync();
        Assert.Equal(ExtensionApiStatus.NotInstalled, api.State.Status);
    }

    [Fact]
    public async Task Install_WhileAGameRuns_IsRefused_BeforeTheInstallerRuns()
    {
        var tool = new FakeTool(_ => (0, "PZEXT-INSTALL\tnot-installed"));
        var api = Api(tool, () => [new(1, DateTime.UtcNow)]);
        Assert.Equal("game-running", (await Assert.ThrowsAsync<ExtensionApiException>(() => api.InstallAsync())).Code);
        await Assert.ThrowsAsync<ExtensionApiException>(() => api.UninstallAsync());
        Assert.Empty(tool.Calls);
    }

    [Fact]
    public async Task Install_PassesTheGameFolder_ThenReadsTheStateAgain()
    {
        var tool = new FakeTool(arguments => (0, arguments[0] == "uninstall" ? "PZEXT-INSTALL\tuninstalled"
            : arguments[0] == "install" ? "PZEXT-INSTALL\tinstalled\tapi-1\tC:\\x" : "PZEXT-INSTALL\tnot-installed"));
        var api = Api(tool);
        await api.InstallAsync();
        await api.UninstallAsync();
        Assert.Equal(["install " + Folder, "status " + Folder, "uninstall " + Folder, "status " + Folder], tool.Calls);
        Assert.Equal(ExtensionApiStatus.NotInstalled, api.State.Status);
    }

    [Fact]
    public async Task Install_TheInstallerRefuses_ThrowsItsCode_AndStillReadsTheState()
    {
        var tool = new FakeTool(arguments => arguments[0] == "install"
            ? (1, "PZEXT-INSTALL-FAILED\tunsafe-folder\tThe install folder may be changed by other accounts")
            : (0, "PZEXT-INSTALL\tnot-installed"));
        var api = Api(tool);
        Assert.Equal("unsafe-folder", (await Assert.ThrowsAsync<ExtensionApiException>(() => api.InstallAsync())).Code);
        Assert.Equal(ExtensionApiStatus.NotInstalled, api.State.Status);
    }

    [Theory]
    // A result line counts only from an installer that ended well; output without one is a failure, never a state.
    [InlineData(1, "PZEXT-INSTALL\tinstalled")]
    [InlineData(0, "")]
    [InlineData(0, "Exception in thread main")]
    public void Result_WithoutAResultLine_IsAnIoFailure(int exitCode, string output) =>
        Assert.Equal("io", Assert.Throws<ExtensionApiException>(() => ExtensionApiInstall.Result(exitCode, output)).Code);

    [Fact]
    public void ReadState_AnUnknownState_IsAnIoFailure() =>
        Assert.Equal("io", Assert.Throws<ExtensionApiException>(() => ExtensionApiInstall.ReadState("half-installed", Folder)).Code);

    /// <summary>An install folder with the loader's line and the API's status file as a game would leave them.</summary>
    private sealed class InstallFolder : IDisposable
    {
        public string Path { get; } = Directory.CreateTempSubdirectory("pztools-extension-api-game").FullName;
        public void Log(string line, DateTime written) => Write("loader.log", line + "\r\n", written);
        public void Status(int pid, DateTime written, params string[] hooks) =>
            Write("api.tsv", $"PZEXT-API\t1\npid\t{pid}\n" + string.Concat(hooks.Select(hook => "hook\t" + hook + "\n")), written);
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
    public void ReadGame_WithoutThisRunsLine_StartedWithoutIt()
    {
        using var folder = new InstallFolder();
        var game = new RunningGame(42, Started);
        Assert.Equal(StartupGameStatus.StartedWithout, ExtensionApiInstall.ReadGame(folder.Path, game)?.Status);
        folder.Log("2026-10-08T11:00:00Z loaded api-0123456789abcdef", Started.AddHours(-1));
        Assert.Equal(StartupGameStatus.StartedWithout, ExtensionApiInstall.ReadGame(folder.Path, game)?.Status);
    }

    [Fact]
    public void ReadGame_TheLoadersFailure_IsReportedWithItsLine()
    {
        using var folder = new InstallFolder();
        folder.Log("2026-10-08T12:00:00Z missing pzext-boot.jar", Started.AddSeconds(0.5));
        var report = ExtensionApiInstall.ReadGame(folder.Path, new RunningGame(42, Started));
        Assert.Equal(new StartupGameReport(StartupGameStatus.LoadFailed, 42, "2026-10-08T12:00:00Z missing pzext-boot.jar"), report);
        Assert.True(report!.HasProblem);
    }

    [Fact]
    public void ReadGame_Loaded_NamesTheHooksThatDidNotGoIn_OfThisGameOnly()
    {
        using var folder = new InstallFolder();
        folder.Log("2026-10-08T12:00:00Z loaded api-0123456789abcdef", Started.AddSeconds(0.5));
        var game = new RunningGame(42, Started);
        Assert.Equal(new StartupGameReport(StartupGameStatus.Loaded, 42, "2026-10-08T12:00:00Z loaded api-0123456789abcdef"),
            ExtensionApiInstall.ReadGame(folder.Path, game));
        // Another process's file says nothing about this game.
        folder.Status(7, Started.AddSeconds(20), "IsoGenerator.update\twhy");
        Assert.False(ExtensionApiInstall.ReadGame(folder.Path, game)!.HasProblem);
        folder.Status(42, Started.AddSeconds(20), "LuaManager.init\tapplied", "Food.updateAge:hours\tnot-loaded",
            "IsoGenerator.update\texpected one update()V, found 0", "IsoGridSquare.haveElectricity\tits code could not be built: x");
        var report = ExtensionApiInstall.ReadGame(folder.Path, game)!;
        Assert.Equal(StartupGameStatus.Loaded, report.Status);
        Assert.Equal("IsoGenerator.update: expected one update()V, found 0\nIsoGridSquare.haveElectricity: its code could not be built: x",
            report.MissingHooks);
        Assert.Equal(["IsoGenerator.update", "IsoGridSquare.haveElectricity"], report.MissingHookNames);
    }

    [Fact]
    public async Task Refresh_Installed_WithOneGame_ReadsHowItWentInIt()
    {
        using var folder = new InstallFolder();
        folder.Log("2026-10-08T12:00:00Z loaded api-0123456789abcdef", Started.AddSeconds(0.5));
        IReadOnlyList<RunningGame> running = [new(42, Started)];
        var tool = new FakeTool(_ => (0, "PZEXT-INSTALL\tinstalled\tapi-1\t" + folder.Path));
        var api = Api(tool, () => running);
        await api.RefreshAsync();
        Assert.Equal(StartupGameStatus.Loaded, api.State.Game?.Status);
        // Two games: which one the files speak of is not known.
        running = [new(42, Started), new(43, Started)];
        await api.RefreshAsync();
        Assert.Null(api.State.Game);
    }
}
