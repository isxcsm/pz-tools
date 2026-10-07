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

/// <summary>What another launch asks of the running instance.</summary>
public enum ApplicationRequest
{
    /// <summary>Show the window, instead of exiting silently, which looks like "the app does not start" when the
    /// running instance is hidden in the tray.</summary>
    Activate,

    /// <summary>Close as the Exit button does, without asking (a development restart asks it, see
    /// scripts/dev/elevated-launcher.ps1).</summary>
    Exit,
}

/// <summary>Lets a second launch ask the running instance for an <see cref="ApplicationRequest"/>.</summary>
public static class ApplicationRequestSignal
{
    private static string Name(string dataRoot, ApplicationRequest request) =>
        NamedMutexRunner.CreateName(request switch
        {
            ApplicationRequest.Activate => "AppActivate",
            ApplicationRequest.Exit => "AppExit",
            _ => throw new ArgumentOutOfRangeException(nameof(request)),
        }, Path.GetFullPath(dataRoot));

    /// <summary>Runs <paramref name="handle"/> on a pool thread each time another launch signals the request.</summary>
    public static IDisposable Listen(string dataRoot, ApplicationRequest request, Action handle)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);
        ArgumentNullException.ThrowIfNull(handle);
        var signal = new EventWaitHandle(false, EventResetMode.AutoReset, Name(dataRoot, request));
        var registration = ThreadPool.RegisterWaitForSingleObject(
            signal, (_, timedOut) => { if (!timedOut) handle(); }, null, Timeout.Infinite, executeOnlyOnce: false);
        return new Listener(signal, registration);
    }

    /// <summary>False when no instance is listening (for example it is still starting or shutting down).</summary>
    public static bool TrySignal(string dataRoot, ApplicationRequest request)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);
        // Opening a named event exists only on Windows; elsewhere the second launch simply finds no listener.
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            if (!EventWaitHandle.TryOpenExisting(Name(dataRoot, request), out var signal)) return false;
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
