package pzext.boot;

import java.lang.classfile.*;
import java.lang.constant.*;
import java.lang.instrument.*;
import java.security.ProtectionDomain;
import java.util.function.Consumer;

/**
 * The API's frame hook: one call to {@link Boot#frame()} at the start of {@code GameWindow.logic()}, put in as the game
 * loads {@code GameWindow} (or by a retransformation, when it has loaded already). The transformer stays registered: when
 * another agent retransforms {@code GameWindow} later, the JVM runs it again on the original bytes, so the call survives
 * their change and theirs survives ours.
 */
final class FrameHook {
    private static final String WINDOW = "zombie/GameWindow";
    private static volatile long failures;

    private FrameHook() { }

    /** Puts the call in; {@code loaded} is told the game's class loader once, when {@code GameWindow} has loaded. */
    static void install(Instrumentation instrumentation, Consumer<ClassLoader> loaded) {
        ClassFileTransformer transformer = new ClassFileTransformer() {
            private boolean told;

            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type, ProtectionDomain domain, byte[] bytes) {
                if (!WINDOW.equals(name)) return null;
                byte[] result;
                try { result = transformWindow(bytes, loader); }
                catch (Throwable problem) {
                    failures++;
                    System.err.println("[PZExt] the frame hook did not go in: " + problem);
                    result = null;
                }
                synchronized (this) {
                    if (!told) {
                        told = true;
                        loaded.accept(loader);
                    }
                }
                return result;
            }
        };
        instrumentation.addTransformer(transformer, true);
        for (Class<?> type : instrumentation.getAllLoadedClasses())
            if (type.getName().equals("zombie.GameWindow")) {
                try { instrumentation.retransformClasses(type); }
                catch (Throwable problem) { System.err.println("[PZExt] GameWindow could not be changed: " + problem); }
            }
    }

    /** Times the call could not be put in, for the status. */
    static long failures() { return failures; }

    private static byte[] transformWindow(byte[] bytes, ClassLoader loader) {
        var cf = ClassFiles.of(loader);
        var model = cf.parse(bytes);
        if (model.methods().stream().filter(m -> m.methodName().equalsString("logic")
                && m.methodType().equalsString("()V")).count() != 1)
            throw new IllegalArgumentException("Expected exactly one GameWindow.logic()V");
        return cf.transformClass(model, ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString("logic") && m.methodType().equalsString("()V"),
            CodeTransform.ofStateful(() -> new CodeTransform() {
                @Override public void atStart(CodeBuilder builder) {
                    builder.invokestatic(ClassDesc.of("pzext.boot.Boot"), "frame", MethodTypeDesc.of(ConstantDescs.CD_void));
                }
                @Override public void accept(CodeBuilder builder, CodeElement element) { builder.with(element); }
            })));
    }
}
