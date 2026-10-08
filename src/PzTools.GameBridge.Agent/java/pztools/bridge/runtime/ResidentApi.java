package pztools.bridge.runtime;

import java.nio.file.Path;
import pztools.bridge.AgentEntry;

/**
 * The extension API in a game the startup loader started (docs/design/extension-api.md), run by each payload's startup:
 * the API itself is its own jar ({@link ApiHost}), which outlives a payload switch. This runs the API's per-frame work
 * as the frame router's API job, takes a changed API jar about once a second, and writes which of its hooks the game
 * has to the install folder for the app (api.tsv): with or without the app, and whatever the extensions do. A newer
 * payload's takes over; this one lets go of its job while a payload switch waits.
 */
final class ResidentApi {
    private static final long WAKE_MILLIS = 250, STATUS_NANOS = 1_000_000_000L;
    private static final Object gate = new Object();
    // Guarded by gate.
    private static Path root;
    private static Thread runner;
    // The API the frame job calls: the one ApiHost last gave.
    private static volatile ApiHost.Api api;

    private ResidentApi() { }

    static void start(Path installFolder) {
        if (!installFolder.isAbsolute()) throw new IllegalArgumentException("Absolute install folder required");
        // Before the game's Lua starts: a new API sets its hook for it now.
        try { api = ApiHost.current(); }
        catch (Exception unreadable) { throw new IllegalStateException("The extension API's jar: " + unreadable, unreadable); }
        synchronized (gate) {
            root = installFolder;
            if (runner != null && runner.isAlive()) return;
            runner = new Thread(ResidentApi::run, "PzTools-extension-api");
            runner.setDaemon(true);
            runner.start();
        }
    }

    private static void run() {
        Object owner = new Object();
        boolean held = false;
        String reported = null;
        long nextStatus = System.nanoTime();
        try {
            while (true) {
                // Whatever one pass throws, the next one tries again: the status and the networks must not stop for good.
                try {
                    if (AgentEntry.runtimeReloadRequested()) {
                        if (held) { Frames.remove(Frames.Job.API, owner); held = false; }
                    } else if (!AgentEntry.payloadCurrent(ResidentApi.class)) return;
                    else if (System.nanoTime() - nextStatus >= 0) {
                        // Once a second: the hook may come only with GameWindow, the status as the hooks' classes load,
                        // a changed jar with an update.
                        nextStatus = System.nanoTime() + STATUS_NANOS;
                        api = ApiHost.current();
                        if (!held) held = hold(owner);
                        Path folder;
                        synchronized (gate) { folder = root; }
                        api.writeStatus(folder);
                    }
                } catch (Throwable failure) {
                    String text = String.valueOf(failure);
                    if (!text.equals(reported)) System.err.println("[PzTools API] " + text);
                    reported = text;
                }
                Thread.sleep(WAKE_MILLIS);
            }
        } catch (InterruptedException stopped) {
            Thread.currentThread().interrupt();
        } finally {
            if (held) Frames.remove(Frames.Job.API, owner);
            synchronized (gate) { if (runner == Thread.currentThread()) runner = null; }
        }
    }

    /** The API's job in the frame router, once the game loop has its hook: false until then, and during a switch. */
    private static boolean hold(Object owner) {
        ClassLoader game;
        try { game = AgentEntry.ensureGameHook().getClassLoader(); }
        catch (Exception | LinkageError notYet) { return false; } // GameWindow has not loaded yet, for one.
        return Frames.add(Frames.Job.API, owner, () -> {
            try { api.frame(game); }
            catch (Error | RuntimeException failure) { throw failure; }
            catch (Throwable impossible) { throw new IllegalStateException(impossible); }
        });
    }
}
