package pztools.bridge.runtime;

import java.lang.classfile.*;
import java.lang.instrument.*;
import java.security.ProtectionDomain;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

/** Disarms older resident bridge code that did not retain an uninstall handle. */
final class LegacyBridgeRetirement {
    static boolean retire(Instrumentation instrumentation) throws Exception {
        Class<?> bridge = null;
        List<Class<?>> targets = new ArrayList<>();
        for (Class<?> type : instrumentation.getAllLoadedClasses()) {
            if (type.getName().equals("pztools.bridge.SaveBridge")) { bridge = type; targets.add(type); }
            else if (type.getName().startsWith("pztools.bridge.SaveBridge$")
                    && ClassFileTransformer.class.isAssignableFrom(type)) targets.add(type);
        }
        if (bridge == null) return true;
        var field = bridge.getDeclaredField("pending");
        field.setAccessible(true);
        if (((AtomicReference<?>)field.get(null)).get() != null)
            return false;
        Set<Class<?>> transformed = new HashSet<>();
        AtomicReference<Throwable> failure = new AtomicReference<>();
        // Use the public retransformation API on our own old classes, never private
        // JVM transformer registries. Older transformer objects may remain registered,
        // but cannot reinsert a callback after their transform method is disabled.
        ClassFileTransformer retirement = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (!targets.contains(type)) return null;
                try {
                    boolean isBridge = type.getName().equals("pztools.bridge.SaveBridge");
                    var cf = ClassFile.of();
                    byte[] result = cf.transformClass(cf.parse(bytes), ClassTransform.transformingMethodBodies(
                        method -> isBridge ? method.methodName().equalsString("poll") && method.methodType().equalsString("()V")
                            : method.methodName().equalsString("transform") && method.methodType().stringValue().endsWith(")[B"),
                        CodeTransform.ofStateful(() -> new CodeTransform() {
                            @Override public void atStart(CodeBuilder builder) {
                                if (isBridge) builder.return_(); else builder.aconst_null().areturn();
                            }
                            @Override public void accept(CodeBuilder builder, CodeElement element) { }
                        })));
                    transformed.add(type);
                    return result;
                } catch (Throwable exception) { failure.set(exception); return null; }
            }
        };
        instrumentation.addTransformer(retirement, true);
        try { instrumentation.retransformClasses(targets.toArray(Class<?>[]::new)); }
        finally { instrumentation.removeTransformer(retirement); }
        if (failure.get() != null || !transformed.containsAll(targets))
            throw new IllegalStateException("Could not retire the older bridge", failure.get());
        for (String name : List.of("window", "save", "gameThread", "gameLoader")) {
            var reference = bridge.getDeclaredField(name);
            reference.setAccessible(true);
            reference.set(null, null);
        }
        var installed = bridge.getDeclaredField("installed");
        installed.setAccessible(true);
        installed.setBoolean(null, false);
        return true;
    }
}
