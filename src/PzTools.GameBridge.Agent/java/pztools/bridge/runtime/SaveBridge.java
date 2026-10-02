package pztools.bridge.runtime;

import java.lang.instrument.Instrumentation;

/**
 * The name the bootstrap loads a payload's request entry by. A bootstrap stays in the game for as long as it runs,
 * so one from an earlier version, from before the bridge was renamed, still asks a newer payload for this class:
 * it stays, and hands each request to {@link BridgeSession}.
 */
public final class SaveBridge {
    private SaveBridge() { }

    public static void run(String options, Instrumentation instrumentation) {
        BridgeSession.run(options, instrumentation);
    }
}
