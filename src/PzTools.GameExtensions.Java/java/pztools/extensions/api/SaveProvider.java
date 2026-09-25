package pztools.extensions.api;

import java.nio.file.Path;
import java.util.Objects;

/** Stable, game-class-free save capability. Module lifecycle is separate from this capability. */
public interface SaveProvider {
    int API_MAJOR = 1;
    String id();
    Support inspect(Context context);
    FrozenSnapshot capture(Context context, long maximumBytes) throws Exception;

    record Context(String requestId, String sessionId, String worldId, Path sourcePath,
                   Thread gameThread, ClassLoader gameClasses) {
        public Context {
            Objects.requireNonNull(requestId);
            Objects.requireNonNull(sessionId);
            Objects.requireNonNull(worldId);
            Objects.requireNonNull(sourcePath);
            Objects.requireNonNull(gameThread);
            Objects.requireNonNull(gameClasses);
            if (!sourcePath.isAbsolute()) throw new IllegalArgumentException("Absolute save path required");
        }
        public void requireGameThread() {
            if (Thread.currentThread() != gameThread) throw new IllegalStateException("Wrong game thread");
        }
    }
    record Support(boolean supported, String reason) { }

    /**
     * Owned immutable capture, never live game objects or a pooled buffer that another writer may reuse.
     * The adapter must respect its allocation budget DURING capture, not merely in retainedBytes().
     * commit() must finish its writes and report internally swallowed errors before returning.
     * A completed DB queue alone is not a world checkpoint. Cross-file consistency belongs to the adapter.
     */
    interface FrozenSnapshot extends AutoCloseable {
        long retainedBytes();
        void commit() throws Exception;
        @Override void close() throws Exception;
    }
}
