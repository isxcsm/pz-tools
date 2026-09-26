package pztools.extensions.api;

import java.lang.instrument.Instrumentation;
import java.nio.file.Path;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/** Trusted save capability; game-specific state and bytecode belong to the module. */
public interface SaveProvider {
    int API_MAJOR = 2;
    String id();
    /** Opt-in: close() must retire all observers and threads without abandoning accepted work. */
    default boolean supportsReload() { return false; }
    default void close() throws Exception { throw new UnsupportedOperationException("Provider requires a game restart"); }
    /** Connection-thread initialization, before any save is admitted. */
    default Support initialize(Instrumentation instrumentation, ClassLoader gameClasses) throws Exception {
        return new Support(true, null);
    }
    Support inspect(Context context);
    /** Side-effect-free game-thread probe. False yields to the next tick, never starts or partially saves. */
    default boolean readyToCapture(Context context) throws Exception { context.requireGameThread(); return true; }
    PreparedSave capture(Context context, long maximumBytes) throws Exception;

    record Context(String requestId, String sessionId, String worldId, Path sourcePath,
                   Thread gameThread, ClassLoader gameClasses, AtomicBoolean worldValid, String gameVersion, boolean forceVersion) {
        public Context(String requestId, String sessionId, String worldId, Path sourcePath,
                       Thread gameThread, ClassLoader gameClasses) {
            this(requestId, sessionId, worldId, sourcePath, gameThread, gameClasses, new AtomicBoolean(true), null, false);
        }
        public Context(String requestId, String sessionId, String worldId, Path sourcePath,
                       Thread gameThread, ClassLoader gameClasses, AtomicBoolean worldValid) {
            this(requestId, sessionId, worldId, sourcePath, gameThread, gameClasses, worldValid, null, false);
        }
        public Context {
            Objects.requireNonNull(requestId); Objects.requireNonNull(sessionId); Objects.requireNonNull(worldId);
            Objects.requireNonNull(sourcePath); Objects.requireNonNull(gameThread);
            Objects.requireNonNull(gameClasses); Objects.requireNonNull(worldValid);
            if (!sourcePath.isAbsolute()) throw new IllegalArgumentException("Absolute save path required");
        }
        public void requireGameThread() {
            if (Thread.currentThread() != gameThread) throw new IllegalStateException("Wrong game thread");
            if (!worldValid.get()) throw new IllegalStateException("World session ended");
        }
    }
    record Support(boolean supported, String reason) { }
    enum Completion { DETACHED_WRITES_COMMITTED, GAME_SAVE_AND_DATABASE_QUEUES_DRAINED, GAME_SAVE_AND_PENDING_WRITES_DRAINED }

    /**
     * Detached writes or a game-owned completion fence, never mutable world objects.
     * The retained budget must be enforced during capture. commit() may wait on a worker,
     * not on the game thread. A drained database queue is NOT an atomic world snapshot.
     */
    interface PreparedSave extends AutoCloseable {
        long retainedBytes();
        /** Bounded, non-sensitive per-request diagnostics, not a completion signal. */
        default String diagnostics() { return ""; }
        void commit() throws Exception;
        default Completion completion() { return Completion.DETACHED_WRITES_COMMITTED; }
        @Override void close() throws Exception;
    }
}
