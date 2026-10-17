package pzext.boot;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.Map;
import java.util.jar.JarInputStream;
import java.util.jar.Manifest;

/**
 * Runs the API from its own jar ({@link Boot#API_JAR} in the version folder), from the moment the game has loaded
 * {@code GameWindow}: the jar is read whole (the bytes hashed are the bytes loaded, and they must be the ones the
 * install vouched for: {@link Boot#apiDigest()}), its classes defined by a loader of their own, and its
 * {@code pzext.api.GameApi.start()} called, which hands the hooks their handlers. With the developer switch on
 * ({@link #DEV_RELOAD}) the jar is looked at again about once a second: a changed one (a build copied over it in a running
 * game, or the build itself where the switch names it) loads without a digest check and starts a new API, which takes
 * the game's Lua environment over from the one before. Without it the jar is loaded once and never looked at again: a
 * release's jar is the one the install put there.
 * Each pass writes which hooks the game has ({@code api.tsv}, in the install folder) for whoever installed the API. Each
 * frame runs the API's per-frame work.
 */
final class Host {
    private static final String NAMESPACE = "pzext.api", ENTRY = "pzext.api.GameApi", CONTRACT = "PZExt-Boot-Api";
    /**
     * The environment variable of the game's process that turns the API's hot reload on, for a developer building the API:
     * set to {@code 1}, a newer jar in the version folder replaces the running API without the install's digest; set to
     * the full path of a jar ({@code ...\out\release\pzext-api.jar}), the API is that jar's from the start, and each
     * build of it replaces the running one (no copy into the install, whose folder takes administrator rights). Off in
     * every other game; the loader still refuses a jar that does not match the install at the next start.
     */
    static final String DEV_RELOAD = "PZEXT_DEV_RELOAD";
    private static final Path DEV_JAR = devJar(System.getenv(DEV_RELOAD));
    private static final boolean DEV = "1".equals(System.getenv(DEV_RELOAD)) || DEV_JAR != null;
    // A jar younger than this may still be being written (a build writes it in place): read on a later pass.
    private static final long SETTLE_MILLIS = 1000;
    private static final long WAKE_MILLIS = 250, STATUS_NANOS = 1_000_000_000L;
    private static final int MAX_JAR = 16 * 1024 * 1024, MAX_CLASS = 2 * 1024 * 1024, MAX_CLASSES = 2048;

    /** What the boot layer calls of an API. */
    record Api(MethodHandle frame, MethodHandle status) { }

    private static volatile ClassLoader game;
    private static volatile Api api;
    // On the host's thread only.
    private static long seenSize, seenTime;
    private static String seenDigest;
    private static String reported;
    // Set when the jar did not match the install: nothing is read again.
    private static boolean refused;
    private static volatile String frameFailure;

    private Host() { }

    /** From the frame hook's transformer, as the game loads GameWindow: nothing is loaded here, a thread does it. */
    static void gameWindowLoaded(ClassLoader loader) {
        game = loader;
        var thread = new Thread(Host::run, "PZExt-api");
        thread.setDaemon(true);
        thread.start();
    }

    /** Each frame, on the game's thread. Whatever the API throws stays here; the game goes on. */
    static void frame() {
        Api current = api;
        ClassLoader loader = game;
        if (current == null || loader == null) return;
        try { current.frame().invokeExact(loader); }
        catch (Throwable failure) {
            String text = String.valueOf(failure);
            if (!text.equals(frameFailure)) System.err.println("[PZExt] frame: " + text);
            frameFailure = text;
        }
    }

    private static void run() {
        long nextStatus = System.nanoTime();
        while (true) {
            try {
                if (System.nanoTime() - nextStatus >= 0) {
                    nextStatus = System.nanoTime() + STATUS_NANOS;
                    Path home = Boot.home();
                    load(DEV_JAR != null ? DEV_JAR : home.resolve(Boot.API_JAR));
                    Api current = api;
                    if (current != null) current.status().invokeExact(home.getParent());
                }
            } catch (Throwable failure) {
                String text = String.valueOf(failure);
                if (!text.equals(reported)) System.err.println("[PZExt] " + text);
                reported = text;
            }
            try { Thread.sleep(WAKE_MILLIS); }
            catch (InterruptedException stopped) { return; }
        }
    }

