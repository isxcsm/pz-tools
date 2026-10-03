using System.Security.Cryptography;

namespace PzTools.App.Core;

/// <summary>
/// This run of the app, by the name the game knows it by: 32 hex digits made at start, so a later run is told from this
/// one. The state scheduler renews this run's lease in the game for as long as its state stream is open, and what the
/// run asks of the game (the last minutes' recording) lasts while the lease does: the game ends it a while after the
/// app has gone, however it went. See the game bridge's Leases.
/// </summary>
public static class AppRun
{
    public static string Id { get; } = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
}
