using System.Security.Cryptography;
using System.Text;

namespace PzTools.Process.Hosting;

public sealed record MutexRunResult<T>(bool Acquired, bool WasAbandoned, T? Value);

public static class NamedMutexRunner
{
    public static string CreateName(string scope, string identity)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(scope);
        ArgumentException.ThrowIfNullOrWhiteSpace(identity);
        var normalized = identity.Trim()
            .Replace(Path.AltDirectorySeparatorChar, Path.DirectorySeparatorChar)
            .TrimEnd(Path.DirectorySeparatorChar)
            .ToUpperInvariant();
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized)));
        return $"Local\\PzTools.{scope}.{digest}";
    }

    public static Task<MutexRunResult<T>> TryRunAsync<T>(
        string mutexName,
        Func<CancellationToken, Task<T>> action,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(mutexName);
        ArgumentNullException.ThrowIfNull(action);
        return Task.Factory.StartNew(
            () => RunOnDedicatedThread(mutexName, action, cancellationToken),
            cancellationToken,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);
    }

    private static MutexRunResult<T> RunOnDedicatedThread<T>(
        string mutexName,
        Func<CancellationToken, Task<T>> action,
        CancellationToken cancellationToken)
    {
        using var mutex = new Mutex(false, mutexName);
        var acquired = false;
        var abandoned = false;
        try
        {
            try
            {
                acquired = mutex.WaitOne(0);
            }
            catch (AbandonedMutexException)
            {
                acquired = true;
                abandoned = true;
            }

            if (!acquired)
            {
                return new MutexRunResult<T>(false, false, default);
            }

            return new MutexRunResult<T>(
                true,
                abandoned,
                action(cancellationToken).GetAwaiter().GetResult());
        }
        finally
        {
            if (acquired)
            {
                mutex.ReleaseMutex();
            }
        }
    }
}
