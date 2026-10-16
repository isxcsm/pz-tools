package pzext.launch;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.UserPrincipal;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HexFormat;
import java.util.Properties;
import java.util.Set;
import java.util.TreeMap;

/**
 * Put in the game's folder by the install ({@code pzext.install.Install}) as {@code pzext/pzext-launch.jar} and started by
 * {@link BootProvider}, early in the game's main method, inside a handler that ignores anything thrown. It loads PZ Extension
 * API's boot layer from the install folder in-process, through the game's own JRE (docs/loader.md). Nothing here may stop the
 * game from starting: every failure is written to the install folder's log and the game goes on as vanilla.
 *
 * <p>Two things start it. The launcher file lists the jar, so the JDK finds the jar's services list and creates
 * {@link BootProvider} (which survives tools that rewrite the class path and drop {@code .}); or the frozen shim in the
 * game's folder ({@code pzext.loader.BootProvider}, the only loose class) checks the jar's SHA-256 against the loose settings,
 * loads it with a class loader of its own and calls {@link #start()}. The process-wide {@link #GUARD} makes whichever gets
 * here first the only boot. The settings it reads are the ones inside the jar, which the shim has verified or the class path
 * supplies.
 *
 * <p>What it loads from the install folder it trusts only as far as the settings vouch for it: the settings, written by
 * the install into the game's folder (in the jar), give the SHA-256 of every file the install put in the version folder, and the
 * loader checks the folders (owned by the administrators, writable by no one else, see {@link Trust}) and then each
 * file before it loads anything.
 *
 * <p>Uses java.base alone: it runs before the game has set anything up.
 */
public final class Loader {
    /**
     * Inside the jar, beside this class: {@code root}, the install folder, {@code game}, {@code version},
     * the version folder to load, {@code sha256.<file>}, the SHA-256 of each file of the version folder, and {@code trust.<n>},
     * the accounts trusted besides the machine's administrators (none, but in the tests).
     */
    public static final String SETTINGS = Loader.class.getPackageName().replace('.', '/') + "/install.properties";
    public static final String DIGEST = "sha256.";
    public static final String LOG = "loader.log";
    public static final String BOOT = "pzext-boot.jar";
    public static final String API = "pzext-api.jar";
    public static final String NATIVE = "pzext-loader.dll";
    /** The jar with the loader, in the game's folder, and its entry in the launcher file's class path. */
    public static final String JAR = "pzext/pzext-launch.jar";
    /** The system property that marks the process as booted by one copy of the loader. */
    public static final String GUARD = "pzext.loader.started";

    private Loader() { }

    private static native int load(String options);

    private static boolean started;

    public static void start() {
        // Once a run per copy: anything that lists the file system providers again makes another BootProvider.
        synchronized (Loader.class) {
            if (started) return;
            started = true;
        }
        Path root = null, game = null;
        try {
            var settings = new Properties();
            try (InputStream input = Loader.class.getClassLoader().getResourceAsStream(SETTINGS)) {
                if (input == null) return;
                settings.load(input);
            }
            root = Path.of(settings.getProperty("root", ""));
            if (!root.isAbsolute()) return;
            String folder = settings.getProperty("game", "");
            if (!folder.isEmpty()) game = Path.of(folder);
            // One boot a process, whichever copy gets here first.
            if (System.getProperties().putIfAbsent(GUARD, LOG) != null) return;
            boot(root, settings);
        } catch (Throwable failure) {
            if (root != null) log(root, "failed: " + failure, false);
        }
        launcher(root, game);
    }

    /**
     * Loads the version the settings name, when the folders are what the install made (owned by the administrators,
     * writable by no one else) and each file in the version folder has the SHA-256 the settings give. Else one line in the
     * log says which, and the game starts without the API.
     */
    private static void boot(Path root, Properties settings) throws Exception {
        String version = settings.getProperty("version", "");
        if (!version.matches("api-[0-9a-f]{16}")) {
            log(root, "the install's settings name no version", false);
            return;
        }
        var digests = new TreeMap<String, String>();
        for (String key : settings.stringPropertyNames()) {
            if (!key.startsWith(DIGEST)) continue;
            String name = key.substring(DIGEST.length()), digest = settings.getProperty(key, "");
            if (!name.matches("[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?") || name.contains("..") || !digest.matches("[0-9a-f]{64}")) {
                log(root, "the install's settings are not readable", false);
                return;
            }
            digests.put(name, digest);
        }
        for (String name : new String[] { BOOT, API, NATIVE })
            if (!digests.containsKey(name)) {
                log(root, "the install's settings do not vouch for " + name, false);
                return;
            }
        // The folders first: one that another account made or may change is not a place to load code from.
        var extra = new ArrayList<String>();
        for (int index = 0; settings.getProperty("trust." + index) != null; index++) extra.add(settings.getProperty("trust." + index));
        Set<UserPrincipal> trusted = Trust.with(extra.toArray(String[]::new));
        Path home = root.resolve(version);
        for (Path folder : new Path[] { home, root, root.getParent() }) {
            if (folder == null) continue;
            String problem;
            try { problem = Trust.problem(folder, trusted); }
            catch (IOException unreadable) { problem = folder + " cannot be read: " + unreadable.getMessage(); }
            if (problem != null) {
                // A link in the install folder's place could send the log anywhere: it stays unwritten.
                if (!Trust.isLink(root)) log(root, "the install folder is not trusted: " + problem, false);
                return;
            }
        }
        for (var entry : digests.entrySet()) {
            Path file = home.resolve(entry.getKey());
            // A half-written install, or one someone changed, must reach neither the JRE (which prints its errors) nor the game.
            if (!Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) {
                log(root, "missing " + entry.getKey(), false);
                return;
            }
            if (!sha256(Files.readAllBytes(file)).equals(entry.getValue())) {
                log(root, entry.getKey() + " does not match the install", false);
                return;
            }
        }
        Path boot = home.resolve(BOOT), library = home.resolve(NATIVE);
        System.load(library.toString());
        // The boot layer checks the API's jar against the digest when it loads it, not only now.
        String encoded = Base64.getEncoder().encodeToString(home.toString().getBytes(StandardCharsets.UTF_8));
        int result = load(boot + "=" + encoded + "," + digests.get(API));
        log(root, result == 0 ? "loaded " + version : "the boot layer did not load (" + result + ")", false);
    }

    private static String sha256(byte[] bytes) throws NoSuchAlgorithmException {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    /**
     * The launcher file lists the jar again when a reset of the game's files (a Steam verify or update) took the entry
     * out, so the next rewrite of the class path by another tool keeps it. Never a reason to stop the game: a line
     * in the log (after the boot's), once, when it cannot be done.
     */
    private static void launcher(Path root, Path game) {
        try {
            if (game == null || !Files.isRegularFile(game.resolve(JAR), LinkOption.NOFOLLOW_LINKS)) return;
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
            // Never through a link: a link in the log's place would send the line elsewhere.
            OpenOption[] options = after
                ? new OpenOption[] { StandardOpenOption.CREATE, StandardOpenOption.APPEND, LinkOption.NOFOLLOW_LINKS }
                : new OpenOption[] { StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS };
            Files.writeString(root.resolve(LOG), Instant.now() + " " + line + System.lineSeparator(), StandardCharsets.UTF_8, options);
        } catch (Throwable ignored) { }
    }
}
