package pztools.bridge;

import java.lang.classfile.*;
import java.lang.constant.*;
import java.lang.instrument.*;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.security.ProtectionDomain;
import java.util.concurrent.atomic.*;

/**
 * The game-loop hook (docs/design/game-bridge.md#the-game-loop-hook): one call to {@link AgentEntry#poll()} at the start
 * of {@code GameWindow.logic()}, and the two things that call runs each frame: the game-thread work of the request that
 * owns the game thread (a save), and the payload's frame router, which runs every other per-frame job of the payload.
 * Knows none of those jobs: a new one is the payload's own.
 */
final class GameHook {
    // Guarded by the class.
    private static Class<?> window;
    private static ClassFileTransformer hook;
    private static volatile long installs;
    // Times the dispatch call could not be put back when GameWindow was retransformed after it was installed.
    private static volatile long failures;

    // What the game loop runs, guarded by lock. No callback runs under it, and it is never held while another lock is
    // taken: a payload's own locks come first (they call in here), the payload switch's comes before this one too.
    private static final Object lock = new Object();
    // Set while a payload switch waits for the old payload to let go: nothing runs, and nothing new is taken.
    private static boolean paused;
    private static int running;
    private static Object requestOwner;
    private static Runnable request, frames;

    private GameHook() { }

    /** Installs only the stable dispatch call, never a callback owned by a payload loader. */
    static synchronized Class<?> ensure(Instrumentation instrumentation) throws Exception {
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
        if (!Modifier.isStatic(logic.getModifiers()) || logic.getReturnType() != void.class
                || !Modifier.isStatic(save.getModifiers()) || save.getReturnType() != void.class)
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
                    if (hook != null) failures++;
                    return null;
                }
            }
        };
        instrumentation.addTransformer(candidate, true);
        try {
            instrumentation.retransformClasses(window);
            if (!transformed.get()) throw new IllegalStateException("Could not install game hook", failure.get());
            hook = candidate;
            installs++;
            return window;
        } finally { if (hook == null) instrumentation.removeTransformer(candidate); }
    }

    /**
     * New stack maps need the game's class hierarchy. It is read from the class files themselves: loading classes from
     * inside a transformer, perhaps during another agent's retransformation, can fail or deadlock, and runs every
     * agent's transformers on the classes it loads. Loading stays only as the last resort, for a class whose file
     * cannot be read, as the hook was always installed before.
     */
    static ClassFile classFile(ClassLoader loader) {
        return ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.defaultResolver()
            .orElse(ClassHierarchyResolver.ofResourceParsing(loader)).orElse(ClassHierarchyResolver.ofClassLoading(loader)).cached()));
    }

    private static byte[] transformWindow(byte[] bytes, ClassLoader loader) {
        var cf = classFile(loader);
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

    // ---- what the game loop runs ----

    static boolean acquire(Object owner, Runnable poll) {
        synchronized (lock) {
            if (requestOwner != null || paused) return false;
            requestOwner = owner;
            request = poll;
            return true;
        }
    }

    static void release(Object owner) {
        synchronized (lock) {
            if (requestOwner != owner) return;
            request = null;
            requestOwner = null;
        }
    }

    /** Takes the frame slot for the payload's router, or confirms it has it; refused to another, and during a switch. */
    static boolean claimFrames(Runnable router) {
        synchronized (lock) {
            if (frames == router) return true;
            if (frames != null || paused) return false;
            frames = router;
            return true;
        }
    }

    static void releaseFrames(Runnable router) {
        synchronized (lock) { if (frames == router) frames = null; }
    }

    /** A request owns the game thread: its save may still run after its connection ended. */
    static boolean requestActive() { synchronized (lock) { return requestOwner != null; } }

    static void pause(boolean value) { synchronized (lock) { paused = value; } }

    /** No payload's work holds a slot or runs: what a payload switch waits for. */
    static boolean idle() { synchronized (lock) { return requestOwner == null && frames == null && running == 0; } }

    /**
     * Each frame, on the game thread. Whatever a callback throws stays here: the game goes on, and the callback is
     * dropped (its owner still holds its slot until it lets go).
     */
    static void poll() {
        Runnable router, current;
        synchronized (lock) {
            if (paused) return;
            router = frames; current = request;
            if (router == null && current == null) return;
            running++;
        }
        try {
            if (router != null) {
                try { router.run(); }
                catch (Throwable failure) { synchronized (lock) { if (frames == router) frames = null; } }
            }
            if (current != null) {
                try { current.run(); }
                catch (Throwable failure) { synchronized (lock) { if (request == current) request = null; } }
            }
        } finally { synchronized (lock) { running--; } }
    }

    // Diagnostics.
    static long installs() { return installs; }
    static long failures() { return failures; }
    static boolean requestCallbackActive() { synchronized (lock) { return request != null; } }
    static boolean framesActive() { synchronized (lock) { return frames != null; } }
}
