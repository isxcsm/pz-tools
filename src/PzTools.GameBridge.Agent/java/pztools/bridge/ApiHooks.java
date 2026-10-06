package pztools.bridge;

import java.lang.classfile.*;
import java.lang.classfile.instruction.ReturnInstruction;
import java.lang.constant.*;
import java.lang.instrument.*;
import java.security.ProtectionDomain;
import java.util.concurrent.TimeUnit;

/**
 * The stable calls that the extension API's hooks put into game code (docs/design/extension-api.md). The payload that
 * runs the API sets the handler, and a newer payload replaces it. Without a handler, and when a hook or the handler
 * fails, the game goes on as it would without the hook: the API never fails closed.
 */
public final class ApiHooks {
    /** Set by the payload. Called on the game's own thread. */
    public interface Handler {
        /** The game has made a new Lua environment ({@code LuaManager.init()}); mods load right after this. */
        void luaStarted(Class<?> luaManager) throws Exception;
    }

    // The payload loads beside the game's start; the first Lua environment may be made before it is ready.
    private static final long HANDLER_WAIT_NANOS = TimeUnit.SECONDS.toNanos(10);
    private static Handler handler;
    // A game the startup loader started, whose payload has not set the handler yet.
    private static boolean expected;

    private ApiHooks() { }

    /** In a game the startup loader started, before the game loads its Lua: the hook goes in as the class loads. */
    static void install(Instrumentation instrumentation) {
        synchronized (ApiHooks.class) { expected = true; }
        ClassFileTransformer transformer = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (!"zombie/Lua/LuaManager".equals(name)) return null;
                try { return luaManager(bytes, loader); }
                catch (Throwable problem) { report(problem); return null; }
            }
        };
        // Stays registered, so that the hook survives another agent's retransformation (see AgentEntry.ensureGameHook).
        instrumentation.addTransformer(transformer, true);
    }

    /** Sets the handler, replacing an earlier payload's; null when the payload cannot run the API. */
    public static void set(Handler next) {
        synchronized (ApiHooks.class) {
            handler = next;
            expected = false;
            ApiHooks.class.notifyAll();
        }
    }

    /** Put at the end of {@code LuaManager.init()}. */
    public static void luaStarted(Class<?> luaManager) {
        Handler current;
        synchronized (ApiHooks.class) {
            long deadline = System.nanoTime() + HANDLER_WAIT_NANOS;
            try {
                for (long left; handler == null && expected && (left = deadline - System.nanoTime()) > 0;)
                    TimeUnit.NANOSECONDS.timedWait(ApiHooks.class, left);
            } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            // Waited once: should the payload never come, later environments do not wait again.
            expected = false;
            current = handler;
        }
        if (current == null) return;
        try { current.luaStarted(luaManager); }
        catch (Throwable problem) { report(problem); }
    }

    // To the game's console log; the game goes on as if the hook were not there.
    private static void report(Throwable problem) { System.err.println("[PzTools API] " + problem); }

    private static byte[] luaManager(byte[] bytes, ClassLoader loader) {
        var cf = AgentEntry.classFile(loader);
        var model = cf.parse(bytes);
        if (model.methods().stream().filter(m -> m.methodName().equalsString("init")
                && m.methodType().equalsString("()V")).count() != 1)
            throw new IllegalArgumentException("Expected exactly one LuaManager.init()V");
        ClassDesc owner = model.thisClass().asSymbol();
        return cf.transformClass(model, ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString("init") && m.methodType().equalsString("()V"),
            (builder, element) -> {
                if (element instanceof ReturnInstruction) {
                    builder.ldc(owner);
                    builder.invokestatic(ClassDesc.of("pztools.bridge.ApiHooks"), "luaStarted",
                        MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Class));
                }
                builder.with(element);
            }));
    }
}
