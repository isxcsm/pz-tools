package pztools.extensions.api;

import java.lang.ref.WeakReference;
import java.util.UUID;

/** Shared process/world identities for observation and commands. Never owns a game world. */
public final class RuntimeIdentity {
    private static final String PROCESS = id();
    private static WeakReference<Object> knownCell = new WeakReference<>(null);
    private static String world = id();
    private RuntimeIdentity() { }
    private static String id() { return UUID.randomUUID().toString().replace("-", ""); }
    public static String processId() { return PROCESS; }
    public static synchronized String worldId(Object cell) {
        if (cell == null) throw new IllegalArgumentException("World cell required");
        if (knownCell.get() != cell) { knownCell = new WeakReference<>(cell); world = id(); }
        return world;
    }
    public static synchronized void forgetWorld() { knownCell.clear(); }
}