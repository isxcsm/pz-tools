package pztools.bridge;

import java.lang.instrument.Instrumentation;

/** Puts the extension API's hooks into the synthetic game as its classes load, as the startup loader's bootstrap does. */
public final class ApiTestAgent {
    private ApiTestAgent() { }

    public static void premain(String arguments, Instrumentation instrumentation) { ApiHooks.install(instrumentation); }
}
