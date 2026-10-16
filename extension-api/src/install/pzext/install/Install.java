package pzext.install;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.UserPrincipal;
import java.security.MessageDigest;
import java.time.LocalDateTime;
import java.util.*;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import pzext.loader.Launcher;
import pzext.loader.Loader;

/**
 * Installs and removes PZ Extension API (docs/loader.md). Run with a Java 25 runtime (the game's own {@code jre64} will
 * do), while no game runs, with rights to write the game's folder:
 * {@code java -jar pzext-install.jar status|install|uninstall <game folder>}. The files installed are the ones beside
 * this jar (a release's folder). Prints one line, {@code PZEXT-INSTALL\t<state>\t<detail>}; a failure prints
 * {@code PZEXT-INSTALL-FAILED\t<code>\t<message>} and exits 1.
 *
 * <p>No game file is changed but the launcher file, by one entry (below). The game's folder is on the game's class path, and gets files of the API's own: the loader's
 * classes, the install folder's path, and a line naming the provider in the folder's file system provider services list,
 * beside any lines of other tools. The launcher's class path may no longer list that folder (pzopt's AOT step drops it
 * and copies the loose classes, without the services list, into a jar of its own), so the game's folder gets the same
 * loader a second time as a jar of its own, {@code pzext/pzext-launch.jar}, under another package name, and the launcher
 * file ({@code ProjectZomboid64.json}) lists the jar after the game's. Only that one entry of the file is added or
 * removed, as text. Everything else the game loads stays in the install folder
 * ({@code %ProgramData%\PZExtAPI\s-<account>}), which only the player's account and the administrators may change. Each
 * version goes into its own folder, {@code api-<digest>}, and {@code current} names the one the next game start loads.
 */
public final class Install {
    static final String MARK = "PZEXT-INSTALL", FAILED = "PZEXT-INSTALL-FAILED";
    static final String GAME_JAR = "projectzomboid.jar", LAUNCHER = "ProjectZomboid64.exe";
    static final String SERVICES = "META-INF/services/java.nio.file.spi.FileSystemProvider";
    static final String PROVIDER = "pzext.loader.BootProvider", LAUNCH_PROVIDER = "pzext.launch.BootProvider";
    static final String LOADER_ENTRY = "pzext/loader/Loader.class", PROVIDER_ENTRY = "pzext/loader/BootProvider.class";
    static final String LAUNCHER_ENTRY = "pzext/loader/Launcher.class";
    static final String SETTINGS = "pzext/loader/install.properties";
    /** The loader's classes and settings in the jar, under the other package name. */
    static final String[] LAUNCH_CLASSES = { "pzext/launch/Loader.class", "pzext/launch/BootProvider.class", "pzext/launch/Launcher.class" };
    static final String LAUNCH_SETTINGS = "pzext/launch/install.properties";
    static final String LAUNCH_JAR = Loader.JAR;
    static final String CURRENT = "current", RECORD = "install.tsv";
    static final String BOOT = "pzext-boot.jar";
    static final String[] FILES = { BOOT, "pzext-api.jar", "pzext-loader.dll" };
    static final String FONTS = "fonts";

    /** A failure with a code a caller turns into a message. */
    static final class Refused extends Exception {
        final String code;
        Refused(String code, String message) { super(message); this.code = code; }
    }

    private Install() { }

    public static void main(String[] args) {
        try {
            System.out.println(MARK + "\t" + run(args, root(), release()));
        } catch (Refused refused) {
            System.out.println(FAILED + "\t" + refused.code + "\t" + oneLine(refused.getMessage()));
            System.exit(1);
        } catch (Throwable failure) {
            System.out.println(FAILED + "\tio\t" + oneLine(failure.toString()));
            System.exit(1);
        }
    }

    static String run(String[] args, Path root, Path release) throws Exception {
        if (args.length != 2) throw new Refused("arguments", "Expected status, install or uninstall and the game folder");
        Path game = Path.of(args[1]).toAbsolutePath().normalize();
        if (!Files.isRegularFile(game.resolve(GAME_JAR)) || !Files.isRegularFile(game.resolve(LAUNCHER)))
            throw new Refused("game-not-found", "No game in " + game);
        return switch (args[0]) {
            case "status" -> status(root, game);
            case "install" -> install(root, game, release);
            case "uninstall" -> uninstall(root, game);
            default -> throw new Refused("arguments", "Unknown command " + args[0]);
        };
    }

