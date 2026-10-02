package pztools.bridge;

import java.io.*;
import pztools.extensions.api.SaveModules;
import pztools.extensions.api.ExtensionApi;
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
    private static String extensionRuntimeDigest;
    private static volatile boolean reloadRequested;
    private static boolean dispatchPaused;
    private static int dispatching;
    private static Object owner;
    private static volatile Runnable callback;
    private static volatile Runnable observerCallback;
    private static Object lifecycleOwner;
    private static volatile Runnable lifecycleCallback;
    private static final AtomicBoolean watchSession = new AtomicBoolean();
    private static final AtomicBoolean extensionSession = new AtomicBoolean();
    private static Method payloadWatch;
    private static Method payloadExtensions;
    private static final Object runtimeGate = new Object();
    private static Instrumentation instrumentation;
    private static Class<?> window;
    private static ClassFileTransformer hook;
    private static final AtomicBoolean session = new AtomicBoolean();
    private static Path payload;
    private static String payloadDigest;
    private static Method payloadRun;
    private static volatile long payloadLoads;
    private static volatile long hookInstalls;
    // Times the dispatch call could not be put back when GameWindow was retransformed after it was installed.
    private static volatile long hookFailures;
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
            System.setProperty("pztools.bridge.bootstrap.api", "11");
            // Published only after the listener is bound. Never print this credential.
            System.setProperty(CONTROL_PROPERTY, "2:" + ProcessHandle.current().pid() + ":"
                + server.getLocalPort() + ":" + secret);
        } catch (Throwable failure) {
            server.close();
            throw failure;
        }
    }

    /** Reload optional runtime/modules only at a save-session boundary; WATCH stays connected. */
    public static SaveModules extensions() throws Exception {
        synchronized (runtimeGate) {
            Path directory = payload.getParent().resolve("extensions");
            var archive = ClassArchive.read(directory.resolve("pztools-extension-runtime.jar"));
            archive.require("PzTools-Extension-Api", Integer.toString(ExtensionApi.HOST_ABI));
            if (extensionHost == null || !archive.digest().equals(extensionRuntimeDigest)) {
                var loader = archive.loader("pztools.extensions.runtime", AgentEntry.class.getClassLoader(), true);
                var next = (SaveModules)loader.loadClass("pztools.extensions.runtime.ModuleHost")
                    .getConstructor(Path.class).newInstance(directory);
                try { if (extensionHost != null) extensionHost.close(); }
                catch (Exception failedRetirement) { next.close(); throw failedRetirement; }
                extensionHost = next; extensionRuntimeDigest = archive.digest();
            } else extensionHost.relocate(directory);
            return extensionHost;
        }
    }
    public static boolean runtimeReloadRequested() { return reloadRequested; }

    /** No callback is executed under runtimeGate or the admission monitor. */
    private static Method preparePayload(Path requested, String kind) throws Exception {
        synchronized (runtimeGate) {
            var archive = ClassArchive.read(requested);
            archive.require("PzTools-Bootstrap-Api", "11");
            if (payloadRun != null && archive.digest().equals(payloadDigest)) {
                if (!payload.equals(requested)) {
                    synchronized (AgentEntry.class) {
                        if (session.get() || callback != null) throw new ReloadBusy();
                        payload = requested;
                    }
                }
                return kind.equals("WATCH") ? payloadWatch : kind.equals("EXTENSIONS") ? payloadExtensions : payloadRun;
            }
            synchronized (AgentEntry.class) {
                if (session.get() || callback != null) throw new ReloadBusy();
            }
            // Stage and link before asking the old WATCH generation to finish.
            var loader = archive.loader("pztools.bridge.runtime", AgentEntry.class.getClassLoader(), false);
            Method next = loader.loadClass("pztools.bridge.runtime.BridgeSession").getMethod("run", String.class, Instrumentation.class);
            Method nextWatch = loader.loadClass("pztools.bridge.runtime.RuntimeWatch").getMethod("run", String.class, Instrumentation.class);
            Method nextExtensions = loader.loadClass("pztools.bridge.runtime.ExtensionControl").getMethod("run", String.class, Instrumentation.class);
            reloadRequested = true;
            synchronized (AgentEntry.class) { dispatchPaused = true; }
            try {
                long deadline = System.nanoTime() + 3_000_000_000L;
                while (true) {
                    synchronized (AgentEntry.class) {
                        if (!session.get() && !watchSession.get() && !extensionSession.get() && callback == null
                                && observerCallback == null && lifecycleCallback == null && dispatching == 0) break;
                    }
                    if (System.nanoTime() >= deadline) throw new ReloadBusy();
                    Thread.sleep(10); // Control thread only; never wait in game dispatch.
                }
                payloadRun = next; payloadWatch = nextWatch; payloadExtensions = nextExtensions; payloadDigest = archive.digest();
                payload = requested; payloadLoads++;
                return kind.equals("WATCH") ? nextWatch : kind.equals("EXTENSIONS") ? nextExtensions : next;
            } finally {
                synchronized (AgentEntry.class) { dispatchPaused = false; }
                reloadRequested = false;
            }
        }
    }
    private static final class ReloadBusy extends Exception { }

    private static void controlLoop(ServerSocket server, String secret) {
        while (!server.isClosed()) {
            try (Socket socket = server.accept()) {
                socket.setSoTimeout(2000);
                var input = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                var output = new PrintWriter(new OutputStreamWriter(socket.getOutputStream(), StandardCharsets.UTF_8), true);
                String line = readLimited(input);
                String[] parts = line == null ? new String[0] : line.split("\\t", -1);
                if ((parts.length != 4 && !(parts.length == 5 && (parts[4].equals("WATCH") || parts[4].equals("EXTENSIONS")))) || !MessageDigest.isEqual(secret.getBytes(StandardCharsets.US_ASCII),
                        parts[0].getBytes(StandardCharsets.US_ASCII))) {
                    output.println("REJECTED");
                    continue;
                }
                int port = Integer.parseInt(parts[1]);
                Path requestedPayload = Path.of(new String(Base64.getDecoder().decode(parts[3]), StandardCharsets.UTF_8));
                if (port < 1 || port > 65535 || !parts[2].matches("[0-9a-f]{64}")
                        || !requestedPayload.isAbsolute()) {
                    output.println("RESTART_REQUIRED");
                    continue;
                }
                // Saves, probes, profile and notice commands: one request each, handled by BridgeSession.
                String kind = parts.length == 5 ? parts[4] : "REQUEST";
                Method entry;
                try { entry = preparePayload(requestedPayload.normalize(), kind); }
                catch (ReloadBusy busy) { output.println("BUSY"); continue; }
                catch (Exception incompatible) { output.println("PAYLOAD_UNAVAILABLE"); continue; }
                AtomicBoolean slot = kind.equals("WATCH") ? watchSession : kind.equals("EXTENSIONS") ? extensionSession : session;
                if (!slot.compareAndSet(false, true)) { output.println("BUSY"); continue; }
                try {
                    Thread worker = new Thread(() -> runSession(parts[1] + ":" + parts[2], kind, entry), "PzTools-" + kind.toLowerCase(Locale.ROOT));
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

    private static void runSession(String options, String kind, Method invokeEntry) {
        try {
            if (kind.equals("REQUEST")) sessions++;
            invokeEntry.invoke(null, options, instrumentation);
        } catch (Throwable failure) {
            System.err.println("[PzTools bridge session] " + failure);
        } finally { (kind.equals("WATCH") ? watchSession : kind.equals("EXTENSIONS") ? extensionSession : session).set(false); }
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
        // Stays registered: when another agent retransforms GameWindow later, the JVM runs this again on the original
        // bytes, so the dispatch call survives their change and theirs survives ours. Should it fail then, the class
        // goes on without it; that is counted for diagnostics rather than passed to the other agent.
        ClassFileTransformer candidate = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (type != window) return null;
                try {
                    byte[] result = transformWindow(bytes, loader);
                    transformed.set(true);
                    return result;
                } catch (Throwable exception) {
                    failure.set(exception);
                    if (hook != null) hookFailures++;
                    return null;
                }
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
        // The new stack maps need the game's class hierarchy. It is read from the class files themselves: loading
        // classes from inside a transformer, perhaps during another agent's retransformation, can fail or deadlock,
        // and runs every agent's transformers on the classes it loads. Loading stays only as the last resort, for a
        // class whose file cannot be read, as the hook was always installed before.
        var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.defaultResolver()
            .orElse(ClassHierarchyResolver.ofResourceParsing(loader)).orElse(ClassHierarchyResolver.ofClassLoading(loader)).cached()));
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
    public static synchronized boolean acquireLifecycle(Object candidate, Runnable poll) {
        if (lifecycleOwner != null) return false;
        lifecycleOwner = candidate; lifecycleCallback = poll; return true;
    }
    public static synchronized void releaseLifecycle(Object candidate) {
        if (lifecycleOwner == candidate) { lifecycleCallback = null; lifecycleOwner = null; }
    }
    public static void poll() {
        Runnable observer, current, lifecycle;
        synchronized (AgentEntry.class) {
            if (dispatchPaused) return;
            observer = observerCallback; current = callback; lifecycle = lifecycleCallback;
            if (observer == null && current == null && lifecycle == null) return;
            dispatching++;
        }
        try {
            if (observer != null) {
                try { observer.run(); }
                catch (Throwable failure) {
                    synchronized (AgentEntry.class) { if (observerCallback == observer) observerCallback = null; }
                }
            }
            if (lifecycle != null) {
                try { lifecycle.run(); }
                catch (Throwable failure) {
                    synchronized (AgentEntry.class) { if (lifecycleCallback == lifecycle) lifecycleCallback = null; }
                }
            }
            if (current != null) current.run();
        } finally { synchronized (AgentEntry.class) { dispatching--; } }
    }
    // Test/diagnostic counters: never include credentials or payload paths.
    public static synchronized String diagnostics() {
        // New counters go at the end: readers match the earlier fields as they have always been laid out.
        return "hookInstalls=" + hookInstalls + ";payloadLoads=" + payloadLoads + ";sessions=" + sessions
            + ";callbackActive=" + (callback != null) + ";observerActive=" + (observerCallback != null) + ";hookFailures=" + hookFailures;
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
