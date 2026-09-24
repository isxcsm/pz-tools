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
