package pztools.startup;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Properties;

/**
 * Put in the game's folder by the startup loader install and started by {@link BootProvider}, early in the game's main
 * method, inside a handler that ignores anything thrown. It loads the PZ Tools bootstrap from the install folder the
 * way an attach would, so the game has the bridge without the app. Nothing here may stop the game from starting: every
 * failure is written to the install folder's log and the game goes on as vanilla.
 *
 * <p>Uses java.base alone: it runs before the game has set anything up.
 */
public final class StartupLoader {
    /** In the game's folder beside this class: {@code root}, the install folder. */
    public static final String SETTINGS = "pztools/startup/install.properties";
    /** In the install folder: the bridge folder to load, a tab, and the SHA-256 of its bootstrap jar. */
    public static final String CURRENT = "current";
    public static final String LOG = "startup.log";
    public static final String BOOTSTRAP = "pztools-game-bootstrap.jar";
    public static final String PAYLOAD = "pztools-game-bridge.jar";
    public static final String NATIVE = "pztools-attach-bootstrap.dll";

    private StartupLoader() { }

    private static native int load(String options);

    private static boolean started;

    public static void start() {
        // Once a run: anything that lists the file system providers again makes another BootProvider.
        synchronized (StartupLoader.class) {
            if (started) return;
            started = true;
        }
        Path root = null;
        try {
            var settings = new Properties();
            try (InputStream input = StartupLoader.class.getClassLoader().getResourceAsStream(SETTINGS)) {
                if (input == null) return;
                settings.load(input);
            }
            root = Path.of(settings.getProperty("root", ""));
            if (!root.isAbsolute()) return;
            Path currentFile = root.resolve(CURRENT);
            String[] current = Files.isRegularFile(currentFile, LinkOption.NOFOLLOW_LINKS)
                ? Files.readString(currentFile, StandardCharsets.UTF_8).strip().split("\t", -1) : new String[0];
            if (current.length != 2 || !current[0].matches("bridge-[0-9a-f]{16}") || !current[1].matches("[0-9a-f]{64}")) {
                log(root, "the install's current file is not readable");
                return;
            }
            Path bridge = root.resolve(current[0]);
            Path bootstrap = bridge.resolve(BOOTSTRAP), payload = bridge.resolve(PAYLOAD), library = bridge.resolve(NATIVE);
            for (Path file : new Path[] { bootstrap, payload, library })
                if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) {
                    log(root, "missing " + file.getFileName());
                    return;
                }
            // A half-written install (the app stopped while copying) must not reach the JRE, which prints its errors.
            String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(bootstrap)));
            if (!digest.equals(current[1])) {
                log(root, "the bootstrap does not match the install");
                return;
            }
            System.load(library.toString());
            String encoded = Base64.getEncoder().encodeToString(payload.toString().getBytes(StandardCharsets.UTF_8));
            int result = load(bootstrap + "=BOOTSTRAP1:" + encoded + ":STARTUP");
            log(root, result == 0 ? "loaded " + current[0] : "the bootstrap did not load (" + result + ")");
        } catch (Throwable failure) {
            if (root != null) log(root, "failed: " + failure);
        }
    }

    /** One line per game start: the log holds the last start only. */
    private static void log(Path root, String line) {
        try {
            Files.writeString(root.resolve(LOG), Instant.now() + " " + line + System.lineSeparator(), StandardCharsets.UTF_8);
        } catch (Throwable ignored) { }
    }
}
