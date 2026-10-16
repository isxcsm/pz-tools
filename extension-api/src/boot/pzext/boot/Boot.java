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
 * ({@link Host}), which a newer jar replaces in a running game only when the developer switch is on ({@link Host#DEV_RELOAD}).
 * It needs nothing but the game and this folder.
 */
public final class Boot {
    /** The API's implementation, beside this jar in the version folder. */
    public static final String API_JAR = "pzext-api.jar";
    /** The boot layer's contract with the implementation jar (its manifest's {@code PZExt-Boot-Api}). */
    public static final String CONTRACT = "1";

    private static volatile Path home;
    // The SHA-256 of the API's jar the install vouches for (hex), or null for a boot layer the tests start by hand.
    private static volatile String apiDigest;
    private static Instrumentation instrumentation;
    private static final Map<String, Object> kept = new HashMap<>();

    private Boot() { }

    /**
     * The loader's call: {@code <base64 of the version folder>,<SHA-256 of the API's jar>} (the digest the install gave
     * the loader, which the host checks against the jar's bytes when it loads them). A second load in the same process
     * is refused.
     */
    public static void agentmain(String arguments, Instrumentation inst) {
        String[] parsed = parse(arguments);
        synchronized (Boot.class) {
            if (instrumentation != null) throw new IllegalStateException("PZ Extension API is loaded already");
            if (Runtime.version().feature() != 25 || !inst.isRetransformClassesSupported())
                throw new IllegalStateException("PZ Extension API needs Java 25 with retransformation");
            instrumentation = inst;
            home = Path.of(parsed[0]);
            apiDigest = parsed[1];
        }
        System.setProperty("pzext.boot", CONTRACT);
        // Before the game loads its Lua: the hook at the end of LuaManager.init waits for the API's handler.
        Hooks.install(inst);
        FrameHook.install(inst, Host::gameWindowLoaded);
    }

    /** The loader's arguments: the version folder and the digest of the API's jar; refused without a digest. */
    static String[] parse(String arguments) {
        String[] parts = (arguments == null ? "" : arguments).split(",", -1);
        if (parts.length != 2 || !parts[1].matches("[0-9a-f]{64}"))
            throw new IllegalStateException("PZ Extension API was started without the digest of its jar");
        return new String[] { new String(Base64.getDecoder().decode(parts[0]), StandardCharsets.UTF_8), parts[1] };
    }

    /** The version folder the loader started: the API's jar and its fonts. */
    public static Path home() {
        Path folder = home;
        if (folder == null) throw new IllegalStateException("PZ Extension API was not started by its loader");
        return folder;
    }

    /** The SHA-256 (hex) the API's jar must have, or null where the boot layer was not started by the loader (the tests). */
    static String apiDigest() { return apiDigest; }

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
