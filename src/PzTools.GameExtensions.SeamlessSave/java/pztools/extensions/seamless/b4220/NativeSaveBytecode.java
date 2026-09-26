package pztools.extensions.seamless.b4220;

import java.lang.classfile.*;
import java.lang.classfile.instruction.*;
import java.lang.constant.*;
import java.util.*;

/** Keeps native submission/notification/cleanup; only the verified save-flag wait can be deferred. */
public final class NativeSaveBytecode {
    private static final ClassDesc HOOKS = ClassDesc.of("pztools.extensions.api.SaveWaitHooks");
    private static final MethodTypeDesc BEFORE = MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object);
    private static final MethodTypeDesc DEFER = MethodTypeDesc.of(ConstantDescs.CD_boolean, ConstantDescs.CD_Object);
    private static final String WORKER = "zombie/MapCollisionData$MCDThread";
    private NativeSaveBytecode() { }
    public static byte[] transform(byte[] bytes, ClassLoader loader) {
        var cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(ClassHierarchyResolver.ofClassLoading(loader)));
        var model = cf.parse(bytes);
        for (String method : List.of("save", "stop")) {
            var matches = model.methods().stream().filter(m -> m.methodName().equalsString(method)
                && m.methodType().equalsString("()V")).toList();
            if (matches.size() != 1 || matches.getFirst().code().isEmpty())
                throw new IllegalArgumentException("Unsupported native " + method);
            if (matches.getFirst().code().orElseThrow().elementStream().anyMatch(e -> e instanceof InvokeInstruction i
                    && i.owner().asInternalName().equals("pztools/extensions/api/SaveWaitHooks")))
                throw new IllegalArgumentException("Native save already intercepted");
        }
        var body = model.methods().stream().filter(m -> m.methodName().equalsString("save")
            && m.methodType().equalsString("()V")).findFirst().orElseThrow().code().orElseThrow();
        var instructions = body.elementStream().filter(e -> e instanceof Instruction).map(e -> (Instruction)e).toList();
        BranchInstruction waitEnd = null;
        int submits = 0, sleeps = 0, prepares = 0, finishes = 0, notifies = 0;
        for (int n = 0; n < instructions.size(); n++) {
            Instruction instruction = instructions.get(n);
            if (instruction instanceof FieldInstruction f && f.owner().asInternalName().equals(WORKER)
                    && f.name().equalsString("save") && f.type().equalsString("Z")) {
                if (f.opcode() == Opcode.PUTFIELD) submits++;
                if (f.opcode() == Opcode.GETFIELD) {
                    if (waitEnd != null || n + 1 == instructions.size()
                            || !(instructions.get(n + 1) instanceof BranchInstruction branch) || branch.opcode() != Opcode.IFEQ)
                        throw new IllegalArgumentException("Unsupported native wait condition");
                    waitEnd = (BranchInstruction)instructions.get(n + 1);
                }
            }
            if (instruction instanceof InvokeInstruction i) {
                if (i.owner().asInternalName().equals("java/lang/Thread") && i.name().equalsString("sleep")
                    && i.type().equalsString("(J)V")) sleeps++;
                if (i.owner().asInternalName().equals("java/lang/Object") && i.name().equalsString("notify")) notifies++;
                if (i.owner().asInternalName().equals("zombie/popman/ZombiePopulationManager")) {
                    if (i.name().equalsString("beginSaveRealZombies")) prepares++;
                    if (i.name().equalsString("endSaveRealZombies")) finishes++;
                }
            }
        }
        if (waitEnd == null || submits != 1 || sleeps != 1 || prepares != 1 || finishes != 1 || notifies != 1)
            throw new IllegalArgumentException("Native save layout differs from the verified adapter");
        return cf.transformClass(model, (builder, element) -> {
            if (element instanceof MethodModel m && m.methodType().equalsString("()V")
                    && (m.methodName().equalsString("save") || m.methodName().equalsString("stop")))
                builder.transformMethod(m, MethodTransform.transformingCode(inject(m.methodName().equalsString("save"))));
            else builder.with(element);
        });
    }
    private static CodeTransform inject(boolean saving) {
        return CodeTransform.ofStateful(() -> new CodeTransform() {
            private boolean saveFlagRead;
            public void atStart(CodeBuilder builder) {
                builder.aload(0).invokestatic(HOOKS, saving ? "beforeSave" : "beforeStop", BEFORE);
            }
            public void accept(CodeBuilder builder, CodeElement element) {
                builder.with(element);
                if (saving && saveFlagRead && element instanceof BranchInstruction branch)
                    builder.aload(0).invokestatic(HOOKS, "deferWait", DEFER).ifne(branch.target());
                if (element instanceof Instruction) saveFlagRead = element instanceof FieldInstruction f
                    && f.opcode() == Opcode.GETFIELD && f.owner().asInternalName().equals(WORKER)
                    && f.name().equalsString("save") && f.type().equalsString("Z");
            }
        });
    }
}