    /** The install folder of the player: one per account, under ProgramData. */
    static Path root() throws Exception {
        String data = System.getenv("ProgramData");
        if (data == null || data.isEmpty() || !Folders.ascii(data))
            throw new Refused("unsupported-path", "ProgramData is missing or its path is not plain ASCII");
        UserPrincipal player = Folders.principals()[0];
        String account = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
            .digest(player.getName().getBytes(StandardCharsets.UTF_8))).substring(0, 12);
        return Path.of(data, "PZExtAPI", "s-" + account);
    }

    /** The folder of this jar: a release's files. */
    static Path release() throws Exception {
        return Path.of(Install.class.getProtectionDomain().getCodeSource().getLocation().toURI()).getParent();
    }

    // ---- state ----

    /**
     * installed (with the version folder the next start loads, the install folder and what the launcher file says of the
     * jar's entry: listed, absent, none or unreadable), not-installed, or reverted (the game lost part of it).
     */
    static String status(Path root, Path game) throws Exception {
        if (!Files.isRegularFile(root.resolve(RECORD))) return present(game, root) ? "reverted" : "not-installed";
        if (!present(game, root)) return "reverted";
        Path current = root.resolve(CURRENT);
        String version = Files.isRegularFile(current) ? Files.readString(current, StandardCharsets.UTF_8).strip().split("\t")[0] : "";
        return "installed\t" + version + "\t" + root + "\tlauncher=" + Launcher.state(game.resolve(Launcher.FILE), LAUNCH_JAR);
    }

    /** Copies the release into a version folder, points current at it and writes the entry; again, an update. */
    static String install(Path root, Path game, Path release) throws Exception {
        UserPrincipal[] owners = Folders.principals();
        if (!Folders.privateDirectory(root, owners))
            throw new Refused("unsafe-folder", "The install folder " + root + " may be changed by other accounts");
        Path copied = copyRelease(root, release, owners);
        writeEntry(root, game);
        return "installed\t" + copied.getFileName() + "\t" + root + "\tlauncher=" + Launcher.state(game.resolve(Launcher.FILE), LAUNCH_JAR);
    }

    static String uninstall(Path root, Path game) throws Exception {
        removeEntry(game);
        try { deleteTree(root); }
        catch (IOException inUse) { throw new Refused("game-running", "The install folder is in use. Close the game first."); }
        return "uninstalled";
    }

    // ---- the entry in the game's folder ----

    /**
     * The jar and the loader's files, then the service line, then the launcher file's entry: a line or an entry naming
     * a class or a jar that is not there would break the JDK's list or the class path.
     */
    private static void writeEntry(Path root, Path game) throws Exception {
        byte[] jar = launchJar(root, game);
        Path jarFile = game.resolve(LAUNCH_JAR);
        // A running game has the jar open: the same bytes stay.
        if (!Files.isRegularFile(jarFile) || !Arrays.equals(Files.readAllBytes(jarFile), jar)) writeAtomically(jarFile, jar);
        writeAtomically(game.resolve(LOADER_ENTRY), ownResource(LOADER_ENTRY));
        writeAtomically(game.resolve(PROVIDER_ENTRY), ownResource(PROVIDER_ENTRY));
        writeAtomically(game.resolve(LAUNCHER_ENTRY), ownResource(LAUNCHER_ENTRY));
        writeAtomically(game.resolve(SETTINGS), settings(root, game));
        var lines = serviceLines(game);
        if (!lines.contains(PROVIDER)) {
            lines.add(PROVIDER);
            writeAtomically(game.resolve(SERVICES), (String.join("\n", lines) + "\n").getBytes(StandardCharsets.UTF_8));
        }
        // No launcher file, or none this can edit: the loose files serve, and status says so.
        Launcher.ensure(game.resolve(Launcher.FILE), LAUNCH_JAR);
        writeAtomically(root.resolve(RECORD), ("game\t" + game + "\n").getBytes(StandardCharsets.UTF_8));
    }

    /**
     * The jar first (a game that runs has it open, which refuses the uninstall before anything else changes), the
     * launcher file's entry, the service line, then the loose files; other tools' lines and entries stay.
     */
    private static void removeEntry(Path game) throws Exception {
        try { Files.deleteIfExists(game.resolve(LAUNCH_JAR)); }
        catch (IOException inUse) { throw new Refused("game-running", "The loader's jar is in use. Close the game first."); }
        Launcher.drop(game.resolve(Launcher.FILE), LAUNCH_JAR);
        var lines = serviceLines(game);
        if (lines.remove(PROVIDER)) {
            if (lines.stream().allMatch(line -> line.isBlank() || line.startsWith("#"))) Files.deleteIfExists(game.resolve(SERVICES));
            else writeAtomically(game.resolve(SERVICES), (String.join("\n", lines) + "\n").getBytes(StandardCharsets.UTF_8));
        }
        for (String name : new String[] { LOADER_ENTRY, PROVIDER_ENTRY, LAUNCHER_ENTRY, SETTINGS }) Files.deleteIfExists(game.resolve(name));
        for (String folder : new String[] { "pzext/loader", "pzext", "META-INF/services", "META-INF" }) deleteIfEmpty(game.resolve(folder));
    }

    /** The entry is all there and names this install folder (the launcher file's entry heals itself and is not part of it). */
    private static boolean present(Path game, Path root) throws Exception {
        if (!serviceLines(game).contains(PROVIDER)) return false;
        for (String name : new String[] { LOADER_ENTRY, PROVIDER_ENTRY, LAUNCHER_ENTRY, SETTINGS, LAUNCH_JAR })
            if (!Files.isRegularFile(game.resolve(name), LinkOption.NOFOLLOW_LINKS)) return false;
        return Arrays.equals(Files.readAllBytes(game.resolve(SETTINGS)), settings(root, game))
            && Arrays.equals(Files.readAllBytes(game.resolve(LAUNCH_JAR)), launchJar(root, game));
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
     * The loader's other copy as a jar: the service list naming it, its classes under {@code pzext.launch}, its
     * settings. The same bytes for the same inputs (fixed times), so an install of the same build leaves the jar be.
     */
    static byte[] launchJar(Path root, Path game) throws IOException {
        var bytes = new ByteArrayOutputStream();
        try (var jar = new ZipOutputStream(bytes)) {
            add(jar, "META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            add(jar, SERVICES, (LAUNCH_PROVIDER + "\n").getBytes(StandardCharsets.UTF_8));
            for (String name : LAUNCH_CLASSES) add(jar, name, ownResource(name));
            add(jar, LAUNCH_SETTINGS, settings(root, game));
        }
        return bytes.toByteArray();
    }

    private static void add(ZipOutputStream jar, String name, byte[] content) throws IOException {
        var entry = new ZipEntry(name);
        entry.setTimeLocal(LocalDateTime.of(2020, 1, 1, 0, 0));
        jar.putNextEntry(entry);
        jar.write(content);
        jar.closeEntry();
    }

    /** {@code root} and {@code game} for the loader's Properties.load, without Properties.store's date line. */
    private static byte[] settings(Path root, Path game) {
        return ("root=" + escaped(root.toString()) + "\ngame=" + escaped(game.toString()) + "\n").getBytes(StandardCharsets.ISO_8859_1);
    }

    /** A property value as Properties.load reads it back: the separators escaped, what is not plain ASCII as unicode escapes. */
    private static String escaped(String value) {
        var out = new StringBuilder();
        for (int index = 0; index < value.length(); index++) {
            char c = value.charAt(index);
            if (c == '\\' || c == ':' || c == '=' || c == '#' || c == '!') out.append('\\').append(c);
            else if (c == ' ') out.append(index == 0 ? "\\ " : " ");
            else if (c < 0x20 || c > 0x7E) out.append(String.format("\\u%04x", (int) c));
            else out.append(c);
        }
        return out.toString();
    }

    private static byte[] ownResource(String name) throws IOException {
        try (InputStream input = Install.class.getClassLoader().getResourceAsStream(name)) {
            if (input == null) throw new FileNotFoundException(name);
            return input.readAllBytes();
        }
    }

    // ---- files ----

    /** The release's files (and its fonts) into api-<digest>; current then names it, and older folders go. */
    static Path copyRelease(Path root, Path release, UserPrincipal[] owners) throws Exception {
        var files = new ArrayList<String>(List.of(FILES));
        Path fonts = release.resolve(FONTS);
        if (Files.isDirectory(fonts)) try (var entries = Files.list(fonts)) {
            for (Path file : entries.sorted().toList()) {
                String name = file.getFileName().toString();
                if (Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) && name.matches("[A-Za-z0-9._-]+")) files.add(FONTS + "/" + name);
            }
        }
        for (String name : files)
            if (!Files.isRegularFile(release.resolve(name), LinkOption.NOFOLLOW_LINKS))
                throw new Refused("release-incomplete", "The release has no " + name + " in " + release);
        var digests = new StringBuilder();
        for (String name : files) digests.append(name).append('\t').append(sha256(release.resolve(name))).append('\n');
        String id = "api-" + sha256(digests.toString().getBytes(StandardCharsets.US_ASCII)).substring(0, 16);
        Path target = root.resolve(id);
        Files.createDirectories(target.resolve(FONTS));
        for (String name : files) {
            Path file = target.resolve(name);
            if (!Files.isRegularFile(file) || !sha256(file).equals(sha256(release.resolve(name)))) replace(release.resolve(name), file);
            if (!Folders.safe(file, owners)) throw new Refused("unsafe-folder", "The copy " + file + " may be changed by other accounts");
        }
        writeAtomically(root.resolve(CURRENT), (id + "\t" + sha256(target.resolve(BOOT)) + "\n").getBytes(StandardCharsets.UTF_8));
        // Folders of earlier versions; one a running game still has open stays until a later install.
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root, "api-*")) {
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
