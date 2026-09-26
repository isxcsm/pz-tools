package pztools.bridge;

import java.io.*;
import pztools.extensions.api.SaveModules;
import pztools.extensions.api.internal.ClassArchive;
import java.lang.classfile.*;
import java.lang.constant.*;
import java.lang.instrument.*;
import java.lang.reflect.Method;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.util.*;
import java.util.concurrent.atomic.*;
import java.util.zip.ZipInputStream;

/** One bootstrap and idle dispatch hook per JVM; no save is performed by the control thread. */
public final class AgentEntry {
    public static final String CONTROL_PROPERTY = "pztools.bridge.control.v1";
    private static SaveModules extensionHost;
    private static boolean extensionHostAttempted;
    private static Object owner;
    private static volatile Runnable callback;
    private static volatile Runnable observerCallback;
    private static final AtomicBoolean watchSession = new AtomicBoolean();
    private static Method payloadWatch;
    private static final Object runtimeGate = new Object();
    private static Instrumentation instrumentation;
    private static Class<?> window;
    private static ClassFileTransformer hook;
    private static final AtomicBoolean session = new AtomicBoolean();
    private static Path payload;
    private static byte[] payloadDigest;
    private static Method payloadRun;
    private static volatile long payloadLoads;
    private static volatile long hookInstalls;
    private static volatile long sessions;

