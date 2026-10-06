package pztools.bridge.runtime;

import pztools.bridge.AgentEntry;
import pztools.extensions.api.*;
import java.io.IOException;
import java.io.InputStream;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.SecureRandom;
import java.util.*;

/**
 * The extensions of a game the startup loader started (docs/design/startup-loader.md, "Resident extensions"). The app
 * writes what it wants running to {@code resident.tsv} in the install folder; this controller applies it in each world
 * the player loads, with or without the app. While the app is connected, the app controls the extensions and this one
 * waits; when the app's connection ends, the extensions keep running and this one takes them back.
 *
 * <p>It speaks to the extension host through the same {@link ExtensionControl.Session} the app's connection uses, so a
 * request from either is checked the same way, and it never retries a request the game refused in the same world.
 */
public final class ResidentExtensions {
    static final String DESIRED = "resident.tsv";
    private static final int MAX_DESIRED = 1 << 20;
    private static final long INTERVAL_MILLIS = 1000, WAKE_MILLIS = 250;
    private static final Object gate = new Object();
    // Guarded by gate.
    private static Path root;
    private static Instrumentation instrumentation;
    private static Thread runner;
    private static int pauses;
    private static ExtensionControl.Session owner;

    private ResidentExtensions() { }

    /** Called by the bootstrap with the install folder, once per payload. Starts the controller unless it runs. */
    public static void start(String installFolder, Instrumentation value) {
        Path folder = Path.of(installFolder);
        if (!folder.isAbsolute()) throw new IllegalArgumentException("Absolute install folder required");
        synchronized (gate) {
            root = folder; instrumentation = value;
            if (runner != null && runner.isAlive()) return;
            runner = new Thread(ResidentExtensions::run, "PzTools-resident-extensions");
            runner.setDaemon(true);
            runner.start();
        }
    }

    /** Whether this game was started by the startup loader, so that an app's connection hands the extensions back. */
    static boolean started() { synchronized (gate) { return root != null; } }

    /** Gives the extensions to an app's connection: returns once this controller has let go of them. */
    static void pause() {
        ExtensionControl.Session current;
        synchronized (gate) {
            pauses++;
            current = owner; owner = null;
            gate.notifyAll();
        }
        // Closing waits for a command in flight; the modules are kept for the app.
        if (current != null) current.close();
    }

    /** The app's connection ended: this controller takes the extensions back, starting again if it had ended. */
    static void resume() {
        synchronized (gate) {
            if (pauses > 0) pauses--;
            gate.notifyAll();
            if (root != null && (runner == null || !runner.isAlive()) && AgentEntry.residentCurrent(ResidentExtensions.class)) {
                runner = new Thread(ResidentExtensions::run, "PzTools-resident-extensions");
                runner.setDaemon(true);
                runner.start();
            }
        }
    }

    private static void run() {
        var controller = new Controller();
        try {
            long next = System.nanoTime();
            while (true) {
                if (AgentEntry.runtimeReloadRequested()) {
                    // A payload reload waits for the lifecycle slot. Should it fail, this controller goes on; should
                    // it succeed, the new payload starts its own and this one ends.
                    ExtensionControl.Session current;
                    synchronized (gate) { current = owner; }
                    if (current != null) release(current);
                } else if (!AgentEntry.residentCurrent(ResidentExtensions.class)) return;
                else if (System.nanoTime() - next >= 0) {
                    next = System.nanoTime() + INTERVAL_MILLIS * 1_000_000;
                    ExtensionControl.Session current;
                    synchronized (gate) { current = pauses == 0 ? owner : null; }
                    if (current == null && !paused()) current = acquire(controller);
                    if (current != null && !controller.reconcile(current, rootValue())) release(current);
                }
                synchronized (gate) { gate.wait(WAKE_MILLIS); }
            }
        } catch (InterruptedException stopped) {
            Thread.currentThread().interrupt();
        } catch (Throwable failure) {
            System.err.println("[PzTools resident extensions] " + failure);
        } finally {
            ExtensionControl.Session current;
            synchronized (gate) {
                current = owner; owner = null;
                if (runner == Thread.currentThread()) runner = null;
            }
            if (current != null) current.close();
        }
    }

    private static boolean paused() { synchronized (gate) { return pauses > 0; } }

    /**
     * Takes the lifecycle slot unless an app's connection paused this controller meanwhile. The session is made outside
     * the gate: it installs the game hook the first time, which a pause must not wait for.
     */
    private static ExtensionControl.Session acquire(Controller controller) {
        ExtensionControl.Session session = controller.session();
        if (session == null) return null;
        synchronized (gate) {
            if (pauses == 0 && owner == null && AgentEntry.acquireLifecycle(session, session::poll)) { owner = session; return session; }
        }
        session.close();
        return null;
    }

    private static void release(ExtensionControl.Session session) {
        synchronized (gate) { if (owner == session) owner = null; else return; }
        session.close();
    }

