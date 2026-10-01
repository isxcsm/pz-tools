using System.Globalization;
using PzTools.Process.Contracts;

namespace PzTools.Backup.Tests;

public sealed class CommandLineTests
{
    [Fact]
    public void Parse_ReadsValuesAndFlags_AndRejectsUnknownRepeatedOrMissingValues()
    {
        var values = CommandLine.Parse(["run", "--db", "a.db", "--once"], ["--db"], ["--once"], start: 1);
        Assert.Equal("a.db", CommandLine.Required(values, "--db"));
        Assert.True(values.ContainsKey("--once"));
        Assert.Throws<ArgumentException>(() => CommandLine.Parse(["--other", "x"], ["--db"]));
        Assert.Throws<ArgumentException>(() => CommandLine.Parse(["--db", "a", "--db", "b"], ["--db"]));
        Assert.Throws<ArgumentException>(() => CommandLine.Parse(["--db"], ["--db"]));
        Assert.Throws<ArgumentException>(() => CommandLine.Required(values, "--missing"));
    }

    [Fact]
    public void FindByName_LeavesOtherOptionsForTheWorker()
    {
        string[] arguments = ["--repository", "r", "--source-id", "7", "--worker-directory", "w"];
        Assert.Equal("r", CommandLine.Required(arguments, "--repository"));
        Assert.Null(CommandLine.Optional(arguments, "--run-index"));
        Assert.Equal(["--repository", "r", "--source-id", "7"], CommandLine.Without(arguments, "--worker-directory"));
        Assert.Throws<ArgumentException>(() => CommandLine.Optional(["--run-index", "1", "--run-index", "2"], "--run-index"));
        Assert.Throws<ArgumentException>(() => CommandLine.Optional(["--run-index"], "--run-index"));
    }

    [Fact]
    public void Numbers_AreInvariantWholeNumbersWithinTheirRange()
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            // A culture whose minus sign is not the ASCII hyphen must not change how a worker reads its arguments.
            CultureInfo.CurrentCulture = new CultureInfo("sv-SE");
            Assert.Equal(12, CommandLine.Int64("12", "--run-index"));
            Assert.Equal(-3, CommandLine.Int64("-3", "--offset", minimum: -10));
            Assert.Throws<ArgumentException>(() => CommandLine.Int64("1.5", "--run-index"));
            Assert.Throws<ArgumentException>(() => CommandLine.Int64(" 1", "--run-index"));
            Assert.Throws<ArgumentOutOfRangeException>(() => CommandLine.Int64("0", "--run-index"));
            Assert.Throws<ArgumentOutOfRangeException>(() => CommandLine.Int32("61", "--interval-minutes", 0, 60));
            Assert.Null(CommandLine.OptionalInt64(null, "--run-index"));
        }
        finally { CultureInfo.CurrentCulture = previous; }
    }
}
