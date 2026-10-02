using System.ComponentModel;
using DiagnosticsProcess = System.Diagnostics.Process;

namespace PzTools.Scheduling;

/// <summary>Wakes state collection as soon as a watched game process exits.</summary>
public sealed class GameProcessExitWatcher : IDisposable
{
    private readonly object gate = new();
    private readonly Dictionary<int, (DiagnosticsProcess Process, EventHandler Handler)> watched = [];
    private readonly SemaphoreSlim exitSignal = new(0, 1);
    private bool pending;
    private bool disposed;

    public void Refresh()
    {
        DiagnosticsProcess[] processes;
        // Called every wake-up; the runtime observer lists processes as often, so share its recent list.
        try { processes = PzTools.Process.Contracts.GameProcessFinder.Find(PzTools.Process.Contracts.GameProcessFinder.WatchSnapshotAge); }
        catch (Exception exception) when (
            exception is InvalidOperationException or Win32Exception)
        { return; }
        foreach (var process in processes) Watch(process);
    }

    // Takes ownership of the Process object, including when it was already watched.
    public void Watch(DiagnosticsProcess process)
    {
        ArgumentNullException.ThrowIfNull(process);
        int id;
        try { id = process.Id; }
        catch (Exception exception) when (
            exception is InvalidOperationException or Win32Exception)
        {
            process.Dispose();
            return;
        }

        lock (gate)
        {
            if (disposed || watched.ContainsKey(id))
            {
                process.Dispose();
                return;
            }
            EventHandler handler = (_, _) => SignalExit(id);
            try
            {
                process.Exited += handler;
                process.EnableRaisingEvents = true;
                watched.Add(id, (process, handler));
            }
            catch (Exception exception) when (
                exception is InvalidOperationException or Win32Exception)
            {
                process.Exited -= handler;
                process.Dispose();
                return;
            }
        }

        // The process may have ended between enumeration and event subscription.
        try { if (process.HasExited) SignalExit(id); }
        catch (Exception exception) when (
            exception is InvalidOperationException or Win32Exception or ObjectDisposedException)
        { SignalExit(id); }
    }

    public async Task<bool> WaitAsync(TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (!await exitSignal.WaitAsync(timeout, cancellationToken)) return false;
        lock (gate) pending = false;
        return true;
    }

    private void SignalExit(int id)
    {
        lock (gate)
        {
            if (!watched.Remove(id, out var entry)) return;
            entry.Process.Exited -= entry.Handler;
            entry.Process.Dispose();
            SignalExitCore();
        }
    }

    private void SignalExitCore()
    {
        if (disposed || pending) return;
        pending = true;
        exitSignal.Release();
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            foreach (var entry in watched.Values)
            {
                entry.Process.Exited -= entry.Handler;
                entry.Process.Dispose();
            }
            watched.Clear();
            exitSignal.Dispose();
        }
    }
}
