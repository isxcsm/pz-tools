import java.lang.instrument.Instrumentation;
/** Test-only premain for offline installed-class admission checks, never packaged with the app. */
public final class PrivateValidationAgent {
    public static Instrumentation instrumentation;
    public static void premain(String ignored, Instrumentation value) { instrumentation = value; }
}
