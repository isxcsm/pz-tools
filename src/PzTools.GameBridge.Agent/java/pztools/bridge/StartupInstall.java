package pztools.bridge;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.UserPrincipal;
import java.security.MessageDigest;
import java.util.*;
import pztools.startup.BootProvider;
import pztools.startup.StartupLoader;

/**
 * Installs and removes the startup loader (docs/design/startup-loader.md). Run by the app with the bundled runtime,
 * elevated, while no game runs: {@code status|install|uninstall <game folder> [<bridge folder>]} and
 * {@code refresh <bridge folder>}. Prints one line, {@code PZTOOLS-STARTUP\t<state>\t<detail>}; a failure prints
 * {@code PZTOOLS-STARTUP-FAILED\t<code>\t<message>} and exits 1.
 *
 * <p>No game file changes. The game's folder is on the game's class path, and gets four files of PZ Tools' own: the
 * {@link StartupLoader} and {@link BootProvider} classes, the install folder's path, and a line naming the provider
 * in the folder's file system provider services list. Everything else the game loads stays in the install folder,
 * which only the player's account and the administrators may change.
 *
 * <p>Earlier versions patched the game's jar instead. Other mods compare the game's classes with the ones they were
 * built for, and took the patched jar for a game update. An install of that kind is turned into this one by the next
 * install or refresh, which put the game's own jar back.
 */
public final class StartupInstall {
    static final String MARK = "PZTOOLS-STARTUP", FAILED = "PZTOOLS-STARTUP-FAILED";
    static final String GAME_JAR = "projectzomboid.jar", LAUNCHER = "ProjectZomboid64.exe";
    static final String SERVICES = "META-INF/services/java.nio.file.spi.FileSystemProvider";
    static final String PROVIDER = BootProvider.class.getName();
    static final String LOADER_ENTRY = "pztools/startup/StartupLoader.class";
    static final String PROVIDER_ENTRY = "pztools/startup/BootProvider.class";
    static final String RECORD = "install.tsv", ORIGINAL = "original.jar";
    static final String[] BRIDGE_FILES = { StartupLoader.BOOTSTRAP, StartupLoader.PAYLOAD, StartupLoader.NATIVE };
    static final String EXTENSIONS = "extensions";

    /** A failure with a code the app turns into a message. */
    static final class Refused extends Exception {
        final String code;
        Refused(String code, String message) { super(message); this.code = code; }
    }

    private StartupInstall() { }

    public static void main(String[] args) {
        try {
            String result = run(args, root());
            System.out.println(MARK + "\t" + result);
        } catch (Refused refused) {
            System.out.println(FAILED + "\t" + refused.code + "\t" + oneLine(refused.getMessage()));
            System.exit(1);
        } catch (Throwable failure) {
            System.out.println(FAILED + "\tio\t" + oneLine(failure.toString()));
            System.exit(1);
        }
    }

    static String run(String[] args, Path root) throws Exception {
        if (args.length == 2 && args[0].equals("refresh")) return refresh(root, Path.of(args[1]));
        if (args.length < 2) throw new Refused("arguments", "Expected a command and the game folder");
        Path game = Path.of(args[1]).toAbsolutePath().normalize();
        if (!Files.isRegularFile(game.resolve(GAME_JAR)) || !Files.isRegularFile(game.resolve(LAUNCHER)))
            throw new Refused("game-not-found", "No game in " + game);
        return switch (args[0]) {
            case "status" -> args.length == 2 ? status(root, game) : usage();
            case "install" -> args.length == 3 ? install(root, game, Path.of(args[2])) : usage();
            case "uninstall" -> args.length == 2 ? uninstall(root, game) : usage();
            default -> usage();
        };
    }

    private static String usage() throws Refused { throw new Refused("arguments", "Unknown command"); }

