package pztools.bridge.runtime;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.Map;
import pztools.bridge.AgentEntry;
import pztools.extensions.api.internal.ClassArchive;

/**
 * The extension API's code (docs/design/extension-api.md), loaded from its own jar in the extensions folder
 * ({@link ExtensionHost#directory()}) and kept by the bootstrap with the jar's digest, so that it outlives a payload
 * switch: a new payload finds the same API running, and only a changed jar loads (and starts) a new one, which takes
 * the game's Lua environment over from the one before. Only a game the startup loader started loads it.
 */
final class ApiHost {
    static final String JAR = "pztools-extension-api.jar";
    private static final String NAMESPACE = "pztools.api", ENTRY = "pztools.api.GameApi";
    private static final String KEPT_API = "extension-api", KEPT_DIGEST = "extension-api-sha256";
    // The jar as this payload last read it (its path, size and time) and the API it gave: asked about once a second, a
    // jar that did not change is not read again.
    private static Path seenPath;
    private static long seenSize, seenTime;
    private static Api seen;

    private ApiHost() { }

    /** What the payload calls of the API (its class, its per-frame work and its hook status). */
    record Api(Class<?> type, MethodHandle frame, MethodHandle status) {
        void frame(ClassLoader game) throws Throwable { frame.invokeExact(game); }
        void writeStatus(Path folder) throws Throwable { status.invokeExact(folder); }
    }

    /** The API from the jar in the extensions folder now (see {@link #current(Path)}). */
    static Api current() throws Exception { return current(ExtensionHost.directory().resolve(JAR)); }

    /** The API from this jar: the one kept while the jar has its digest, else a new one, started. */
    static synchronized Api current(Path jar) throws Exception {
        var file = Files.readAttributes(jar, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        long time = file.lastModifiedTime().toMillis();
        if (seen != null && jar.equals(seenPath) && file.size() == seenSize && time == seenTime) return seen;
        Class<?> type;
        Map<String, Object> kept = AgentEntry.kept();
        synchronized (kept) {
            var archive = ClassArchive.read(jar);
            // It answers the bootstrap's hooks: the bootstrap the game loaded at its start.
            archive.require("PzTools-Bootstrap-Api", System.getProperty("pztools.bridge.bootstrap.api", ""));
            type = kept.get(KEPT_API) instanceof Class<?> running && archive.digest().equals(kept.get(KEPT_DIGEST))
                ? running : null;
            if (type == null) {
                var next = archive.loader(NAMESPACE, AgentEntry.class.getClassLoader(), true).loadClass(ENTRY);
                next.getMethod("start").invoke(null);
                kept.put(KEPT_API, next);
                kept.put(KEPT_DIGEST, archive.digest());
                type = next;
            }
        }
        var lookup = MethodHandles.publicLookup();
        seen = new Api(type, lookup.findStatic(type, "frame", MethodType.methodType(void.class, ClassLoader.class)),
            lookup.findStatic(type, "writeStatus", MethodType.methodType(void.class, Path.class)));
        seenPath = jar;
        seenSize = file.size();
        seenTime = time;
        return seen;
    }
}
