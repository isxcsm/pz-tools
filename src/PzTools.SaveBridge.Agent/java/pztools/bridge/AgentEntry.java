package pztools.bridge;

import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.HashMap;
import java.util.zip.ZipInputStream;

/** Stable dispatch only. Request implementations live in a disposable class loader. */
public final class AgentEntry {
    private static Object owner;
    private static volatile Runnable callback;

    public static void agentmain(String options, Instrumentation instrumentation) {
        String[] parts = options.split(":", -1);
        if (parts.length != 3) throw new IllegalArgumentException("Invalid bridge session");
        Path payload = Path.of(new String(Base64.getDecoder().decode(parts[2]), StandardCharsets.UTF_8));
        if (!payload.isAbsolute()) throw new IllegalArgumentException("Absolute payload path required");
        Thread worker = new Thread(() -> {
            try {
                // URL/JarFile caches can retain an older central directory when an app
                // replaces the payload at the same path. Read one fresh, closed snapshot.
                var classes = new HashMap<String, byte[]>();
                try (var zip = new ZipInputStream(Files.newInputStream(payload))) {
                    for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                        String name = entry.getName();
                        if (name.startsWith("pztools/bridge/runtime/") && name.endsWith(".class"))
                            classes.put(name.substring(0, name.length() - 6).replace('/', '.'), zip.readAllBytes());
                    }
                }
                var loader = new ClassLoader(AgentEntry.class.getClassLoader()) {
                    @Override protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
                        if (!name.startsWith("pztools.bridge.runtime.")) return super.loadClass(name, resolve);
                        synchronized (getClassLoadingLock(name)) {
                            Class<?> loaded = findLoadedClass(name);
                            if (loaded == null) {
                                byte[] bytes = classes.get(name);
                                if (bytes == null) throw new ClassNotFoundException(name);
                                loaded = defineClass(name, bytes, 0, bytes.length);
                            }
                            if (resolve) resolveClass(loaded);
                            return loaded;
                        }
                    }
                };
                loader.loadClass("pztools.bridge.runtime.SaveBridge")
                    .getMethod("run", String.class, Instrumentation.class)
                    .invoke(null, parts[0] + ":" + parts[1], instrumentation);
            } catch (Throwable exception) {
                System.err.println("[PzTools bridge session] " + exception);
            }
        }, "PzTools-save-bridge");
        worker.setDaemon(true);
        worker.start();
    }

    public static synchronized boolean acquire(Object candidate, Runnable poll) {
        if (owner != null) return false;
        owner = candidate;
        callback = poll;
        return true;
    }

    public static synchronized void release(Object candidate) {
        if (owner != candidate) return;
        callback = null;
        owner = null;
    }

    public static void poll() {
        Runnable current = callback;
        if (current != null) current.run();
    }
}
