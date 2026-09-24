namespace PzTools.Process.Hosting;

/// <summary>Transfers ownership only after every non-blocking acquisition succeeds.</summary>
public sealed class SemaphoreAdmission : IAsyncDisposable
{
    private List<SemaphoreSlim>? held;
    private SemaphoreAdmission(List<SemaphoreSlim> held) => this.held = held;

    public static async Task<SemaphoreAdmission?> TryAcquireAsync(IEnumerable<SemaphoreSlim> gates,
        CancellationToken cancellationToken = default)
    {
        var held = new List<SemaphoreSlim>();
        var transferred = false;
        try
        {
            foreach (var gate in gates)
            {
                if (!await gate.WaitAsync(0, cancellationToken)) return null;
                held.Add(gate);
            }
            var admission = new SemaphoreAdmission(held);
            transferred = true;
            return admission;
        }
        finally
        {
            if (!transferred)
                for (var i = held.Count - 1; i >= 0; i--) held[i].Release();
        }
    }

    public ValueTask DisposeAsync()
    {
        var acquired = Interlocked.Exchange(ref held, null);
        if (acquired is not null)
            for (var i = acquired.Count - 1; i >= 0; i--) acquired[i].Release();
        return ValueTask.CompletedTask;
    }
}
