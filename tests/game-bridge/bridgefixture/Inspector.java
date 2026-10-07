package bridgefixture;

import java.lang.classfile.*;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.constant.*;
import java.lang.instrument.*;
import java.nio.file.*;
import java.security.ProtectionDomain;

/** Test-only instrumentation: checks one stable idle hook and preservation of other agents. */
public final class Inspector {
    private static Instrumentation instrumentation;
    public static void marker() { }
    public static void premain(String options, Instrumentation value) throws Exception {
        instrumentation = value;
        instrumentation.addTransformer(new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (!"zombie/GameWindow".equals(name)) return null;
                return inject(bytes, "bridgefixture.Inspector", "marker");
            }
        }, true);
    }
    public static byte[] inject(byte[] bytes, String owner, String method) {
        var cf = ClassFile.of();
        return cf.transformClass(cf.parse(bytes), ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString("logic"), CodeTransform.ofStateful(() -> new CodeTransform() {
                @Override public void atStart(CodeBuilder builder) {
                    builder.invokestatic(ClassDesc.of(owner), method, MethodTypeDesc.of(ConstantDescs.CD_void));
                }
                @Override public void accept(CodeBuilder builder, CodeElement element) { builder.with(element); }
            })));
    }
    public static void inspect(Path output) throws Exception {
        var calls = new StringBuilder();
        ClassFileTransformer reader = new ClassFileTransformer() {
            @Override public byte[] transform(ClassLoader loader, String name, Class<?> type,
                    ProtectionDomain domain, byte[] bytes) {
                if (!"zombie/GameWindow".equals(name)) return null;
                ClassFile.of().parse(bytes).methods().stream().filter(m -> m.methodName().equalsString("logic"))
                    .forEach(m -> m.code().orElseThrow().forEach(e -> {
                        if (e instanceof InvokeInstruction call)
                            calls.append(call.owner().asInternalName()).append('.').append(call.name().stringValue()).append('\n');
                    }));
                return null;
            }
        };
        Instrumentation observer = instrumentation;
        String diagnostics = "";
        try {
            var resident = Class.forName("pztools.bridge.AgentEntry");
            var field = resident.getDeclaredField("instrumentation");
            field.setAccessible(true);
            // Attach can publish the bootstrap class before agentmain initializes it.
            // Keep the premain observer until the resident instrumentation is available.
            var candidate = (Instrumentation)field.get(null);
            if (candidate != null) observer = candidate;
            diagnostics = (String)resident.getMethod("diagnostics").invoke(null);
            calls.append(diagnostics).append('\n');
        } catch (ClassNotFoundException ignored) { }
        observer.addTransformer(reader, true);
        try { observer.retransformClasses(Class.forName("zombie.GameWindow")); }
        finally { observer.removeTransformer(reader); }
        // Each Java agent has its own transformer chain: our premain observer runs before the attached agent's. A
        // request that holds the game thread is read from the bootstrap's own diagnostics.
        if (diagnostics.contains("callbackActive=true")) calls.append("bridge-session-active\n");
        Path staging = output.resolveSibling(output.getFileName() + ".tmp");
        Files.writeString(staging, calls.toString());
        Files.move(staging, output, StandardCopyOption.REPLACE_EXISTING);
    }
}
