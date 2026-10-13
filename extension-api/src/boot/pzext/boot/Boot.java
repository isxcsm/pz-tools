package pzext.boot;

import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;

/**
 * The boot layer of PZ Extension API (docs/loader.md): loaded once per game process by the loader in the game's folder
 * ({@code pzext.loader.Loader}), early in the game's main method, and never replaced. It puts the API's hooks into the
 * game's classes as they load ({@link Hooks}), adds one call at the start of {@code GameWindow.logic()} for the API's
 * per-frame work ({@link FrameHook}), and once the game has loaded {@code GameWindow} runs the API from its own jar
 * ({@link Host}), which a newer jar replaces in a running game. It needs nothing but the game and this folder.
 */
public final class Boot {
    /** The API's implementation, beside this jar in the version folder. */
    public static final String API_JAR = "pzext-api.jar";
    /** The boot layer's contract with the implementation jar (its manifest's {@code PZExt-Boot-Api}). */
    public static final String CONTRACT = "1";

    private static volatile Path home;
    private static Instrumentation instrumentation;
    private static final Map<String, Object> kept = new HashMap<>();

    private Boot() { }

    /** The loader's call: {@code <base64 of the version folder>}. A second load in the same process is refused. */
    public static void agentmain(String arguments, Instrumentation inst) {
        synchronized (Boot.class) {
            if (instrumentation != null) throw new IllegalStateException("PZ Extension API is loaded already");
            if (Runtime.version().feature() != 25 || !inst.isRetransformClassesSupported())
                throw new IllegalStateException("PZ Extension API needs Java 25 with retransformation");
            instrumentation = inst;
            home = Path.of(new String(Base64.getDecoder().decode(arguments == null ? "" : arguments), StandardCharsets.UTF_8));
        }
        System.setProperty("pzext.boot", CONTRACT);
        // Before the game loads its Lua: the hook at the end of LuaManager.init waits for the API's handler.
        Hooks.install(inst);
        FrameHook.install(inst, Host::gameWindowLoaded);
    }

    /** The version folder the loader started: the API's jar and its fonts. */
    public static Path home() {
        Path folder = home;
        if (folder == null) throw new IllegalStateException("PZ Extension API was not started by its loader");
        return folder;
    }

    /** For the tests, which start the boot layer without the loader. */
    static void home(Path folder) { home = folder; }

    /**
     * What an API keeps for the one that replaces it in a running game (the fonts it baked, the pictures in video
     * memory): one map for the life of the process. Callers synchronize on it.
     */
    public static Map<String, Object> kept() { return kept; }

    /** Each frame, at the start of {@code GameWindow.logic()}, on the game's thread. */
    public static void frame() { Host.frame(); }
}
