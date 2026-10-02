package pztools.bridge;

import java.lang.instrument.*;
import java.lang.reflect.*;
import java.security.ProtectionDomain;
import java.util.concurrent.atomic.AtomicReference;

/** Models the old resident hook, which discarded its transformer removal handle. */
public final class SaveBridge {
    private static final AtomicReference<Object> pending = new AtomicReference<>();
    private static boolean installed;
    private static Class<?> window;
    private static Method save;
    private static Field gameThread;
    private static ClassLoader gameLoader;
    public static void poll() { }
    public static void install(Instrumentation instrumentation) throws Exception {
        window = Class.forName("zombie.GameWindow");
        save = window.getMethod("save", boolean.class);
        gameThread = window.getField("gameThread");
        gameLoader = window.getClassLoader();
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (type != window) return null;
                return bridgefixture.Inspector.inject(bytes, "pztools.bridge.SaveBridge", "poll");
            }
        }, true);
        instrumentation.retransformClasses(window);
        installed = true;
    }
}
