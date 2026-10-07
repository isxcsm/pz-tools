package pztools.bridge.runtime;

import java.lang.instrument.Instrumentation;
import java.nio.file.Path;

/**
 * The payload's one entry (docs/design/game-bridge.md#layers). The bootstrap hands every session here by its kind and
 * runs the work that comes back, on a thread of the session's own; a new kind is added here, never in the bootstrap.
 * Called on the bootstrap's control thread: it only picks the work.
 */
public final class PayloadEntry {
    private PayloadEntry() { }

    /** The work of one session of this kind, or null for a kind this payload does not know. */
    public static Runnable dispatch(String kind, String options, Instrumentation instrumentation) {
        return switch (kind) {
            // Saves, probes, profile and notice commands: one request each.
            case "REQUEST" -> () -> BridgeSession.run(options, instrumentation);
            case "WATCH" -> () -> RuntimeWatch.run(options, instrumentation);
            case "EXTENSIONS" -> () -> ExtensionControl.run(options, instrumentation);
            // The bootstrap's own, once per payload in a game the startup loader started; options is the install's payload.
            case "STARTUP" -> () -> startup(options, instrumentation);
            default -> null;
        };
    }

    /**
     * A game the startup loader started (docs/design/startup-loader.md): the extension API and the resident extensions
     * run in it with or without the app. Each starts on its own, and a failure of one leaves the other.
     */
    private static void startup(String installPayload, Instrumentation instrumentation) {
        Path payload = Path.of(installPayload);
        if (!payload.isAbsolute()) throw new IllegalArgumentException("Absolute install payload required");
        // <install folder>\bridge-<id>\<payload>
        Path bridge = payload.getParent(), install = bridge.getParent();
        ExtensionHost.install(bridge);
        try { ResidentApi.start(install); }
        catch (Throwable failure) { System.err.println("[PzTools API] " + failure); }
        try { ResidentExtensions.start(install, instrumentation); }
        catch (Throwable failure) { System.err.println("[PzTools resident extensions] " + failure); }
    }
}
