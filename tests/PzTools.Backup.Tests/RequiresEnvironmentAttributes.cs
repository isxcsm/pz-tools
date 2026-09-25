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
