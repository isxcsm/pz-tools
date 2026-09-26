package pztools.extensions.api;

import java.lang.instrument.Instrumentation;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;

/** Trusted, explicitly owned continuous capability. Constructors must have no side effects. */
public interface ContinuousProvider extends AutoCloseable {
    String id();
    /** Connection thread, before retiring the old generation. May inspect but must not install owned effects. */
    default Support preflight(Instrumentation instrumentation, ClassLoader gameClasses, PreflightSource activeSource) throws Exception {
        return new Support(true, null);
    }
    /** A refreshed snapshot at the existing transformer's input, before its own hooks; null if not owned. */
    default byte[] capturePreflightInput(Class<?> target) throws Exception { return null; }
    /** Borrowed only for preflight; candidates must not retain the source or its old generation. */
    @FunctionalInterface interface PreflightSource { byte[] capture(Class<?> target) throws Exception; }
    /** Connection thread: validate the target and install only inert instrumentation. */
    Support initialize(Instrumentation instrumentation, ClassLoader gameClasses) throws Exception;
    /** Connection thread; reject invalid configuration before retiring or changing an activation. */
    default void validateConfig(Map<String, String> config) throws Exception { }
    /** Side-effect-free game-thread admission check. */
    default boolean readyToActivate(Context context, Map<String, String> config) throws Exception {
        context.requireGameThread(); return true;
    }
    void activate(Context context, Map<String, String> config) throws Exception;
    void updateConfig(Map<String, String> config) throws Exception;
    /** Any thread: bounded, read-only latest fault, or null. Must not inspect/write game state. */
    default String failureReason() { return null; }
    /** Bounded latest-only diagnostics; called on the connection thread, never formats per frame. */
    default String diagnostics() { return ""; }
    /** Any thread: revoke new callbacks immediately, without waiting or writing game fields. */
    void deactivate();
    /** Connection thread, after lifecycle callbacks drained: retire hooks and owned references. */
    @Override void close() throws Exception;
    record Support(boolean supported, String reason) { }
    /** worldIdentity is WATCH's current cell object, not the long-lived IsoWorld singleton. */
    record Context(String processId, String worldId, Object worldIdentity, Thread gameThread,
                   ClassLoader gameClasses, AtomicBoolean worldValid) {
        public Context {
            Objects.requireNonNull(processId); Objects.requireNonNull(worldId); Objects.requireNonNull(worldIdentity);
            Objects.requireNonNull(gameThread); Objects.requireNonNull(gameClasses); Objects.requireNonNull(worldValid);
        }
        public void requireGameThread() {
            if (Thread.currentThread() != gameThread) throw new IllegalStateException("Wrong game thread");
            if (!worldValid.get()) throw new IllegalStateException("World session ended");
        }
    }
}
