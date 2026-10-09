namespace PzTools.Backup.Tests;

/// <summary>Missing opt-ins are skipped; an explicitly configured but broken fixture still fails.</summary>
public sealed class RequiresEnvironmentFactAttribute : FactAttribute
{
    public RequiresEnvironmentFactAttribute(string variable)
    {
        if (!OperatingSystem.IsWindows()) Skip = "Requires Windows.";
        else if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(variable)))
            Skip = $"Set {variable} to run this integration test.";
    }

    /// <summary>The test needs maintenance work to run, which it never does while a game is open.</summary>
    public bool NoGame
    {
        get => false;
        set { if (value) Skip ??= NoGameRunning.SkipReason(); }
    }
}

/// <summary>
/// Maintenance work (lanes, orphan cleanup) is deferred while any game process runs, by design. A test that needs
/// that work to run skips then, instead of failing on a machine where someone is playing.
/// </summary>
internal static class NoGameRunning
{
    public static string? SkipReason() => PzTools.Process.Hosting.GameplayWorkGate.ShouldDeferMaintenance()
        ? "Close Project Zomboid: maintenance work is deferred while a game runs." : null;

    /// <summary>Names a game that appeared after the test started, so it does not read as a product bug.</summary>
    public static string Explain(string failure) => PzTools.Process.Hosting.GameplayWorkGate.ShouldDeferMaintenance()
        ? failure + " A game process is running now, so maintenance work was deferred." : failure;
}

public sealed class RequiresEnvironmentTheoryAttribute : TheoryAttribute
{
    public RequiresEnvironmentTheoryAttribute(string variable)
    {
        if (!OperatingSystem.IsWindows()) Skip = "Requires Windows.";
        else if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(variable)))
            Skip = $"Set {variable} to run this integration test.";
    }
}
