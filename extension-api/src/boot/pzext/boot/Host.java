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
 * {@code GameWindow}: the jar is read whole (the bytes hashed are the bytes loaded), its classes defined by a loader of
 * their own, and its {@code pzext.api.GameApi.start()} called, which hands the hooks their handlers. About once a second
 * the jar is looked at again: a changed one (an update copied over it in a running game) loads and starts a new API,
 * which takes the game's Lua environment over from the one before. The same pass writes which hooks the game has
 * ({@code api.tsv}, in the install folder) for whoever installed the API. Each frame runs the API's per-frame work.
 */
final class Host {
    private static final String NAMESPACE = "pzext.api", ENTRY = "pzext.api.GameApi", CONTRACT = "PZExt-Boot-Api";
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
                    load(home.resolve(Boot.API_JAR));
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
        var file = Files.readAttributes(jar, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        long time = file.lastModifiedTime().toMillis();
        if (api != null && file.size() == seenSize && time == seenTime) return;
        byte[] bytes;
        try (var input = Files.newInputStream(jar, LinkOption.NOFOLLOW_LINKS)) { bytes = input.readNBytes(MAX_JAR + 1); }
        if (bytes.length > MAX_JAR) throw new IOException("The API's jar is too large");
        String digest = sha256(bytes);
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
    }

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
