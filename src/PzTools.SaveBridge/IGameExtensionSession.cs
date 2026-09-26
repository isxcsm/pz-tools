using PzTools.Process.Contracts.GameRuntime;

namespace PzTools.SaveBridge;

/// <summary>A single authenticated continuous-control lease; independent of WATCH and save requests.</summary>
public interface IGameExtensionSession : IAsyncDisposable
{
    Task<RuntimeExtensionStatus> StatusAsync(CancellationToken token);
    Task<RuntimeExtensionStatus> PingAsync(CancellationToken token);
    Task<RuntimeExtensionStatus> ApplyAsync(string processSession, string worldSession,
        long expectedRevision, long revision, string moduleId, bool forceVersion,
        IReadOnlyDictionary<string, string> configuration, CancellationToken token);
}
