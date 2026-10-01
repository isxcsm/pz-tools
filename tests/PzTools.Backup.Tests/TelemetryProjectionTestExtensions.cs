using PzTools.Projections;

namespace PzTools.Backup.Tests;

internal static class TelemetryProjectionTestExtensions
{
    /// <summary>For a host used once: projects, then closes its connections so the test folder can be deleted.</summary>
    public static async Task ProjectOnceThenCloseAsync(this TelemetryProjectionHost host,
        DateTimeOffset? observedUtc = null, CancellationToken cancellationToken = default)
    {
        using (host) await host.ProjectOnceAsync(observedUtc, cancellationToken);
    }
}
