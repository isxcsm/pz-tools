package pztools.launch;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Properties;

/**
 * Put in the game's folder by the startup loader install, as {@code pztools/pztools-launch.jar}, and started by
 * {@link BootProvider}, early in the game's main method, inside a handler that ignores anything thrown. It loads the PZ Tools bootstrap from the install folder the
 * way an attach would, so the game has the bridge without the app. Nothing here may stop the game from starting: every
 * failure is written to the install folder's log and the game goes on as vanilla.
 *
 * <p>Two things start it (docs/design/startup-loader.md). The launcher file lists the jar, so the JDK finds the jar's
 * services list and creates {@link BootProvider} (which survives tools that rewrite the class path and drop {@code .});
 * or the frozen shim in the game's folder ({@code pztools.startup.BootProvider}, the only loose class) checks the jar's
 * SHA-256 against the loose settings, loads it with a class loader of its own and calls {@link #start()}. The
 * process-wide {@link #GUARD} makes whichever gets here first the only boot. It reads the settings inside the jar. The
 * guard is this loader's own: another tool's loader (PZ Extension API's) in the same process boots as well.
 *
 * <p>Uses java.base alone: it runs before the game has set anything up.
 */
public final class StartupLoader {
    /** Inside the jar, beside this class: {@code root}, the install folder, and {@code game}. */
    public static final String SETTINGS = StartupLoader.class.getPackageName().replace('.', '/') + "/install.properties";
    /** In the install folder: the bridge folder to load, a tab, and the SHA-256 of its bootstrap jar. */
    public static final String CURRENT = "current";
    public static final String LOG = "startup.log";
    public static final String BOOTSTRAP = "pztools-game-bootstrap.jar";
    public static final String PAYLOAD = "pztools-game-bridge.jar";
    public static final String NATIVE = "pztools-attach-bootstrap.dll";
    /** The jar with the loader, in the game's folder, and its entry in the launcher file's class path. */
    public static final String JAR = "pztools/pztools-launch.jar";
    /** The system property that marks the process as booted by one copy of the loader. */
    public static final String GUARD = "pztools.startup.loader.started";

    private StartupLoader() { }

    private static native int load(String options);

    private static boolean started;

    public static void start() {
        // Once a run per copy: anything that lists the file system providers again makes another BootProvider.
        synchronized (StartupLoader.class) {
            if (started) return;
            started = true;
        }
        Path root = null, game = null;
        try {
            var settings = new Properties();
            try (InputStream input = StartupLoader.class.getClassLoader().getResourceAsStream(SETTINGS)) {
                if (input == null) return;
                settings.load(input);
            }
            root = Path.of(settings.getProperty("root", ""));
            if (!root.isAbsolute()) return;
            String folder = settings.getProperty("game", "");
            if (!folder.isEmpty()) game = Path.of(folder);
            // One boot a process, whichever copy gets here first.
            if (System.getProperties().putIfAbsent(GUARD, LOG) != null) return;
            boot(root);
        } catch (Throwable failure) {
            if (root != null) log(root, "failed: " + failure, false);
        }
        launcher(root, game);
    }

    private static void boot(Path root) throws Exception {
        Path currentFile = root.resolve(CURRENT);
        String[] current = Files.isRegularFile(currentFile, LinkOption.NOFOLLOW_LINKS)
            ? Files.readString(currentFile, StandardCharsets.UTF_8).strip().split("\t", -1) : new String[0];
        if (current.length != 2 || !current[0].matches("bridge-[0-9a-f]{16}") || !current[1].matches("[0-9a-f]{64}")) {
            log(root, "the install's current file is not readable", false);
            return;
        }
        Path bridge = root.resolve(current[0]);
        Path bootstrap = bridge.resolve(BOOTSTRAP), payload = bridge.resolve(PAYLOAD), library = bridge.resolve(NATIVE);
        for (Path file : new Path[] { bootstrap, payload, library })
            if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) {
                log(root, "missing " + file.getFileName(), false);
                return;
            }
        // A half-written install (the app stopped while copying) must not reach the JRE, which prints its errors.
        String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(bootstrap)));
        if (!digest.equals(current[1])) {
            log(root, "the bootstrap does not match the install", false);
            return;
        }
        System.load(library.toString());
        String encoded = Base64.getEncoder().encodeToString(payload.toString().getBytes(StandardCharsets.UTF_8));
        int result = load(bootstrap + "=BOOTSTRAP1:" + encoded + ":STARTUP");
        log(root, result == 0 ? "loaded " + current[0] : "the bootstrap did not load (" + result + ")", false);
    }

    /**
     * The launcher file lists the jar again when a reset of the game's files (a Steam verify or update) took the entry
     * out, so the next rewrite of the class path by another tool keeps it. Never a reason to stop the game: a line
     * in the log (after the boot's), once, when it cannot be done.
     */
    private static void launcher(Path root, Path game) {
        try {
            if (root == null || game == null || !Files.isRegularFile(game.resolve(JAR), LinkOption.NOFOLLOW_LINKS)) return;
            String state = Launcher.ensure(game.resolve(Launcher.FILE), JAR);
            if (state.equals("added")) log(root, "launcher: the class path entry was missing; added", true);
            else if (state.equals("unreadable")) log(root, "launcher: no class path list to add the entry to", true);
        } catch (Throwable failure) {
            log(root, "launcher: " + failure, true);
        }
    }

    /** One line per game start: the log holds the last start only; the boot's line is the first, and later lines follow it. */
    private static void log(Path root, String line, boolean after) {
        try {
            OpenOption[] options = after
                ? new OpenOption[] { StandardOpenOption.CREATE, StandardOpenOption.APPEND }
                : new OpenOption[] { StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE };
            Files.writeString(root.resolve(LOG), Instant.now() + " " + line + System.lineSeparator(), StandardCharsets.UTF_8, options);
        } catch (Throwable ignored) { }
    }
}
