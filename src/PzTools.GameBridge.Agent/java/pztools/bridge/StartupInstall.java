package pztools.bridge;

import java.io.*;
import java.lang.classfile.*;
import java.lang.constant.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.UserPrincipal;
import java.security.MessageDigest;
import java.util.*;
import pztools.startup.StartupLoader;

/**
 * Installs and removes the startup loader (docs/design/startup-loader.md). Run by the app with the bundled runtime,
 * elevated, while no game runs: {@code status|install|uninstall <game folder> [<bridge folder>]} and
 * {@code refresh <bridge folder>}. Prints one line, {@code PZTOOLS-STARTUP\t<state>\t<detail>}; a failure prints
 * {@code PZTOOLS-STARTUP-FAILED\t<code>\t<message>} and exits 1.
 *
 * <p>The game's jar gets two things: one call at the start of {@code MainScreenState.main}, inside a handler that
 * ignores anything thrown, and the {@link StartupLoader} class with the install folder's path. Everything else the
 * game loads stays in the install folder, which only the player's account and the administrators may change.
 */
public final class StartupInstall {
    static final String MARK = "PZTOOLS-STARTUP", FAILED = "PZTOOLS-STARTUP-FAILED";
    static final String GAME_JAR = "projectzomboid.jar", LAUNCHER = "ProjectZomboid64.exe";
    static final String MAIN_ENTRY = "zombie/gameStates/MainScreenState.class";
    static final String LOADER_ENTRY = "pztools/startup/StartupLoader.class";
    static final String RECORD = "install.tsv", ORIGINAL = "original.jar";
    static final String[] BRIDGE_FILES = { StartupLoader.BOOTSTRAP, StartupLoader.PAYLOAD, StartupLoader.NATIVE };

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
        Path jar = game.resolve(GAME_JAR);
        if (!Files.isRegularFile(jar) || !Files.isRegularFile(game.resolve(LAUNCHER)))
            throw new Refused("game-not-found", "No game in " + game);
        return switch (args[0]) {
            case "status" -> args.length == 2 ? status(root, jar) : usage();
            case "install" -> args.length == 3 ? install(root, jar, Path.of(args[2])) : usage();
            case "uninstall" -> args.length == 2 ? uninstall(root, jar) : usage();
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

    /** installed, not-installed, reverted (an update replaced the patched jar) or foreign (someone else's patch). */
    static String status(Path root, Path jar) throws Exception {
        Map<String, String> record = readRecord(root);
        boolean patched = hasLoader(jar);
        if (record == null) return patched ? "foreign" : "not-installed";
        String digest = sha256(jar);
        if (digest.equals(record.get("patched_sha256"))) return "installed\t" + digest;
        return patched ? "foreign" : "reverted";
    }

    static String install(Path root, Path jar, Path bridge) throws Exception {
        Map<String, String> record = readRecord(root);
        String current = sha256(jar);
        if (record != null && current.equals(record.get("patched_sha256"))) {
            refresh(root, bridge);
            return "installed\t" + current;
        }
        if (hasLoader(jar)) throw new Refused("foreign-install",
            "The game's jar already has a startup loader this install did not put there. Verify the game's files in Steam.");
        byte[] main = readEntry(jar, MAIN_ENTRY);
        if (main == null || hasVersionedEntry(jar, MAIN_ENTRY))
            throw new Refused("unsupported-game", "This game version has no single MainScreenState class");

        privateRoot(root);
        Path copied = copyBridge(root, bridge);
        Path original = root.resolve(ORIGINAL);
        if (!Files.isRegularFile(original) || !sha256(original).equals(current)) replace(jar, original);

        Path staged = Files.createTempFile(jar.getParent(), "projectzomboid", ".pztools.tmp");
        try {
            Files.copy(jar, staged, StandardCopyOption.REPLACE_EXISTING);
            try (FileSystem zip = FileSystems.newFileSystem(staged)) {
                byte[] patched;
                try { patched = patchMain(main, zip); }
                catch (IllegalArgumentException unsupported) { throw new Refused("unsupported-game", unsupported.getMessage()); }
                Files.write(zip.getPath(MAIN_ENTRY), patched);
                Path loader = zip.getPath(LOADER_ENTRY);
                Files.createDirectories(loader.getParent());
                Files.write(loader, loaderClass());
                var settings = new Properties();
                settings.setProperty("root", root.toString());
                try (OutputStream output = Files.newOutputStream(zip.getPath(StartupLoader.SETTINGS))) {
                    settings.store(output, null);
                }
            }
            String patchedDigest = sha256(staged);
            // The record goes first: if the move then fails, the game's jar is still the original, which the
            // record names, so the state reads as not installed rather than as someone else's patch.
            writeRecord(root, jar, current, patchedDigest);
            try { Files.move(staged, jar, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE); }
            catch (FileSystemException inUse) {
                throw new Refused("game-running", "The game's jar is in use. Close the game and any server started from its folder.");
            }
            return "installed\t" + patchedDigest + "\t" + copied.getFileName();
        } finally { Files.deleteIfExists(staged); }
    }

    static String uninstall(Path root, Path jar) throws Exception {
        Map<String, String> record = readRecord(root);
        if (record == null) {
            if (hasLoader(jar)) throw new Refused("foreign-install",
                "The game's jar has a startup loader this install did not put there. Verify the game's files in Steam.");
            return "not-installed";
        }
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
        // Otherwise a game update already replaced the jar: it is the game's own, and only the folder goes.
        deleteTree(root);
        return "uninstalled";
    }

    /** Brings the install folder's bridge up to the app's, so the next game start loads the current bootstrap. */
    static String refresh(Path root, Path bridge) throws Exception {
        if (readRecord(root) == null) return "not-installed";
        Path current = root.resolve(StartupLoader.CURRENT);
        String before = Files.isRegularFile(current) ? Files.readString(current, StandardCharsets.UTF_8).strip() : "";
        Path copied = copyBridge(root, bridge);
        return before.startsWith(copied.getFileName() + "\t") ? "unchanged" : "refreshed\t" + copied.getFileName();
    }

    // ---- the patch ----

    /** One static call to the loader at the start of main(String[]), inside a handler that drops any Throwable. */
    static byte[] patchMain(byte[] bytes, FileSystem jar) {
        var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.defaultResolver()
            .orElse(ClassHierarchyResolver.ofResourceParsing(desc -> {
                try { return Files.newInputStream(jar.getPath(desc.descriptorString()
                    .substring(1, desc.descriptorString().length() - 1) + ".class")); }
                catch (IOException missing) { return null; }
            })).cached()));
        var model = cf.parse(bytes);
        if (model.methods().stream().filter(StartupInstall::isMain).count() != 1)
            throw new IllegalArgumentException("Expected exactly one MainScreenState.main(String[])");
        ClassDesc loader = ClassDesc.of(StartupLoader.class.getName());
        byte[] patched = cf.transformClass(model, ClassTransform.transformingMethodBodies(StartupInstall::isMain,
            CodeTransform.ofStateful(() -> new CodeTransform() {
                @Override public void atStart(CodeBuilder builder) {
                    builder.trying(body -> body.invokestatic(loader, "start", MethodTypeDesc.of(ConstantDescs.CD_void)),
                        handlers -> handlers.catching(ClassDesc.of("java.lang.Throwable"), handler -> handler.pop()));
                }
                @Override public void accept(CodeBuilder builder, CodeElement element) { builder.with(element); }
            })));
        // A class the JVM would reject would stop the game at its first line; the install refuses it instead.
        var errors = cf.verify(patched);
        if (!errors.isEmpty()) throw new IllegalArgumentException("The patched MainScreenState does not verify: " + errors.getFirst());
        return patched;
    }

    private static boolean isMain(MethodModel method) {
        return method.methodName().equalsString("main") && method.methodType().equalsString("([Ljava/lang/String;)V")
            && (method.flags().flagsMask() & ClassFile.ACC_STATIC) != 0;
    }

    private static byte[] loaderClass() throws IOException {
        try (InputStream input = StartupInstall.class.getClassLoader().getResourceAsStream(LOADER_ENTRY)) {
            if (input == null) throw new FileNotFoundException(LOADER_ENTRY);
            return input.readAllBytes();
        }
    }

    // ---- files ----

    private static void privateRoot(Path root) throws Exception {
        UserPrincipal[] owners = AttachMain.principals();
        if (!AttachMain.privateDirectory(root, owners))
            throw new Refused("unsafe-folder", "The install folder " + root + " may be changed by other accounts");
    }

    /** Copies the app's bootstrap, payload and native library to bridge-<digest>, then points {@code current} at it. */
    static Path copyBridge(Path root, Path bridge) throws Exception {
        var digests = new StringBuilder();
        for (String name : BRIDGE_FILES) digests.append(sha256(bridge.resolve(name)));
        String id = "bridge-" + sha256(digests.toString().getBytes(StandardCharsets.US_ASCII)).substring(0, 16);
        Path target = root.resolve(id);
        Files.createDirectories(target);
        UserPrincipal[] owners = AttachMain.principals();
        for (String name : BRIDGE_FILES) {
            Path file = target.resolve(name);
            if (!Files.isRegularFile(file) || !sha256(file).equals(sha256(bridge.resolve(name)))) replace(bridge.resolve(name), file);
            if (!AttachMain.safe(file, owners)) throw new Refused("unsafe-folder", "The copy " + file + " may be changed by other accounts");
        }
        writeAtomically(root.resolve(StartupLoader.CURRENT), id + "\t" + sha256(target.resolve(StartupLoader.BOOTSTRAP)) + "\n");
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

    private static void writeAtomically(Path target, String text) throws IOException {
        Path staged = Files.createTempFile(target.getParent(), "staging", ".tmp");
        try {
            Files.writeString(staged, text, StandardCharsets.UTF_8);
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

    private static void writeRecord(Path root, Path jar, String original, String patched) throws IOException {
        writeAtomically(root.resolve(RECORD), "game_jar\t" + jar + "\noriginal_sha256\t" + original
            + "\npatched_sha256\t" + patched + "\n");
    }

    static boolean hasLoader(Path jar) throws IOException { return readEntry(jar, LOADER_ENTRY) != null; }

    private static byte[] readEntry(Path jar, String name) throws IOException {
        try (var zip = new java.util.zip.ZipFile(jar.toFile())) {
            var entry = zip.getEntry(name);
            if (entry == null) return null;
            try (InputStream input = zip.getInputStream(entry)) { return input.readAllBytes(); }
        }
    }

    private static boolean hasVersionedEntry(Path jar, String name) throws IOException {
        try (var zip = new java.util.zip.ZipFile(jar.toFile())) {
            return zip.stream().anyMatch(entry -> entry.getName().startsWith("META-INF/versions/")
                && entry.getName().endsWith("/" + name));
        }
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
