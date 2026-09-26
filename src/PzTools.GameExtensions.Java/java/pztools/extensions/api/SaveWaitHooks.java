package pztools.extensions.api;

import java.util.Objects;

/** Optional completion-wait handoff; the module owns game-specific fields and completion semantics. */
public final class SaveWaitHooks {
    public interface Handler {
        void beforeSave(Object operation);
        boolean deferWait(Object operation);
        void beforeStop(Object operation);
    }
    private static volatile Handler handler;
    private SaveWaitHooks() { }
    public static synchronized void register(Handler value) {
        Objects.requireNonNull(value);
        if (handler != null) throw new IllegalStateException("Save wait already owned");
        handler = value;
    }
    public static synchronized void unregister(Handler value) { if (handler == value) handler = null; }
    public static void beforeSave(Object operation) {
        Handler current = handler;
        if (current != null) current.beforeSave(operation);
    }
    public static boolean deferWait(Object operation) {
        Handler current = handler;
        return current != null && current.deferWait(operation);
    }
    public static void beforeStop(Object operation) {
        Handler current = handler;
        if (current != null) current.beforeStop(operation);
    }
}
