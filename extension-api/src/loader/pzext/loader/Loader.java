package pzext.loader;

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
 * Put in the game's folder by the install ({@code pzext.install.Install}) and started by {@link BootProvider}, early in
 * the game's main method, inside a handler that ignores anything thrown. It loads PZ Extension API's boot layer from the
 * install folder in-process, through the game's own JRE (docs/loader.md). Nothing here may stop the game from starting:
 * every failure is written to the install folder's log and the game goes on as vanilla.
 *
 * <p>Uses java.base alone: it runs before the game has set anything up.
 */
public final class Loader {
    /** In the game's folder beside this class: {@code root}, the install folder. */
    public static final String SETTINGS = "pzext/loader/install.properties";
    /** In the install folder: the version folder to load, a tab, and the SHA-256 of its boot jar. */
    public static final String CURRENT = "current";
    public static final String LOG = "loader.log";
    public static final String BOOT = "pzext-boot.jar";
    public static final String API = "pzext-api.jar";
    public static final String NATIVE = "pzext-loader.dll";

    private Loader() { }

    private static native int load(String options);

    private static boolean started;

    public static void start() {
        // Once a run: anything that lists the file system providers again makes another BootProvider.
        synchronized (Loader.class) {
            if (started) return;
            started = true;
        }
        Path root = null;
        try {
            var settings = new Properties();
            try (InputStream input = Loader.class.getClassLoader().getResourceAsStream(SETTINGS)) {
                if (input == null) return;
                settings.load(input);
            }
            root = Path.of(settings.getProperty("root", ""));
            if (!root.isAbsolute()) return;
            Path currentFile = root.resolve(CURRENT);
            String[] current = Files.isRegularFile(currentFile, LinkOption.NOFOLLOW_LINKS)
                ? Files.readString(currentFile, StandardCharsets.UTF_8).strip().split("\t", -1) : new String[0];
            if (current.length != 2 || !current[0].matches("api-[0-9a-f]{16}") || !current[1].matches("[0-9a-f]{64}")) {
                log(root, "the install's current file is not readable");
                return;
            }
            Path version = root.resolve(current[0]);
            Path boot = version.resolve(BOOT), api = version.resolve(API), library = version.resolve(NATIVE);
            for (Path file : new Path[] { boot, api, library })
                if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) {
                    log(root, "missing " + file.getFileName());
                    return;
                }
            // A half-written install must not reach the JRE, which prints its errors.
            String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(boot)));
            if (!digest.equals(current[1])) {
                log(root, "the boot jar does not match the install");
                return;
            }
            System.load(library.toString());
            String encoded = Base64.getEncoder().encodeToString(version.toString().getBytes(StandardCharsets.UTF_8));
            int result = load(boot + "=" + encoded);
            log(root, result == 0 ? "loaded " + current[0] : "the boot layer did not load (" + result + ")");
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
