namespace PzTools.Projections;

public enum ProjectorHealth { Waiting, Healthy, Faulted, Stopped }

public sealed record ProjectorStatus(
    string Name,
    ProjectorHealth Health,
    string? Message,
    DateTimeOffset ChangedUtc);

public sealed class ProjectionHost : IAsyncDisposable
{
    private readonly CancellationTokenSource cancellation = new();
    private readonly List<Task> loops = [];
    private readonly List<LoopRegistration> registrations = [];
    private readonly object gate = new();
    private readonly Dictionary<string, ProjectorStatus> statuses =
        new(StringComparer.Ordinal);
    private bool started;

    public IReadOnlyList<ProjectorStatus> Statuses
    {
        get
        {
            lock (gate) return statuses.Values.OrderBy(item => item.Name).ToArray();
        }
    }

    public void AddLoop(
        string name,
        Func<CancellationToken, Task> projection,
        TimeSpan interval)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        ArgumentNullException.ThrowIfNull(projection);
        if (interval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(interval));
        lock (gate)
        {
            if (started) throw new InvalidOperationException("Projection host is already started.");
            if (statuses.ContainsKey(name))
                throw new ArgumentException($"Projection loop '{name}' is already registered.", nameof(name));
            statuses.Add(name, Status(name, ProjectorHealth.Waiting, null));
            registrations.Add(new LoopRegistration(name, projection, interval));
        }
    }

    public void Start()
    {
        lock (gate)
        {
            if (started) return;
            started = true;
            foreach (var registration in registrations)
            {
                loops.Add(Task.Run(() => RunLoopAsync(
                    registration,
                    cancellation.Token)));
            }
        }
    }

    public async Task ProjectNowAsync(string name, CancellationToken cancellationToken = default)
    {
        LoopRegistration registration;
        lock (gate)
            registration = registrations.Single(item => item.Name == name);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token, cancellationToken);
        // Explicit UI refreshes must use the same background boundary as timer ticks.
        // ConfigureAwait(false) alone does not move synchronous SQLite work off the caller.
        await Task.Run(() => ProjectOneAsync(registration, linked.Token), linked.Token).ConfigureAwait(false);
    }

    private async Task ProjectOneAsync(LoopRegistration registration, CancellationToken token)
    {
        await registration.ExecutionGate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            await registration.Projection(token).ConfigureAwait(false);
            SetStatus(Status(registration.Name, ProjectorHealth.Healthy, null));
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            SetStatus(Status(registration.Name, ProjectorHealth.Faulted, exception.Message));
            throw;
        }
        finally { registration.ExecutionGate.Release(); }
    }

    // Stop periodic and explicit projections without disposing cancellation state
    // that an in-flight refresh may still need while it unwinds.
    public void RequestStop() => cancellation.Cancel();

    public async ValueTask DisposeAsync()
    {
        RequestStop();
        Task[] pending;
        lock (gate) pending = loops.ToArray();
        try { await Task.WhenAll(pending).ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        cancellation.Dispose();
    }

    private async Task RunLoopAsync(
        LoopRegistration registration,
        CancellationToken token)
    {
        using var timer = new PeriodicTimer(registration.Interval);
        try
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    await ProjectOneAsync(registration, token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception exception)
                {
                    SetStatus(Status(registration.Name, ProjectorHealth.Faulted, exception.Message));
                }
                if (!await timer.WaitForNextTickAsync(token).ConfigureAwait(false)) break;
            }
        }
        finally
        {
            SetStatus(Status(registration.Name, ProjectorHealth.Stopped, null));
        }
    }

    private void SetStatus(ProjectorStatus status)
    {
        lock (gate)
        {
            if (statuses.TryGetValue(status.Name, out var previous)
                && previous.Health == status.Health
                && StringComparer.Ordinal.Equals(previous.Message, status.Message))
                status = status with { ChangedUtc = previous.ChangedUtc };
            statuses[status.Name] = status;
        }
    }

    private static ProjectorStatus Status(
        string name,
        ProjectorHealth health,
        string? message) => new(name, health, message, DateTimeOffset.UtcNow);

    private sealed record LoopRegistration(
        string Name,
        Func<CancellationToken, Task> Projection,
        TimeSpan Interval)
    {
        public SemaphoreSlim ExecutionGate { get; } = new(1, 1);
    }
}
