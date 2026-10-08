package pztools.bridge;

import java.io.IOException;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.file.Path;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import pztools.extensions.api.internal.ClassArchive;

/**
 * The payload (docs/design/module-reload.md#payload): the jar loaded now, its one entry, and the switch to another.
 *
 * <p>The entry is {@code pztools.bridge.runtime.PayloadEntry.dispatch(kind, options, instrumentation)}, which returns
 * the work of one session, or null for a kind the payload does not know. The bootstrap passes every kind through and
 * runs what comes back; it knows only two kinds of its own: {@link #REQUEST}, a connection that names none, and
 * {@link #STARTUP}, which it dispatches itself once per payload in a game the startup loader started. A new kind of
 * session, or a new job of the payload, needs no change here.
 */
final class Payload {
    static final String REQUEST = "REQUEST", STARTUP = "STARTUP";
    private static final String ENTRY = "pztools.bridge.runtime.PayloadEntry";
    // Guarded by the class: one load or switch at a time. Taken before GameHook's and ControlServer's locks, never
    // after them, and never held while the payload's code runs.
    private static volatile Path path;
    private static String digest;
    private static volatile Method entry;
    // The entry whose startup ran.
    private static Method started;
    private static volatile boolean reloadRequested;
    private static volatile long loads;
    private static final Map<String, Object> kept = Collections.synchronizedMap(new HashMap<>());

    private Payload() { }

    static final class Busy extends Exception { }

    /** The payload the first bootstrap load names; loaded by the first connection, or by the startup. */
    static void init(Path first) { path = first; }

    static Path path() { return path; }

    static boolean reloadRequested() { return reloadRequested; }

    static long loads() { return loads; }

    static Map<String, Object> kept() { return kept; }

    /** Whether the class belongs to the payload loaded now. Not locked: a switch holds the lock while it waits. */
    static boolean current(Class<?> type) {
        Method current = entry;
        return current != null && current.getDeclaringClass().getClassLoader() == type.getClassLoader();
    }

    /**
     * Loads the requested payload, or reuses the loaded one if its bytes are the same, and returns its entry. A new
     * payload is linked before anything is stopped; then the running sessions and the old payload's per-frame work are
     * asked to end, and the switch waits up to 3 seconds for them. No callback is executed under this lock.
     */
    static Method prepare(Path requested) throws Exception {
        synchronized (Payload.class) {
            var archive = ClassArchive.read(requested);
            archive.require("PzTools-Bootstrap-Api", AgentEntry.API);
            if (entry != null && archive.digest().equals(digest)) {
                if (!path.equals(requested)) {
                    // The payload's folder decides where its extensions are read from; a running request uses them.
                    if (ControlServer.running(REQUEST) || GameHook.requestActive()) throw new Busy();
                    path = requested;
                }
                return entry;
            }
            if (ControlServer.running(REQUEST) || GameHook.requestActive()) throw new Busy();
            // Stage and link before asking the old payload to finish.
            var loader = archive.loader("pztools.bridge.runtime", AgentEntry.class.getClassLoader(), false);
            Method next = loader.loadClass(ENTRY).getMethod("dispatch", String.class, String.class, Instrumentation.class);
            if (!Modifier.isStatic(next.getModifiers()) || next.getReturnType() != Runnable.class)
                throw new IOException("Incompatible payload entry");
            // The old payload's sessions and threads let go when they see this, and end.
            reloadRequested = true;
            // Nothing new is taken from here on, so what the old payload holds only goes.
            GameHook.pause(true);
            try {
                long deadline = System.nanoTime() + 3_000_000_000L;
                while (!ControlServer.idle() || !GameHook.idle()) {
                    if (System.nanoTime() >= deadline) throw new Busy();
                    Thread.sleep(10); // Control or startup thread only; never wait in game dispatch.
                }
                entry = next; digest = archive.digest();
                path = requested; loads++;
                return entry;
            } finally {
                GameHook.pause(false);
                reloadRequested = false;
            }
        }
    }

    /** The work of one session of this kind, or null when the payload does not know the kind. */
    static Runnable session(Method entry, String kind, String options, Instrumentation instrumentation) throws Exception {
        return (Runnable)entry.invoke(null, kind, options, instrumentation);
    }

    /**
     * In a game the startup loader started: the payload loaded now gets its startup, once, with the install's payload
     * path. Runs on the calling thread; the payload's startup only starts its own threads.
     */
    static void startup(Instrumentation instrumentation) {
        Path install = AgentEntry.startupPayload();
        Method current;
        synchronized (Payload.class) {
            if (install == null || entry == null || started == entry) return;
            current = started = entry;
        }
        try {
            Runnable work = session(current, STARTUP, install.toString(), instrumentation);
            if (work == null) System.err.println("[PzTools startup] The payload has no startup");
            else work.run();
        } catch (Throwable failure) { System.err.println("[PzTools startup] " + failure); }
    }

    static boolean started() { synchronized (Payload.class) { return started != null; } }
}
