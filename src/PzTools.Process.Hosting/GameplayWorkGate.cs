using System.ComponentModel;

namespace PzTools.Process.Hosting;

/// <summary>Defer nonessential maintenance while any game process may be alive (including menus).</summary>
public static class GameplayWorkGate
{
    public static bool ShouldDeferMaintenance()
    {
        try
        {
            var processes = PzTools.Process.Contracts.GameProcessFinder.Find();
            try { return processes.Any(process => !process.HasExited); }
            finally { foreach (var process in processes) process.Dispose(); }
        }
        catch (Exception exception) when (exception is Win32Exception or InvalidOperationException or UnauthorizedAccessException)
        {
            // Uncertainty is a reason to defer maintenance, not permission to compete with the game.
            return true;
        }
    }

    public static IDisposable WatchForGameplay(CancellationTokenSource cancellation,
        Func<bool>? shouldDefer = null, TimeSpan? interval = null)
    {
        ArgumentNullException.ThrowIfNull(cancellation);
        var period = interval ?? TimeSpan.FromSeconds(1);
        if (period <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(interval));
        return new Timer(_ =>
        {
            try
            {
                if ((shouldDefer ?? ShouldDeferMaintenance)()) cancellation.Cancel();
            }
            catch (ObjectDisposedException) { }
        }, null, TimeSpan.Zero, period);
    }
}