    public static synchronized void agentmain(String options, Instrumentation value) throws Exception {
        if (instrumentation != null) throw new IllegalStateException("Bootstrap already loaded; reuse its control endpoint");
        String[] parts = options.split(":", -1);
        if (parts.length != 2 || !parts[0].equals("BOOTSTRAP1"))
            throw new IllegalArgumentException("Incompatible bootstrap; rebuild app/workers and restart the game");
        Path candidate = Path.of(new String(Base64.getDecoder().decode(parts[1]), StandardCharsets.UTF_8));
        if (!candidate.isAbsolute()) throw new IllegalArgumentException("Absolute payload path required");
        payload = candidate.normalize();
        var server = new ServerSocket();
        server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 8);
        byte[] key = new byte[32];
        new SecureRandom().nextBytes(key);
        String secret = HexFormat.of().formatHex(key);
        instrumentation = value;
        Thread control = new Thread(() -> controlLoop(server, secret), "PzTools-bridge-control");
        control.setDaemon(true);
        try {
            control.start();
            System.setProperty("pztools.bridge.bootstrap.api", "5");
            // Published only after the listener is bound. Never print this credential.
            System.setProperty(CONTROL_PROPERTY, "2:" + ProcessHandle.current().pid() + ":"
                + server.getLocalPort() + ":" + secret);
        } catch (Throwable failure) {
            server.close();
            throw failure;
        }
    }

    /** Optional modules are loaded only for an explicit provider request. */
    public static synchronized SaveModules extensions() throws Exception {
        if (extensionHost != null) return extensionHost;
        if (extensionHostAttempted) throw new IllegalStateException("Extension runtime unavailable; restart required");
        extensionHostAttempted = true;
        Path directory = payload.getParent().resolve("extensions");
        ClassLoader loader = ClassArchive.open(directory.resolve("pztools-extension-runtime.jar"),
            "pztools.extensions.runtime", AgentEntry.class.getClassLoader());
        extensionHost = (SaveModules)loader.loadClass("pztools.extensions.runtime.ModuleHost")
            .getConstructor(Path.class).newInstance(directory);
        return extensionHost;
    }

    private static void controlLoop(ServerSocket server, String secret) {
        while (!server.isClosed()) {
            try (Socket socket = server.accept()) {
                socket.setSoTimeout(2000);
                var input = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                var output = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8), true);
                String line = readLimited(input);
                String[] parts = line == null ? new String[0] : line.split("\\t", -1);
                if ((parts.length != 4 && !(parts.length == 5 && parts[4].equals("WATCH"))) || !MessageDigest.isEqual(secret.getBytes(StandardCharsets.US_ASCII),
                        parts[0].getBytes(StandardCharsets.US_ASCII))) {
                    output.println("REJECTED");
                    continue;
                }
                int port = Integer.parseInt(parts[1]);
                Path requestedPayload = Path.of(new String(Base64.getDecoder().decode(parts[3]), StandardCharsets.UTF_8));
                if (port < 1 || port > 65535 || !parts[2].matches("[0-9a-f]{64}")
                        || !requestedPayload.isAbsolute() || !payload.equals(requestedPayload.normalize())) {
                    output.println("RESTART_REQUIRED");
                    continue;
                }
                boolean watch = parts.length == 5;
                AtomicBoolean slot = watch ? watchSession : session;
                if (!slot.compareAndSet(false, true)) { output.println("BUSY"); continue; }
                try {
                    Thread worker = new Thread(() -> runSession(parts[1] + ":" + parts[2], watch), watch ? "PzTools-runtime-watch" : "PzTools-save-bridge");
                    worker.setDaemon(true);
                    worker.start();
                    output.println("ACCEPTED");
                } catch (Throwable failure) {
                    slot.set(false);
                    throw failure;
                }
            } catch (Exception failure) {
                // Invalid/abandoned control clients cannot enqueue a save. No retry of an accepted request.
                if (server.isClosed()) return;
            }
        }
    }

    private static void runSession(String options, boolean watch) {
        try {
            // Read a closed snapshot, never JarFile/URL caches. One current payload loader is retained.
            // A changed payload replaces it only between sessions; old request state cannot overlap.
            Method invokeEntry;
            synchronized (runtimeGate) {
            byte[] archive;
            try (var stream = Files.newInputStream(payload)) {
                archive = stream.readNBytes(16 * 1024 * 1024 + 1);
            }
            if (archive.length > 16 * 1024 * 1024) throw new IOException("Oversized bridge payload");
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(archive);
            if (payloadRun == null || !MessageDigest.isEqual(digest, payloadDigest)) {
                if (payloadRun != null && (observerCallback != null || callback != null || (watch ? session.get() : watchSession.get())))
                    throw new IOException("Runtime changed while observing; restart the game to replace it safely");
                var classes = new HashMap<String, byte[]>();
                int total = 0;
                try (var zip = new ZipInputStream(new ByteArrayInputStream(archive))) {
                    for (var entry = zip.getNextEntry(); entry != null; entry = zip.getNextEntry()) {
                        String name = entry.getName();
                        if (name.startsWith("pztools/bridge/runtime/") && name.endsWith(".class")) {
                            byte[] bytes = zip.readNBytes(2 * 1024 * 1024 + 1);
                            total = Math.addExact(total, bytes.length);
                            if (bytes.length > 2 * 1024 * 1024 || total > 16 * 1024 * 1024)
                                throw new IOException("Oversized runtime classes");
                            classes.put(name.substring(0, name.length() - 6).replace('/', '.'), bytes);
                        }
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
                Method next = loader.loadClass("pztools.bridge.runtime.SaveBridge")
                    .getMethod("run", String.class, Instrumentation.class);
                payloadWatch = loader.loadClass("pztools.bridge.runtime.RuntimeWatch")
                    .getMethod("run", String.class, Instrumentation.class);
                payloadRun = next;
                payloadDigest = digest;
                payloadLoads++;
            }
            invokeEntry = watch ? payloadWatch : payloadRun;
            }
            if (!watch) sessions++;
            invokeEntry.invoke(null, options, instrumentation);
        } catch (Throwable failure) {
            System.err.println("[PzTools bridge session] " + failure);
        } finally { (watch ? watchSession : session).set(false); }
    }

    /** Installs only the stable dispatch call, never a callback owned by a payload loader. */
    public static synchronized Class<?> ensureGameHook() throws Exception {
        if (hook != null) return window;
        if (Runtime.version().feature() != 25 || !instrumentation.isRetransformClassesSupported())
            throw new IllegalStateException("This bridge requires Java 25 with retransformation");
        for (Class<?> type : instrumentation.getAllLoadedClasses()) {
            if (type.getName().equals("zombie.GameWindow")) {
                if (window != null && window != type) throw new IllegalStateException("Multiple GameWindow classes");
                window = type;
            }
        }
        if (window == null) throw new IllegalStateException("GameWindow has not loaded yet");
        if (Class.forName(AgentEntry.class.getName(), false, window.getClassLoader()) != AgentEntry.class)
            throw new IllegalStateException("Game cannot access the bootstrap");
        Method logic = window.getDeclaredMethod("logic");
        Method save = window.getMethod("save", boolean.class);
        window.getField("gameThread");
        if (!java.lang.reflect.Modifier.isStatic(logic.getModifiers()) || logic.getReturnType() != void.class
                || !java.lang.reflect.Modifier.isStatic(save.getModifiers()) || save.getReturnType() != void.class)
            throw new IllegalStateException("Unsupported game method signatures");
        var transformed = new AtomicBoolean();
        var failure = new AtomicReference<Throwable>();
        ClassFileTransformer candidate = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (type != window) return null;
                try {
                    byte[] result = transformWindow(bytes, loader);
                    transformed.set(true);
                    return result;
                } catch (Throwable exception) { failure.set(exception); return null; }
            }
        };
        instrumentation.addTransformer(candidate, true);
        try {
            instrumentation.retransformClasses(window);
            if (!transformed.get()) throw new IllegalStateException("Could not install game hook", failure.get());
            hook = candidate;
            hookInstalls++;
            return window;
        } finally { if (hook == null) instrumentation.removeTransformer(candidate); }
    }

    private static byte[] transformWindow(byte[] bytes, ClassLoader loader) {
        var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
        var model = cf.parse(bytes);
        if (model.methods().stream().filter(m -> m.methodName().equalsString("logic")
                && m.methodType().equalsString("()V")).count() != 1)
            throw new IllegalArgumentException("Expected exactly one GameWindow.logic()V");
        return cf.transformClass(model, ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString("logic") && m.methodType().equalsString("()V"),
            CodeTransform.ofStateful(() -> new CodeTransform() {
                @Override public void atStart(CodeBuilder builder) {
                    builder.invokestatic(ClassDesc.of("pztools.bridge.AgentEntry"), "poll", MethodTypeDesc.of(ConstantDescs.CD_void));
                }
                @Override public void accept(CodeBuilder builder, CodeElement element) { builder.with(element); }
            })));
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
    public static void observe(Runnable observer) { observerCallback = observer; }
    public static void poll() {
        Runnable observer = observerCallback;
        if (observer != null) {
            try { observer.run(); } catch (Throwable failure) { observerCallback = null; }
        }
        Runnable current = callback;
        if (current != null) current.run();
    }
    // Test/diagnostic counters: never include credentials or payload paths.
    public static synchronized String diagnostics() {
        return "hookInstalls=" + hookInstalls + ";payloadLoads=" + payloadLoads + ";sessions=" + sessions
            + ";callbackActive=" + (callback != null) + ";observerActive=" + (observerCallback != null);
    }
    private static String readLimited(Reader input) throws IOException {
        var line = new StringBuilder();
        for (int value; (value = input.read()) != -1;) {
            if (value == '\n') return line.toString();
            if (value != '\r') line.append((char)value);
            if (line.length() > 32768) throw new IOException("Oversized control request");
        }
        return null;
    }
}
