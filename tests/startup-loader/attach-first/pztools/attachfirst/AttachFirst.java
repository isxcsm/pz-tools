package pztools.attachfirst;

import java.lang.instrument.Instrumentation;

/**
 * Stands in for the app's helper attaching to a game that has only just started: it loads the bootstrap the way the
 * helper does (option BOOTSTRAP1:&lt;payload&gt;) before the game's main method, and so before the startup loader runs.
 */
public final class AttachFirst {
    private AttachFirst() { }

    public static void premain(String options, Instrumentation instrumentation) throws Exception {
        Class.forName("pztools.bridge.AgentEntry").getMethod("agentmain", String.class, Instrumentation.class)
            .invoke(null, options, instrumentation);
    }
}
