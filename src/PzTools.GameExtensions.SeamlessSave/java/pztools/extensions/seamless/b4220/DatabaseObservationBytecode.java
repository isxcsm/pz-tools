package pztools.extensions.seamless.b4220;

import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.lang.constant.*;

/** Read-only success/error observation. Never changes a game save method or I/O path. */
public final class DatabaseObservationBytecode {
    private static final ClassDesc HOOKS = ClassDesc.of("pztools.extensions.api.GameHooks");
    private static final MethodTypeDesc ENTER = MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_String);
    private static final MethodTypeDesc EXIT = MethodTypeDesc.of(ConstantDescs.CD_void,
        ConstantDescs.CD_String, ClassDesc.of("java.lang.Throwable"));
    private DatabaseObservationBytecode() { }
    public static byte[] transform(String name, byte[] bytes, ClassLoader loader) {
        var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
        var model = cf.parse(bytes);
        if (!name.equals("zombie/savefile/PlayerDB") && !name.equals("zombie/vehicles/VehiclesDB2")
                && !name.equals("zombie/core/logger/ExceptionLogger"))
            throw new IllegalArgumentException("Not a database observation target: " + name);
        String method = name.equals("zombie/core/logger/ExceptionLogger") ? "logException" : "updateWorldStreamer";
        String signature = method.equals("logException") ? "(Ljava/lang/Throwable;)V" : "()V";
        var targets = model.methods().stream().filter(m -> m.methodName().equalsString(method)
            && m.methodType().equalsString(signature)).toList();
        if (targets.size() != 1 || targets.getFirst().code().isEmpty())
            throw new IllegalArgumentException("Unsupported save method: " + name);
        var body = targets.getFirst().code().orElseThrow();
        if (body.elementStream().anyMatch(e -> e instanceof InvokeInstruction i
                && i.owner().asInternalName().equals("pztools/extensions/api/GameHooks")))
            throw new IllegalArgumentException("Save method already intercepted");
        CodeTransform transform;
        if (method.equals("logException")) {
            transform = CodeTransform.ofStateful(() -> new CodeTransform() {
                public void atStart(CodeBuilder builder) {
                    builder.ldc(SaveSignals.ERRORS).aload(0).invokestatic(HOOKS, "error", EXIT);
                }
                public void accept(CodeBuilder builder, CodeElement element) { builder.with(element); }
            });
        } else {
            String point = name.equals("zombie/savefile/PlayerDB") ? SaveSignals.PLAYERS : SaveSignals.VEHICLES;
            transform = drain(point);
        }
        return cf.transformClass(model, ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString(method) && m.methodType().equalsString(signature), transform));
    }
    private static CodeTransform drain(String point) {
        return CodeTransform.ofStateful(() -> new CodeTransform() {
            private Label start, end, handler;
            private int failureSlot;
            public void atStart(CodeBuilder builder) {
                start = builder.newLabel(); end = builder.newLabel(); handler = builder.newLabel();
                failureSlot = builder.allocateLocal(TypeKind.REFERENCE);
                builder.ldc(point).invokestatic(HOOKS, "enter", ENTER).labelBinding(start);
            }
            public void accept(CodeBuilder builder, CodeElement element) {
                if (element instanceof ReturnInstruction)
                    builder.ldc(point).aconst_null().invokestatic(HOOKS, "exit", EXIT);
                builder.with(element);
            }
            public void atEnd(CodeBuilder builder) {
                builder.labelBinding(end).labelBinding(handler).astore(failureSlot);
                builder.ldc(point).aload(failureSlot).invokestatic(HOOKS, "exit", EXIT);
                builder.aload(failureSlot).athrow().exceptionCatchAll(start, end, handler);
            }
        });
    }
}
