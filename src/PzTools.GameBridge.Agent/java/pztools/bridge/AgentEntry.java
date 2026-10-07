package pztools.bridge;

import java.lang.instrument.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.atomic.*;

/**
 * The bootstrap (docs/design/game-bridge.md#layers): loaded once per game process and never replaced, so it holds no
 * feature of its own. It takes the agent's arguments, starts the control listener ({@link ControlServer}), keeps the
 * game-loop hook ({@link GameHook}) and the payload ({@link Payload}), and in a game the startup loader started it
 * starts the payload's startup work. The public methods are what a payload calls; no save is performed by the control
 * thread.
 */
public final class AgentEntry {
    public static final String CONTROL_PROPERTY = "pztools.bridge.control.v1";
    /** The bootstrap API: the helper and every payload jar must name this one. */
    static final String API = "12";
    private static Instrumentation instrumentation;
    // In a game the startup loader started: the install's payload, <install folder>\bridge-<id>\<payload>.
    private static volatile Path startupPayload;
    // Whether the control endpoint is set; guarded by the class, as startupPayload's writes are.
    private static boolean endpointPublished;

    private AgentEntry() { }

    public static synchronized void agentmain(String options, Instrumentation value) throws Exception {
        String[] parts = options.split(":", -1);
        boolean startup = parts.length == 3 && parts[2].equals("STARTUP");
        if ((parts.length != 2 && !startup) || !parts[0].equals("BOOTSTRAP1"))
            throw new IllegalArgumentException("Incompatible bootstrap; rebuild app/workers and restart the game");
        Path candidate = Path.of(new String(Base64.getDecoder().decode(parts[1]), StandardCharsets.UTF_8));
        if (!candidate.isAbsolute()) throw new IllegalArgumentException("Absolute payload path required");
        if (instrumentation != null) {
            // The app was open when the game started, and its helper attached before the startup loader ran. The game
            // still becomes one the loader started, with its startup work, rather than refuse the loader.
            if (!startup || startupPayload != null) throw new IllegalStateException("Bootstrap already loaded; reuse its control endpoint");
            becomeStartup(candidate.normalize());
            return;
        }
        Payload.init(candidate.normalize());
        var server = new ServerSocket();
        server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 8);
        byte[] key = new byte[32];
        new SecureRandom().nextBytes(key);
        String secret = HexFormat.of().formatHex(key);
        instrumentation = value;
        if (startup) becomeStartup(candidate.normalize());
        try {
            ControlServer.start(server, secret, value);
            System.setProperty("pztools.bridge.bootstrap.api", API);
            // Published only after the listener is bound. Never print this credential.
            String endpoint = "2:" + ProcessHandle.current().pid() + ":" + server.getLocalPort() + ":" + secret;
            publishAfterPropertyList(endpoint);
        } catch (Throwable failure) {
            server.close();
            throw failure;
        }
    }

    /**
     * Makes this a game the startup loader started: its install, the extension API's Lua hook (before the game's Lua
     * loads), and, once the endpoint is set, the payload's startup work.
     */
    private static void becomeStartup(Path installPayload) {
        boolean ready;
        synchronized (AgentEntry.class) {
            startupPayload = installPayload;
            ready = endpointPublished;
        }
        try { ApiHooks.install(instrumentation); }
        catch (Throwable failure) { System.err.println("[PzTools API] " + failure); }
        if (ready) launchStartup();
    }

    /**
     * A bootstrap can run before the game's main method has written every system property to its log (console.txt),
     * which players post with bug reports: the startup loader's always does, and the helper's does when the app was open
     * as the game started. The endpoint, which holds the secret, is set only once the game loads GameWindow: its main
     * method lists the properties before it first uses that class. The helper waits for it meanwhile (it sees the API
     * property without the endpoint). Nothing is changed in the class.
     */
    private static void publishAfterPropertyList(String endpoint) {
        var published = new AtomicBoolean();
        ClassFileTransformer watcher = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (type == null && "zombie/GameWindow".equals(name) && published.compareAndSet(false, true)) {
                    instrumentation.removeTransformer(this);
                    publish(endpoint);
                }
                return null;
            }
        };
        instrumentation.addTransformer(watcher, false);
        // Already loaded (the usual attach, or a game whose main method differs): the list was written, or never will be.
        for (Class<?> type : instrumentation.getAllLoadedClasses())
            if (type.getName().equals("zombie.GameWindow") && published.compareAndSet(false, true)) {
                instrumentation.removeTransformer(watcher);
                publish(endpoint);
            }
    }

    private static void publish(String endpoint) {
        boolean startup;
        synchronized (AgentEntry.class) {
            System.setProperty(CONTROL_PROPERTY, endpoint);
            endpointPublished = true;
            startup = startupPayload != null;
        }
        if (startup) launchStartup();
    }

    /**
     * Loads the payload and runs its startup work, away from the class loading that calls this. A game started without
     * the app gets its extension API and resident extensions this way; they wait for the game's first frames.
     */
    private static void launchStartup() {
        Thread starter = new Thread(() -> {
            for (int attempt = 0; attempt < 30; attempt++) {
                try {
                    Payload.prepare(Payload.path());
                    Payload.startup(instrumentation);
                    return;
                } catch (Payload.Busy busy) {
                    // An app's connection is replacing the payload; it starts the new one's startup itself.
                } catch (Throwable failure) {
                    System.err.println("[PzTools startup] " + failure);
                }
                try { Thread.sleep(1000); } catch (InterruptedException stopped) { break; }
                if (Payload.started()) return;
            }
            // No payload: the game's Lua stops waiting for the API.
            ApiHooks.set(null);
        }, "PzTools-startup");
        starter.setDaemon(true);
        starter.start();
    }

    static Path startupPayload() { return startupPayload; }

    // ---- what a payload calls ----

    /** The game's {@code GameWindow} class, once the game-loop hook is in it. */
    public static Class<?> ensureGameHook() throws Exception { return GameHook.ensure(instrumentation); }

    /** The call at the start of {@code GameWindow.logic()}. */
    public static void poll() { GameHook.poll(); }

    /** A request's game-thread work, run each frame after the payload's frame router; one request at a time. */
    public static boolean acquire(Object owner, Runnable poll) { return GameHook.acquire(owner, poll); }
    public static void release(Object owner) { GameHook.release(owner); }

    /**
     * The payload's frame router, run first each frame: true once it has the slot (again). Refused while a payload
     * switch waits for the old payload to let go.
     */
    public static boolean claimFrames(Runnable router) { return GameHook.claimFrames(router); }
    public static void releaseFrames(Runnable router) { GameHook.releaseFrames(router); }

    /** A payload switch waits: the payload's sessions and threads let go of what they hold, and end. */
    public static boolean runtimeReloadRequested() { return Payload.reloadRequested(); }

    /** Whether the class belongs to the payload loaded now; one a newer payload replaced ends. */
    public static boolean payloadCurrent(Class<?> type) { return Payload.current(type); }

    /** Where the payload loaded now was read from: the last connection's path for the same bytes. */
    public static Path payloadPath() { return Payload.path(); }

    /**
     * What a payload keeps for the next one, by name (the extension runtime's host, which outlives a payload switch).
     * A payload synchronizes on the map while it replaces an entry.
     */
    public static Map<String, Object> kept() { return Payload.kept(); }

    // Test/diagnostic counters: never include credentials or payload paths.
    public static String diagnostics() {
        // New counters go at the end: readers match the earlier fields as they have always been laid out.
        return "hookInstalls=" + GameHook.installs() + ";payloadLoads=" + Payload.loads() + ";sessions=" + ControlServer.requests()
            + ";callbackActive=" + GameHook.requestCallbackActive() + ";framesActive=" + GameHook.framesActive()
            + ";hookFailures=" + GameHook.failures();
    }
}
