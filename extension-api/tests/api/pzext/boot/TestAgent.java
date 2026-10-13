package pzext.boot;

import java.lang.instrument.Instrumentation;

/** Puts the extension API's hooks into the synthetic game as its classes load, as the boot layer does. */
public final class TestAgent {
    private TestAgent() { }

    public static void premain(String arguments, Instrumentation instrumentation) { Hooks.install(instrumentation); }
}
