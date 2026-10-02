namespace PzTools.Process.Hosting;

/// <summary>Keeps one application instance per data root in the Windows session.</summary>
public sealed class ApplicationInstanceLease : IDisposable
{
    private readonly Mutex marker;

    private ApplicationInstanceLease(Mutex marker) => this.marker = marker;

    public static ApplicationInstanceLease? TryAcquire(string dataRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);
        var name = NamedMutexRunner.CreateName("AppInstance", Path.GetFullPath(dataRoot));
        // Object creation is atomic. Hold the handle, not thread-affine mutex ownership:
        // Windows removes this marker when the process exits, including after a crash.
        var marker = new Mutex(false, name, out var created);
        if (created) return new ApplicationInstanceLease(marker);
        marker.Dispose();
        return null;
    }

    public void Dispose() => marker.Dispose();
}

/// <summary>
/// Lets a second launch ask the running instance to show its window instead of exiting silently,
/// which looks like "the app does not start" when the first instance is hidden in the tray.
/// </summary>
public static class ApplicationActivationSignal
{
    private static string Name(string dataRoot) =>
        NamedMutexRunner.CreateName("AppActivate", Path.GetFullPath(dataRoot));

    /// <summary>Runs <paramref name="activate"/> on a pool thread each time another launch signals.</summary>
    public static IDisposable Listen(string dataRoot, Action activate)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);
        ArgumentNullException.ThrowIfNull(activate);
        var signal = new EventWaitHandle(false, EventResetMode.AutoReset, Name(dataRoot));
        var registration = ThreadPool.RegisterWaitForSingleObject(
            signal, (_, timedOut) => { if (!timedOut) activate(); }, null, Timeout.Infinite, executeOnlyOnce: false);
        return new Listener(signal, registration);
    }

    /// <summary>False when no instance is listening (for example it is still starting or shutting down).</summary>
    public static bool TrySignal(string dataRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);
        // Opening a named event exists only on Windows; elsewhere the second launch simply finds no listener.
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            if (!EventWaitHandle.TryOpenExisting(Name(dataRoot), out var signal)) return false;
            using (signal) return signal.Set();
        }
        catch (Exception exception) when (exception is UnauthorizedAccessException or IOException) { return false; }
    }

    private sealed class Listener(EventWaitHandle signal, RegisteredWaitHandle registration) : IDisposable
    {
        public void Dispose()
        {
            // Wait until the pool lets go of the event; otherwise a launch right after closing could still open it.
            using var released = new ManualResetEvent(false);
            if (registration.Unregister(released)) released.WaitOne(TimeSpan.FromSeconds(5));
            signal.Dispose();
        }
    }
}