    /** The install folder of the player the app works for: one per account, under ProgramData. */
    static Path root() throws Exception {
        String data = System.getenv("ProgramData");
        if (data == null || data.isEmpty() || !AttachMain.ascii(data))
            throw new Refused("unsupported-path", "ProgramData is missing or its path is not plain ASCII");
        UserPrincipal player = AttachMain.principals()[0];
        String account = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
            .digest(player.getName().getBytes(StandardCharsets.UTF_8))).substring(0, 12);
        return Path.of(data, "PzTools", "startup", "s-" + account);
    }

    // ---- state ----

    /**
     * installed, not-installed, reverted (installed before, and the game no longer has all of it) or foreign (a patch in
     * the game's jar this install has no record of).
     */
    static String status(Path root, Path game) throws Exception {
        Map<String, String> record = readRecord(root);
        if (record == null) return foreign(game) ? "foreign" : "not-installed";
        // The folder too: the app writes there what the game's resident extensions should run.
        if (record.containsKey("entry_sha256")) return present(game, root) ? "installed\t" + entryDigest(game) + "\t" + root : "reverted";
        // Installed by an earlier version, into the jar: works until the next refresh or install turns it into this.
        Path jar = game.resolve(GAME_JAR);
        return sha256(jar).equals(record.get("patched_sha256")) ? "installed\t" + sha256(jar) + "\t" + root : "reverted";
    }

    static String install(Path root, Path game, Path bridge) throws Exception {
        Map<String, String> record = readRecord(root);
        if (record == null && foreign(game)) throw new Refused("foreign-install",
            "The game already has a startup loader this install did not put there. Verify the game's files in Steam.");
        privateRoot(root);
        Path copied = copyBridge(root, bridge);
        boolean already = record != null && record.containsKey("entry_sha256") && current(game, root);
        restoreJar(root, game, record);
        writeEntry(root, game);
        return "installed\t" + entryDigest(game) + (already ? "" : "\t" + copied.getFileName());
    }

    static String uninstall(Path root, Path game) throws Exception {
        Map<String, String> record = readRecord(root);
        if (record == null) {
            if (foreign(game)) throw new Refused("foreign-install",
                "The game has a startup loader this install did not put there. Verify the game's files in Steam.");
            removeEntry(game);
            return "not-installed";
        }
        restoreJar(root, game, record);
        removeEntry(game);
        deleteTree(root);
        return "uninstalled";
    }

    /**
     * Brings the install folder's bridge up to the app's, so the next game start loads the current bootstrap, and the
     * game folder's entry up to this version's. An install of an earlier version (in the jar) becomes one of this kind.
     */
    static String refresh(Path root, Path bridge) throws Exception {
        Map<String, String> record = readRecord(root);
        if (record == null) return "not-installed";
        Path current = root.resolve(StartupLoader.CURRENT);
        String before = Files.isRegularFile(current) ? Files.readString(current, StandardCharsets.UTF_8).strip() : "";
        Path copied = copyBridge(root, bridge);
        String game = record.get("game");
        if (game == null && record.get("game_jar") != null) game = Path.of(record.get("game_jar")).getParent().toString();
        boolean entryChanged = false;
        if (game != null && Files.isRegularFile(Path.of(game, GAME_JAR))) {
            Path folder = Path.of(game);
            // A game that runs keeps its jar open: the move waits for a refresh while it is closed.
            try { restoreJar(root, folder, record); } catch (Refused running) { return "refreshed\t" + copied.getFileName(); }
            if (!record.containsKey("entry_sha256") || !current(folder, root)) {
                writeEntry(root, folder);
                entryChanged = true;
            }
        }
        return !entryChanged && before.startsWith(copied.getFileName() + "\t") ? "unchanged" : "refreshed\t" + copied.getFileName();
    }

    // ---- the entry in the game's folder ----

    /** The loader's files, then the service line: a line naming a class that is not there would break the JDK's list. */
    private static void writeEntry(Path root, Path game) throws Exception {
        writeAtomically(game.resolve(LOADER_ENTRY), ownClass(LOADER_ENTRY));
        writeAtomically(game.resolve(PROVIDER_ENTRY), ownClass(PROVIDER_ENTRY));
        writeAtomically(game.resolve(StartupLoader.SETTINGS), settings(root));
        var lines = serviceLines(game);
        if (!lines.contains(PROVIDER)) {
            lines.add(PROVIDER);
            writeAtomically(game.resolve(SERVICES), (String.join("\n", lines) + "\n").getBytes(StandardCharsets.UTF_8));
        }
        writeRecord(root, game);
    }

    /** The service line first, then the files; other tools' service lines stay. */
    private static void removeEntry(Path game) throws IOException {
        var lines = serviceLines(game);
        if (lines.remove(PROVIDER)) {
            if (lines.stream().allMatch(line -> line.isBlank() || line.startsWith("#"))) Files.deleteIfExists(game.resolve(SERVICES));
            else writeAtomically(game.resolve(SERVICES), (String.join("\n", lines) + "\n").getBytes(StandardCharsets.UTF_8));
        }
        for (String name : new String[] { LOADER_ENTRY, PROVIDER_ENTRY, StartupLoader.SETTINGS }) Files.deleteIfExists(game.resolve(name));
        for (String folder : new String[] { "pztools/startup", "pztools", "META-INF/services", "META-INF" }) deleteIfEmpty(game.resolve(folder));
    }

    /** The entry is all there and names this install folder; it may be an earlier version's, which still loads. */
    private static boolean present(Path game, Path root) throws Exception {
        if (!serviceLines(game).contains(PROVIDER)) return false;
        for (String name : new String[] { LOADER_ENTRY, PROVIDER_ENTRY, StartupLoader.SETTINGS })
            if (!Files.isRegularFile(game.resolve(name), LinkOption.NOFOLLOW_LINKS)) return false;
        return Arrays.equals(Files.readAllBytes(game.resolve(StartupLoader.SETTINGS)), settings(root));
    }

    /** Present, and this version's: what install and refresh leave. */
    private static boolean current(Path game, Path root) throws Exception {
        if (!present(game, root)) return false;
        for (String name : new String[] { LOADER_ENTRY, PROVIDER_ENTRY })
            if (!Arrays.equals(Files.readAllBytes(game.resolve(name)), ownClass(name))) return false;
        return true;
    }

    /**
     * A patch in the game's jar with no record: an earlier version's whose record is gone, or another tool's; either way
     * not this install's to change. An entry in the game's folder with no record (the install folder was deleted) is
     * this install's own files: install takes them over and uninstall removes them.
     */
    private static boolean foreign(Path game) throws IOException {
        return hasLoader(game.resolve(GAME_JAR));
    }

    private static List<String> serviceLines(Path game) throws IOException {
        Path file = game.resolve(SERVICES);
        if (!Files.isRegularFile(file)) return new ArrayList<>();
        var lines = new ArrayList<String>();
        for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) lines.add(line.strip());
        while (!lines.isEmpty() && lines.getLast().isEmpty()) lines.removeLast();
        return lines;
    }

    /**
     * {@code root} for the loader's Properties.load, written by hand without Properties.store's date line: the same
     * install gives the same bytes, which status compares. The path is plain ASCII (see root()).
     */
    private static byte[] settings(Path root) {
        return ("root=" + root.toString().replace("\\", "\\\\").replace(":", "\\:") + "\n").getBytes(StandardCharsets.ISO_8859_1);
    }

    private static String entryDigest(Path game) throws Exception {
        var digest = MessageDigest.getInstance("SHA-256");
        for (String name : new String[] { LOADER_ENTRY, PROVIDER_ENTRY, StartupLoader.SETTINGS })
            digest.update(Files.readAllBytes(game.resolve(name)));
        return HexFormat.of().formatHex(digest.digest());
    }

    private static byte[] ownClass(String name) throws IOException {
        try (InputStream input = StartupInstall.class.getClassLoader().getResourceAsStream(name)) {
            if (input == null) throw new FileNotFoundException(name);
            return input.readAllBytes();
        }
    }

    /**
     * An earlier version's install patched the jar: the game's own goes back from the copy it kept, and with it the
     * copy. A jar a game update has since replaced is the game's own already.
     */
    private static void restoreJar(Path root, Path game, Map<String, String> record) throws Exception {
        if (record == null || record.get("patched_sha256") == null) return;
        Path jar = game.resolve(GAME_JAR);
        if (sha256(jar).equals(record.get("patched_sha256"))) {
            Path original = root.resolve(ORIGINAL);
            if (!Files.isRegularFile(original) || !sha256(original).equals(record.get("original_sha256")))
                throw new Refused("original-missing",
                    "The saved copy of the game's jar is missing. Verify the game's files in Steam to restore it.");
            Path staged = Files.createTempFile(jar.getParent(), "projectzomboid", ".pztools.tmp");
            try {
                Files.copy(original, staged, StandardCopyOption.REPLACE_EXISTING);
                try { Files.move(staged, jar, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); }
                catch (FileSystemException inUse) {
                    throw new Refused("game-running", "The game's jar is in use. Close the game and any server started from its folder.");
                }
            } finally { Files.deleteIfExists(staged); }
        }
        Files.deleteIfExists(root.resolve(ORIGINAL));
        writeRecord(root, game);
    }

    // ---- files ----

    private static void privateRoot(Path root) throws Exception {
        UserPrincipal[] owners = AttachMain.principals();
        if (!AttachMain.privateDirectory(root, owners))
            throw new Refused("unsafe-folder", "The install folder " + root + " may be changed by other accounts");
    }

    /**
     * Copies the app's bootstrap, payload, native library and extensions (the files of its {@code extensions} folder) to
     * bridge-<digest>, then points {@code current} at it. The extensions are what the game runs without the app.
     */
    static Path copyBridge(Path root, Path bridge) throws Exception {
        var files = new ArrayList<String>(List.of(BRIDGE_FILES));
        Path extensions = bridge.resolve(EXTENSIONS);
        if (Files.isDirectory(extensions)) try (var entries = Files.list(extensions)) {
            for (Path file : entries.sorted().toList()) {
                String name = file.getFileName().toString();
                if (Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) && name.matches("[A-Za-z0-9._-]+")) files.add(EXTENSIONS + "/" + name);
            }
        }
        var digests = new StringBuilder();
        for (String name : files) digests.append(name).append('\t').append(sha256(bridge.resolve(name))).append('\n');
        String id = "bridge-" + sha256(digests.toString().getBytes(StandardCharsets.US_ASCII)).substring(0, 16);
        Path target = root.resolve(id);
        Files.createDirectories(target.resolve(EXTENSIONS));
        UserPrincipal[] owners = AttachMain.principals();
        for (String name : files) {
            Path file = target.resolve(name);
            if (!Files.isRegularFile(file) || !sha256(file).equals(sha256(bridge.resolve(name)))) replace(bridge.resolve(name), file);
            if (!AttachMain.safe(file, owners)) throw new Refused("unsafe-folder", "The copy " + file + " may be changed by other accounts");
        }
        writeAtomically(root.resolve(StartupLoader.CURRENT),
            (id + "\t" + sha256(target.resolve(StartupLoader.BOOTSTRAP)) + "\n").getBytes(StandardCharsets.UTF_8));
        // Folders of earlier versions; one a running game still has open stays until a later refresh.
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root, "bridge-*")) {
            for (Path old : entries) if (!old.equals(target)) try { deleteTree(old); } catch (IOException inUse) { }
        }
        return target;
    }

    private static void replace(Path source, Path target) throws IOException {
        Path staged = Files.createTempFile(target.getParent(), "staging", ".tmp");
        try {
            Files.copy(source, staged, StandardCopyOption.REPLACE_EXISTING);
            Files.move(staged, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } finally { Files.deleteIfExists(staged); }
    }

    private static void writeAtomically(Path target, byte[] bytes) throws IOException {
        Files.createDirectories(target.getParent());
        Path staged = Files.createTempFile(target.getParent(), "staging", ".tmp");
        try {
            Files.write(staged, bytes);
            Files.move(staged, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } finally { Files.deleteIfExists(staged); }
    }

    private static Map<String, String> readRecord(Path root) throws IOException {
        Path file = root.resolve(RECORD);
        if (!Files.isRegularFile(file)) return null;
        var record = new HashMap<String, String>();
        for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
            int tab = line.indexOf('\t');
            if (tab > 0) record.put(line.substring(0, tab), line.substring(tab + 1));
        }
        return record;
    }

    /** The game folder, and the entry's digest once it is there; an earlier version's jar patch while it still is. */
    private static void writeRecord(Path root, Path game) throws Exception {
        Map<String, String> old = readRecord(root);
        var text = new StringBuilder("game\t" + game + "\n");
        if (Files.isRegularFile(game.resolve(PROVIDER_ENTRY))) text.append("entry_sha256\t").append(entryDigest(game)).append('\n');
        if (old != null && old.get("patched_sha256") != null && sha256(game.resolve(GAME_JAR)).equals(old.get("patched_sha256")))
            text.append("original_sha256\t").append(old.get("original_sha256")).append("\npatched_sha256\t").append(old.get("patched_sha256")).append('\n');
        writeAtomically(root.resolve(RECORD), text.toString().getBytes(StandardCharsets.UTF_8));
    }

    /** An earlier version's patch: the loader class in the game's jar. */
    static boolean hasLoader(Path jar) throws IOException {
        try (var zip = new java.util.zip.ZipFile(jar.toFile())) { return zip.getEntry(LOADER_ENTRY) != null; }
    }

    private static void deleteIfEmpty(Path folder) throws IOException {
        if (!Files.isDirectory(folder, LinkOption.NOFOLLOW_LINKS)) return;
        try (var entries = Files.list(folder)) { if (entries.findAny().isPresent()) return; }
        Files.delete(folder);
    }

    static void deleteTree(Path root) throws IOException {
        if (!Files.exists(root, LinkOption.NOFOLLOW_LINKS)) return;
        try (var walk = Files.walk(root)) {
            for (Path path : walk.sorted(Comparator.reverseOrder()).toList()) Files.delete(path);
        }
    }

    static String sha256(Path file) throws Exception {
        var digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = Files.newInputStream(file)) {
            byte[] buffer = new byte[1 << 16];
            for (int read; (read = input.read(buffer)) > 0; ) digest.update(buffer, 0, read);
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private static String sha256(byte[] bytes) throws Exception {
        return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    }

    private static String oneLine(String text) { return String.valueOf(text).replace('\r', ' ').replace('\n', ' ').replace('\t', ' '); }
}
