package pztools.extensions.seamless.b4220;

import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.lang.constant.*;
import java.util.List;

/** Guard only the file-I/O block. Keep vanilla serialization, vehicle updates, locks and exception handlers. */
public final class ChunkSaveBytecode {
    private static final ClassDesc HOOK = ClassDesc.of("pztools.extensions.api.FileWriteHooks");
    private static final ClassDesc FILE = ClassDesc.of("java.io.File");
    private ChunkSaveBytecode() { }
    public static byte[] transform(byte[] bytes, ClassLoader loader) {
        var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
        var model = cf.parse(bytes);
        for (String name : List.of("SafeWrite", "SafeRead")) {
            var methods = model.methods().stream().filter(m -> m.methodName().equalsString(name)).toList();
            String signature = name.equals("SafeWrite") ? "(IILjava/nio/ByteBuffer;)V"
                : "(IILjava/nio/ByteBuffer;)Ljava/nio/ByteBuffer;";
            if (methods.size() != 1 || !methods.getFirst().methodType().equalsString(signature)
                    || !methods.getFirst().flags().has(java.lang.reflect.AccessFlag.STATIC))
                throw new IllegalArgumentException("Unexpected chunk I/O signature: " + name);
            var instructions = methods.getFirst().code().orElseThrow().elementStream()
                .filter(e -> e instanceof Instruction).map(e -> (Instruction)e).toList();
            if (instructions.stream().anyMatch(e -> e instanceof InvokeInstruction i && i.owner().asInternalName()
                    .equals("pztools/extensions/api/FileWriteHooks")))
                throw new IllegalArgumentException("Chunk I/O already intercepted");
            streamFileSlot(instructions, name.equals("SafeWrite"));
        }
        return cf.transformClass(model, (builder, element) -> {
            if (element instanceof MethodModel method && (method.methodName().equalsString("SafeWrite")
                    || method.methodName().equalsString("SafeRead"))) {
                boolean writing = method.methodName().equalsString("SafeWrite");
                var instructions = method.code().orElseThrow().elementStream().filter(e -> e instanceof Instruction)
                    .map(e -> (Instruction)e).toList();
                int fileSlot = streamFileSlot(instructions, writing);
                builder.transformMethod(method, MethodTransform.transformingCode(CodeTransform.ofStateful(() -> new CodeTransform() {
                    private Label afterWrite;
                    private boolean started, bound;
                    public void atStart(CodeBuilder code) { if (writing) afterWrite = code.newLabel(); }
                    public void accept(CodeBuilder code, CodeElement current) {
                        if (isStream(current, writing)) {
                            started = true;
                            code.aload(fileSlot);
                            if (writing) code.aload(2).invokestatic(HOOK, "tryDefer", MethodTypeDesc.of(
                                ConstantDescs.CD_boolean, FILE, ClassDesc.of("java.nio.ByteBuffer"))).ifne(afterWrite);
                            else code.invokestatic(HOOK, "beforeRead", MethodTypeDesc.of(ConstantDescs.CD_void, FILE));
                        }
                        if (writing && started && !bound && current instanceof FieldInstruction field
                                && field.opcode() == Opcode.GETSTATIC && field.name().equalsString("sanityCheck")) {
                            code.labelBinding(afterWrite); bound = true;
                        }
                        code.with(current);
                    }
                    public void atEnd(CodeBuilder code) {
                        if (!started || writing && !bound) throw new IllegalArgumentException("Missing chunk I/O boundary");
                    }
                })));
            } else builder.with(element);
        });
    }
    private static int streamFileSlot(List<Instruction> code, boolean writing) {
        int found = -1, count = 0;
        for (int i = 0; i < code.size(); i++) if (isStream(code.get(i), writing)) {
            count++; found = i;
        }
        if (count != 1 || found + 3 >= code.size() || code.get(found + 1).opcode() != Opcode.DUP
                || !(code.get(found + 2) instanceof LoadInstruction load) || load.typeKind() != TypeKind.REFERENCE
                || !(code.get(found + 3) instanceof InvokeInstruction constructor)
                || !constructor.name().equalsString("<init>") || !constructor.type().equalsString("(Ljava/io/File;)V"))
            throw new IllegalArgumentException("Unexpected chunk stream construction");
        if (writing) {
            int end = -1;
            for (int i = found + 4; i < code.size(); i++) if (code.get(i) instanceof FieldInstruction field
                    && field.opcode() == Opcode.GETSTATIC && field.name().equalsString("sanityCheck")) { end = i; break; }
            if (end < 0 || end + 1 >= code.size() || !(code.get(end + 1) instanceof InvokeInstruction close)
                    || !close.name().equalsString("endSaveFile") || !close.type().equalsString("()V"))
                throw new IllegalArgumentException("Unexpected chunk write finally boundary");
        }
        return load.slot();
    }
    private static boolean isStream(CodeElement element, boolean writing) {
        return element instanceof NewObjectInstruction allocation && allocation.className().asInternalName()
            .equals(writing ? "java/io/FileOutputStream" : "java/io/FileInputStream");
    }
}