    /** The API of this jar: the one running while the jar is unchanged, else a new one, started. */
    private static void load(Path jar) throws Throwable {
        if (!wanted(api != null, refused, DEV)) return;
        var file = Files.readAttributes(jar, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        long time = file.lastModifiedTime().toMillis();
        if (api != null && file.size() == seenSize && time == seenTime) return;
        if (DEV && System.currentTimeMillis() - time < SETTLE_MILLIS) return;
        byte[] bytes;
        try (var input = Files.newInputStream(jar, LinkOption.NOFOLLOW_LINKS)) { bytes = input.readNBytes(MAX_JAR + 1); }
        if (bytes.length > MAX_JAR) throw new IOException("The API's jar is too large");
        String digest = sha256(bytes);
        try { verify(digest, Boot.apiDigest(), DEV); }
        catch (IOException mismatch) { refused = true; throw mismatch; }
        seenSize = file.size();
        seenTime = time;
        if (api != null && digest.equals(seenDigest)) return;
        Map<String, byte[]> classes = classes(bytes);
        var loader = new ClassLoader("pzext-api", Host.class.getClassLoader()) {
            @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                if (!name.startsWith(NAMESPACE + ".")) return super.loadClass(name, resolve);
                synchronized (getClassLoadingLock(name)) {
                    Class<?> type = findLoadedClass(name);
                    if (type == null) {
                        byte[] code = classes.get(name);
                        if (code == null) throw new ClassNotFoundException(name);
                        type = defineClass(name, code, 0, code.length);
                    }
                    if (resolve) resolveClass(type);
                    return type;
                }
            }
        };
        Class<?> type = loader.loadClass(ENTRY);
        var lookup = MethodHandles.publicLookup();
        var next = new Api(lookup.findStatic(type, "frame", MethodType.methodType(void.class, ClassLoader.class)),
            lookup.findStatic(type, "writeStatus", MethodType.methodType(void.class, Path.class)));
        type.getMethod("start").invoke(null);
        seenDigest = digest;
        api = next;
        // the developer's reload says which jar runs now (pzdev.py api waits for it); a release's load says nothing
        if (DEV) System.err.println("[PZExt] API loaded " + digest.substring(0, 12) + " (developer reload)");
    }

    /** The developer's jar the switch names: an absolute path ending in .jar, else none (a {@code 1}, or nothing). */
    static Path devJar(String setting) {
        if (setting == null || !setting.toLowerCase(java.util.Locale.ROOT).endsWith(".jar")) return null;
        try {
            Path jar = Path.of(setting);
            return jar.isAbsolute() ? jar : null;
        } catch (InvalidPathException bad) {
            return null;
        }
    }

    /**
     * The jar the host read must be the one the install vouched for; the developer's reload is exempt. A boot layer
     * started without a digest (the tests start it by hand) has nothing to compare.
     */
    static void verify(String digest, String expected, boolean dev) throws IOException {
        if (!dev && expected != null && !expected.equals(digest))
            throw new IOException("The API's jar does not match the install: not loaded");
    }

    /**
     * Whether the jar is read now: never after it was refused, and once an API runs only with the developer's reload
     * (a release's jar is loaded the once).
     */
    static boolean wanted(boolean running, boolean refused, boolean dev) { return !refused && (!running || dev); }

    /** The API's classes by name, after its manifest says it was built for this boot layer. */
    private static Map<String, byte[]> classes(byte[] bytes) throws IOException {
        String prefix = NAMESPACE.replace('.', '/') + "/";
        var classes = new HashMap<String, byte[]>();
        int total = 0;
        try (var zip = new JarInputStream(new ByteArrayInputStream(bytes))) {
            Manifest manifest = zip.getManifest();
            String contract = manifest == null ? null : manifest.getMainAttributes().getValue(CONTRACT);
            if (!Boot.CONTRACT.equals(contract))
                throw new IOException("The API's jar was built for boot layer " + contract + ", not " + Boot.CONTRACT + ": restart the game after an update");
            for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                if (entry.isDirectory()) continue;
                String name = entry.getName();
                if (name.startsWith("META-INF/")) continue;
                if (!name.startsWith(prefix) || !name.endsWith(".class") || name.contains(".."))
                    throw new IOException("Unexpected entry in the API's jar: " + name);
                byte[] code = zip.readNBytes(MAX_CLASS + 1);
                total = Math.addExact(total, code.length);
                if (code.length > MAX_CLASS || total > 4 * MAX_JAR || classes.size() >= MAX_CLASSES)
                    throw new IOException("The API's classes are too large");
                if (classes.putIfAbsent(name.substring(0, name.length() - 6).replace('/', '.'), code) != null)
                    throw new IOException("A class twice in the API's jar: " + name);
            }
        }
        if (classes.isEmpty()) throw new IOException("The API's jar has no classes");
        return classes;
    }

    private static String sha256(byte[] bytes) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes)); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
}