    /** What the app last asked for: its settings revision and each continuous module, on or off, with its configuration. */
    record Desired(long revision, List<Module> modules) { }
    record Module(String id, boolean enabled, boolean force, String config) { }

    /** Null when the app has not written the file, or wrote one this version does not read: then nothing changes. */
    static Desired readDesired(Path folder) {
        Path file = folder.resolve(DESIRED);
        byte[] bytes;
        try (InputStream input = Files.newInputStream(file, LinkOption.NOFOLLOW_LINKS)) { bytes = input.readNBytes(MAX_DESIRED + 1); }
        catch (IOException unreadable) { return null; }
        if (bytes.length > MAX_DESIRED) return null;
        String[] lines = new String(bytes, StandardCharsets.UTF_8).split("\r?\n", -1);
        if (lines.length < 2 || !lines[0].equals("PZTOOLS-RESIDENT\t1")) return null;
        String[] revision = lines[1].split("\t", -1);
        if (revision.length != 2 || !revision[0].equals("revision") || !revision[1].matches("[0-9]{1,18}")) return null;
        var modules = new ArrayList<Module>();
        var ids = new HashSet<String>();
        for (int index = 2; index < lines.length; index++) {
            String line = lines[index];
            if (line.isEmpty()) continue;
            String[] p = line.split("\t", -1);
            if (p.length != 5 || !p[0].equals("module") || !p[1].matches("[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+") || !ids.add(p[1])
                    || !Set.of("on", "off").contains(p[2]) || !Set.of("normal", "force").contains(p[3])
                    || !p[4].matches("[A-Za-z0-9+/=]*") || modules.size() >= 64) return null;
            modules.add(new Module(p[1], p[2].equals("on"), p[3].equals("force"), p[4]));
        }
        return new Desired(Long.parseLong(revision[1]), List.copyOf(modules));
    }

    /** One controller run: its own epoch and command numbers, and the requests it already made in each world. */
    static final class Controller {
        private final String epoch;
        private long commands;
        // module -> world and revision last asked for. A refused request is not repeated until either changes.
        private final Map<String, String> attempted = new HashMap<>();

        Controller() {
            byte[] bytes = new byte[16];
            new SecureRandom().nextBytes(bytes);
            epoch = HexFormat.of().formatHex(bytes);
        }

        /** A session that keeps the modules when it ends, or null while the game is not ready for one. */
        ExtensionControl.Session session() {
            try {
                return new ExtensionControl.Session(instrumentationValue(), AgentEntry.ensureGameHook(), System::nanoTime,
                    () -> (ContinuousModules)AgentEntry.extensions(), ExtensionControl::residentHostAbi, false, true);
            } catch (Exception | LinkageError notReady) { return null; } // GameWindow has not loaded yet, for one.
        }

        /** One pass over the wanted modules; false when this session can no longer be used. */
        boolean reconcile(ExtensionControl.Session session, Path folder) {
            String world = session.worldId();
            if (world == null) return true; // No world loaded: the session's poll has already withdrawn the modules.
            Desired desired = readDesired(folder);
            if (desired == null) return true;
            try {
                for (Module module : desired.modules()) reconcile(session, world, desired.revision(), module);
                return true;
            } catch (IOException | RuntimeException unusable) { return false; }
        }

        private void reconcile(ExtensionControl.Session session, String world, long revision, Module module) throws IOException {
            String[] state = command(session, "STATUS\t" + id() + "\t" + epoch + "\t" + module.id()).split("\t", -1);
            String current = state[2], appliedWorld = state[5];
            long applied = Long.parseLong(state[7]);
            boolean running = current.equals("Active") || current.equals("Pending");
            if (!module.enabled()) {
                if (running) command(session, "OFF\t" + id() + "\t" + epoch + "\t" + module.id());
                return;
            }
            if (running && appliedWorld.equals(world) && applied >= revision) return;
            // A module the game cannot run again in this process is left to the app to report.
            if (current.equals("RestartRequired") || current.equals("FaultedPassThrough") && appliedWorld.equals(world)) return;
            String key = world + "\t" + revision;
            if (key.equals(attempted.get(module.id()))) return;
            attempted.put(module.id(), key);
            command(session, String.join("\t", "APPLY", id(), epoch, RuntimeIdentity.processId(), world, Long.toString(applied),
                Long.toString(revision), module.id(), module.force() ? "force" : "normal", module.config()));
        }

        private static String command(ExtensionControl.Session session, String line) throws IOException {
            try { return session.command(line); }
            catch (IOException failure) { throw failure; }
            catch (Exception failure) { throw new IOException(failure); }
        }

        private String id() { return "r" + (++commands); }
    }

    private static Path rootValue() { synchronized (gate) { return root; } }
    private static Instrumentation instrumentationValue() { synchronized (gate) { return instrumentation; } }
}
