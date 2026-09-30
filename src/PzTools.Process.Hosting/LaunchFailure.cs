using System.ComponentModel;

namespace PzTools.Process.Hosting;

public static class LaunchFailure
{
    public const string Failed = "launch-failed";

    /// <summary>
    /// Windows refused to run the file by policy (Smart App Control / App Control, software
    /// restriction, or antivirus) rather than the file being missing or broken. Reputation-based
    /// verdicts can change from day to day, so this is reported separately and retried.
    /// </summary>
    public const string Blocked = "launch-blocked";

    // ERROR_VIRUS_INFECTED, ERROR_ACCESS_DISABLED_BY_POLICY, ERROR_SYSTEM_INTEGRITY_POLICY_VIOLATION,
    // ERROR_SYSTEM_INTEGRITY_INVALID_POLICY.
    public static string Classify(Exception exception) =>
        exception is Win32Exception { NativeErrorCode: 225 or 1260 or 4551 or 4552 } ? Blocked : Failed;
}
