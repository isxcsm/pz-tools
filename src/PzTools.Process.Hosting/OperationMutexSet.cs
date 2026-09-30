namespace PzTools.Process.Hosting;

public enum OperationMutexScope
{
    RepositoryAccess = 0,
    SaveWrite = 1,
}

public sealed record OperationMutexRequest(
    OperationMutexScope Scope,
    string Identity);

public sealed record OperationMutexSetResult<T>(
    bool Acquired,
    bool WasAbandoned,
    T? Value);

public static class OperationMutexSet
{
    /// <summary>Whether any process currently holds or is taking this lock. Never acquires it.</summary>
    public static bool IsInUse(OperationMutexRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var name = NamedMutexRunner.CreateName(request.Scope.ToString(), Path.GetFullPath(request.Identity));
        try
        {
            if (!Mutex.TryOpenExisting(name, out var mutex)) return false;
            mutex.Dispose();
            return true;
        }
        catch (UnauthorizedAccessException) { return true; }
    }

    public static async Task<OperationMutexSetResult<T>> TryRunAsync<T>(
        IEnumerable<OperationMutexRequest> requests,
        Func<CancellationToken, Task<T>> action,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(requests);
        ArgumentNullException.ThrowIfNull(action);
        var ordered = requests
            .Select(request => request with { Identity = Path.GetFullPath(request.Identity) })
            .Distinct()
            .OrderBy(request => request.Scope)
            .ThenBy(request => request.Identity, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (ordered.Length == 0)
            return new OperationMutexSetResult<T>(true, false, await action(cancellationToken));
        return await AcquireAsync(ordered, 0, action, cancellationToken);
    }

    private static async Task<OperationMutexSetResult<T>> AcquireAsync<T>(
        IReadOnlyList<OperationMutexRequest> requests,
        int index,
        Func<CancellationToken, Task<T>> action,
        CancellationToken cancellationToken)
    {
        if (index == requests.Count)
            return new OperationMutexSetResult<T>(true, false, await action(cancellationToken));

        var request = requests[index];
        var name = NamedMutexRunner.CreateName(request.Scope.ToString(), request.Identity);
        var acquired = await NamedMutexRunner.TryRunAsync(
            name,
            token => AcquireAsync(requests, index + 1, action, token),
            cancellationToken);
        if (!acquired.Acquired || acquired.Value is null)
            return new OperationMutexSetResult<T>(false, acquired.WasAbandoned, default);
        return acquired.Value with
        {
            WasAbandoned = acquired.WasAbandoned || acquired.Value.WasAbandoned,
        };
    }
}
