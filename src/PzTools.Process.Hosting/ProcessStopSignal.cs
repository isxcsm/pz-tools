namespace PzTools.Process.Hosting;

/// <summary>
/// A polite stop for a child process. Workers run without a window, so asking one to close its main
/// window never reached it, and cancelling a worker killed it outright: no cancelled record, no
/// cleanup. A worker that listens here gets a cancellation instead, as Ctrl+C would give it; the
/// parent waits a moment for it to finish, and only then ends it.
/// </summary>
public static class ProcessStopSignal
{
    private static string Name(int processId) => $@"Local\PzTools-Stop-{processId}";

    /// <summary>Child side: cancels <paramref name="cancellation"/> when the parent asks this process to stop.</summary>
    public static IDisposable Listen(CancellationTokenSource cancellation)
    {
        ArgumentNullException.ThrowIfNull(cancellation);
        var signal = new EventWaitHandle(false, EventResetMode.ManualReset, Name(Environment.ProcessId));
        var registration = ThreadPool.RegisterWaitForSingleObject(signal, (_, _) =>
        {
            try { cancellation.Cancel(); }
            catch (ObjectDisposedException) { }
        }, null, Timeout.Infinite, executeOnlyOnce: true);
        return new Listening(signal, registration);
    }

    /// <summary>Parent side: true when the child listens and has been asked to stop.</summary>
    public static bool TryRequest(int processId)
    {
        // Opening a named event exists only on Windows; elsewhere the parent ends the child as before.
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            if (!EventWaitHandle.TryOpenExisting(Name(processId), out var signal)) return false;
            using (signal) return signal.Set();
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException
            or WaitHandleCannotBeOpenedException)
        {
            return false;
        }
    }

    private sealed class Listening(EventWaitHandle signal, RegisteredWaitHandle registration) : IDisposable
    {
        public void Dispose()
        {
            registration.Unregister(null);
            signal.Dispose();
        }
    }
}
