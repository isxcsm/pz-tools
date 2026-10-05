using System.Diagnostics;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Tests;

/// <summary>A game started by its Java runtime directly (the game's own ProjectZomboid64.bat) is the game too.</summary>
public sealed class GameProcessFinderTests
{
    [Theory]
    // The game's own ProjectZomboid64.bat.
    [InlineData("\".\\jre64\\bin\\java.exe\" -Djava.awt.headless=true -XX:+UseZGC -Xmx3072m -Djava.library.path=./win64/;./ -cp ./;projectzomboid.jar zombie.gameStates.MainScreenState", true)]
    // A player's own script, with another runtime and arguments after the class.
    [InlineData("C:\\Java\\bin\\javaw.exe -Xmx8g -cp \"D:\\Games\\ProjectZomboid\\projectzomboid.jar\" zombie.gameStates.MainScreenState -debug", true)]
    // The dedicated server, and Java programs that are not the game.
    [InlineData("\".\\jre64\\bin\\java.exe\" -Xmx8g -cp ./;projectzomboid.jar zombie.network.GameServer -statistic 0", false)]
    [InlineData("java -jar tools.jar", false)]
    [InlineData("java -Dzombie.gameStates.MainScreenState=1 -cp x Main", false)]
    [InlineData("java -cp x my.zombie.gameStates.MainScreenStates", false)]
    [InlineData(null, false)]
    public void ClientCommandLine_IsTheGame(string? commandLine, bool game) =>
        Assert.Equal(game, GameProcessFinder.IsGameCommandLine(commandLine));

    [JavaFact]
    public async Task JavaProcess_IsFoundOnlyWhenItStartsTheGame()
    {
        using var temp = new TempDirectory();
        var source = temp.GetPath("Sleep.java");
        await File.WriteAllTextAsync(source,
            "class Sleep { public static void main(String[] arguments) throws Exception { Thread.sleep(60_000); } }");
        System.Diagnostics.Process Start(string argument)
        {
            var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("PZTOOLS_BRIDGE_TEST_JAVA")!)
                { UseShellExecute = false, CreateNoWindow = true };
            foreach (var value in new[] { source, argument }) start.ArgumentList.Add(value);
            return System.Diagnostics.Process.Start(start)!;
        }
        using var game = Start("zombie.gameStates.MainScreenState");
        using var other = Start("zombie.network.GameServer");
        try
        {
            var found = GameProcessFinder.Find();
            try
            {
                Assert.Contains(found, process => process.Id == game.Id);
                Assert.DoesNotContain(found, process => process.Id == other.Id);
                Assert.True(GameProcessFinder.IsStartedWithoutLauncher(found.Single(process => process.Id == game.Id)));
            }
            finally { foreach (var process in found) process.Dispose(); }
        }
        finally
        {
            foreach (var process in new[] { game, other }) { process.Kill(); await process.WaitForExitAsync(); }
        }
    }

    private sealed class JavaFactAttribute : FactAttribute
    {
        public JavaFactAttribute()
        {
            if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("PZTOOLS_BRIDGE_TEST_JAVA")))
                Skip = "Set PZTOOLS_BRIDGE_TEST_JAVA to a Java runtime.";
        }
    }
}
