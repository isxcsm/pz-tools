package pztools.extensions.api;

/** Nonblocking observation across the stable bootstrap/module class-loader boundary. */
public interface SaveTask {
    record Result(String requestId, String sessionId, String worldId,
                  SaveProvider.Completion completion, Throwable failure, boolean cancelled) { }
    /** null means not finished, even if a worker has already dequeued its input. */
    Result completed();
    default String diagnostics() { return ""; }
}
